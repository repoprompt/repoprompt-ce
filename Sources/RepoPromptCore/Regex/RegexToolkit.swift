import Foundation

/// Umbrella protocol for all regex pattern failures
public protocol RegexPatternFailure: LocalizedError {}

/// Unified regex toolkit providing pattern validation, normalization, and risk assessment
public enum RegexToolkit {
    /// Whitelist for legal one-char escapes after backslash has been consumed
    private static let validSingleCharEscapes: Set<Character> = [
        "\\", ".", "s", "S", "w", "W", "d", "D", "b", "B", "n", "r", "t", "f", "v",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "(", ")", "[", "]", "{", "}", "^", "$", "*", "+", "?", "|", "-"
    ]

    // MARK: - Public API

    /// Normalized pattern result
    public struct Normalised {
        public let text: String // safe to compile
        public let wasModified: Bool // user typed ≠ we compiled

        public init(text: String, wasModified: Bool) {
            self.text = text
            self.wasModified = wasModified
        }
    }

    /// Normalizes regex pattern by fixing common issues with empty alternatives
    public static func normalise(_ raw: String) throws -> Normalised {
        var normalized = raw
        let originalPattern = raw

        // Remove leading pipes (empty alternative at start)
        while normalized.hasPrefix("|") {
            normalized = String(normalized.dropFirst())
        }

        // Remove trailing pipes (empty alternative at end)
        while normalized.hasSuffix("|") {
            normalized = String(normalized.dropLast())
        }

        // Replace multiple consecutive pipes with single pipe
        while normalized.contains("||") {
            normalized = normalized.replacingOccurrences(of: "||", with: "|")
        }

        // NEW: Escape-aware unmatched parentheses repair (outside of [...] and not already escaped)
        if !normalized.isEmpty {
            let chars = Array(normalized)
            var out: [Character] = []
            out.reserveCapacity(chars.count)

            var openStack: [Int] = [] // indices in 'out' where '(' was emitted
            var i = 0
            var escaping = false
            var inClass = false
            let backslash: Character = "\\"

            while i < chars.count {
                let ch = chars[i]

                if escaping {
                    // Keep escaped character as-is
                    out.append(ch)
                    escaping = false
                    i += 1
                    continue
                }
                if ch == backslash {
                    out.append(backslash)
                    escaping = true
                    i += 1
                    continue
                }
                if ch == "[", !inClass {
                    inClass = true
                    out.append(ch)
                    i += 1
                    continue
                }
                if ch == "]", inClass {
                    inClass = false
                    out.append(ch)
                    i += 1
                    continue
                }
                if !inClass {
                    if ch == "(" {
                        openStack.append(out.count)
                        out.append(ch)
                        i += 1
                        continue
                    }
                    if ch == ")" {
                        if openStack.isEmpty {
                            // unmatched closing paren → escape it
                            out.append(backslash)
                            out.append(")")
                        } else {
                            _ = openStack.removeLast()
                            out.append(")")
                        }
                        i += 1
                        continue
                    }
                }
                out.append(ch)
                i += 1
            }
            // Escape any remaining unmatched '('
            if !openStack.isEmpty {
                for idx in openStack.reversed() {
                    out.insert(backslash, at: idx)
                }
            }
            normalized = String(out)
        }

        // If the pattern becomes empty after normalization, return a pattern that matches nothing
        if normalized.isEmpty {
            normalized = "(?!.*)" // Negative lookahead that matches nothing
        }

        let wasModified = normalized != originalPattern
        return Normalised(text: normalized, wasModified: wasModified)
    }

    /// Validates a regex pattern **according to NSRegularExpression semantics**.
    ///
    /// This validator is only used when we route a pattern to the NSRegularExpression
    /// engine (PCRE tokens like `\w`, `\d`, `\s`, `\b`, whole-word mode, or Swift Regex
    /// compilation failure). Swift's native `Regex` accepts a broader set of patterns
    /// (e.g., treating invalid quantifier syntax like `{` as literals), and we do *not*
    /// run this validation for Swift Regex paths.
    ///
    /// ## When to use
    /// - Patterns containing PCRE-specific tokens (`\w`, `\d`, `\s`, `\b`, etc.)
    /// - Patterns with `wholeWord: true` (uses `\b` boundaries)
    /// - Fallback when Swift Regex compilation fails
    /// - Path search regex (which only uses NSRegularExpression)
    ///
    /// ## When NOT to use
    /// - Patterns that will execute via Swift's native `Regex` engine
    /// - Use `validateComplexity(_:isRegex:)` as the only pre-check for Swift Regex
    ///
    /// - Parameter pattern: The regex pattern to validate
    /// - Throws: `SearchPatternError` with user-friendly classification
    public static func validate(_ pattern: String) throws {
        // Fast-path: if NSRegularExpression compiles it, the pattern is valid for NSRegex.
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [])
            return
        } catch {
            // Fall through to friendly error classification below.
        }
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)

        // --- fast semantic guards --------------------------------------------
        // (1) unmatched parens  (2) unmatched [] char-class  (3) invalid escape
        var paren = 0, bracket = 0, escaping = false, inClass = false
        var iterator = pattern.enumerated().makeIterator()
        while let (i, ch) = iterator.next() {
            if escaping {
                //  validate the *escaped* character (current 'ch')
                if !validSingleCharEscapes.contains(ch) {
                    throw SearchPatternError.invalidEscape(pattern)
                }
                escaping = false
                continue
            }
            if ch == "\\" {
                escaping = true
                if i == pattern.count - 1 { // lone back-slash at end
                    throw SearchPatternError.invalidEscape(pattern)
                }
                continue
            }
            if ch == "[", !inClass { bracket += 1
                inClass = true
                continue
            }
            if ch == "]", inClass { bracket -= 1
                if bracket == 0 { inClass = false }
                continue
            }
            if ch == "]", !inClass { throw SearchPatternError.unmatchedBrackets(pattern) }

            if !inClass { // outside [...]
                if ch == "(" { paren += 1 }
                if ch == ")" { paren -= 1
                    if paren < 0 { throw SearchPatternError.unmatchedParentheses(pattern) }
                }

                // ------------------------------------------------------------------
                //  Quantifier / brace sanity  {  …  }
                // ------------------------------------------------------------------
                if ch == "{" {
                    // ➊  Fast-path: detect "{" followed by ']', '[' or end-of-string
                    //     → clearly *not* a legal quantifier
                    if i == pattern.count - 1 { throw SearchPatternError.invalidQuantifier(pattern) }
                    let next = pattern[pattern.index(pattern.startIndex, offsetBy: i + 1)]

                    if next == "," || next == "}" {
                        //  {,}   or   {}   → syntax is wrong but it *is* intended as a
                        //  quantifier, so classify as .invalidQuantifier (not brackets)
                        throw SearchPatternError.invalidQuantifier(pattern)
                    }

                    // ➋  If next isn't a digit **and** isn't '}', treat as unmatched brace
                    guard next.isNumber || next == "}" else {
                        throw SearchPatternError.unmatchedBrackets(pattern)
                    }

                    // ➌  Parse a canonical {min,max}  /  {min,}  /  {n}
                    var idx = pattern.index(pattern.startIndex, offsetBy: i + 1)
                    var firstDigits = ""
                    while idx < pattern.endIndex, pattern[idx].isNumber {
                        firstDigits.append(pattern[idx])
                        idx = pattern.index(after: idx)
                    }
                    var hasComma = false
                    var secondDigits = ""
                    if idx < pattern.endIndex, pattern[idx] == "," {
                        hasComma = true
                        idx = pattern.index(after: idx)
                        while idx < pattern.endIndex, pattern[idx].isNumber {
                            secondDigits.append(pattern[idx])
                            idx = pattern.index(after: idx)
                        }
                    }

                    // ➍  Must end with a closing '}'
                    guard idx < pattern.endIndex, pattern[idx] == "}" else {
                        throw SearchPatternError.invalidQuantifier(pattern)
                    }

                    // ➎  Sanity-check numeral sizes
                    for numStr in [firstDigits, secondDigits] where !numStr.isEmpty {
                        if let n = Int(numStr), n > 10000 {
                            throw SearchPatternError.invalidQuantifier(pattern)
                        }
                    }

                    // ➏  Reject constructs like "{,}" or "{,"  (missing numbers)
                    if hasComma, firstDigits.isEmpty, secondDigits.isEmpty {
                        throw SearchPatternError.invalidQuantifier(pattern)
                    }

                    // ➐  Advance scan-pointer so outer loop skips the rest of the quantifier
                    //     (-1 because the outer loop will do its own idx += 1)
                    let distance = pattern.distance(from: pattern.index(pattern.startIndex, offsetBy: i), to: idx)
                    for _ in 0 ..< distance {
                        _ = iterator.next()
                    }
                    continue
                }
            }
        }
        if paren != 0 { throw SearchPatternError.unmatchedParentheses(pattern) }
        if bracket != 0 { throw SearchPatternError.unmatchedBrackets(pattern) }

        // Use NSRegularExpression's own diagnostics for everything else
        // This catches complex quantifier issues, nested patterns, etc.
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            throw SearchPatternError.invalidRegex(pattern, error.localizedDescription)
        }
    }

    /// Detects anchored patterns that also contain a nested quantifier
    /// ")+", ")*", ")?", or "){…}" which are prone to catastrophic
    /// back-tracking (e.g. the classical `^(a+)+b$`).
    public static func isHighRisk(_ pattern: String) -> Bool {
        // Must be ^…$ without embedded newline
        guard isLineAnchored(pattern) else { return false }
        // Quick substring scan – we ignore escaped parens for simplicity.
        return pattern.contains(")+") ||
            pattern.contains(")*") ||
            pattern.contains(")?") ||
            pattern.contains("){")
    }

    /// Detects unanchored patterns containing greedy quantifiers like `.*` or `.+`
    /// that are expensive to evaluate on large buffers.  These patterns are not
    /// "catastrophic" in the classical nested-quantifier sense, but they force the
    /// regex engine to scan through the entire buffer for every potential start
    /// position, which becomes very slow on multi-MB files — especially combined
    /// with alternation.  The synchronous `.matches(of:)` call cannot be
    /// interrupted by cooperative cancellation, so these patterns should be
    /// evaluated line-by-line instead of on the full document buffer.
    ///
    /// Examples caught:
    /// - `xml.*trim|xmlTrim`  — greedy `.*` with alternation
    /// - `foo.+bar`           — greedy `.+`
    /// - `.*something`        — leading greedy wildcard
    public static func isExpensiveUnanchored(_ pattern: String) -> Bool {
        guard !isLineAnchored(pattern) else { return false }
        // Look for unescaped .* or .+ which indicate greedy quantifiers on '.'
        var previousWasEscape = false
        var previousWasDot = false
        for ch in pattern {
            if previousWasEscape {
                previousWasEscape = false
                previousWasDot = false
                continue
            }
            if ch == "\\" {
                previousWasEscape = true
                previousWasDot = false
                continue
            }
            if previousWasDot, ch == "*" || ch == "+" {
                return true
            }
            previousWasDot = (ch == ".")
        }
        return false
    }

    /// Returns `true` when the raw regex pattern is anchored with ^ … $
    /// and does **not** contain any explicit newline.  Those patterns can be
    /// scanned efficiently line-by-line to avoid catastrophic back-tracking on
    /// huge files.
    public static func isLineAnchored(_ pattern: String) -> Bool {
        guard pattern.first == "^", pattern.last == "$" else { return false }
        return !pattern.contains("\n")
    }

    /// Validates pattern complexity and throws SearchPatternTooComplexError when the supplied pattern is obviously
    /// too large or contains an excessive amount of capturing groups. This is a
    /// fast O(n) scan and runs *before* handing the pattern to the regex engine.
    public static func validateComplexity(_ pattern: String, isRegex: Bool) throws {
        // Hard guards to avoid catastrophic regex compilation/back-tracking.
        let maxPatternLength = 2000 // characters
        let maxCaptureGroups = 250 // '(' not escaped by '\'

        guard pattern.count <= maxPatternLength else {
            throw SearchPatternTooComplexError()
        }
        guard isRegex else { return } // literal patterns are safe

        // Reject obviously catastrophic patterns like ^(a+)+b$
        if isHighRisk(pattern) {
            throw SearchPatternTooComplexError()
        }

        var groupCount = 0
        var previousWasEscape = false
        for ch in pattern {
            if previousWasEscape {
                previousWasEscape = false
                continue
            }
            if ch == "\\" {
                previousWasEscape = true
            } else if ch == "(" {
                groupCount += 1
                if groupCount > maxCaptureGroups {
                    throw SearchPatternTooComplexError()
                }
            }
        }
    }

    /// Simple validation to check if a regex pattern can be compiled
    public static func isValidPattern(_ pattern: String) -> Bool {
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [])
            return true
        } catch {
            return false
        }
    }

    /// Detects if pattern uses PCRE-only features unsupported by Swift Regex
    public static func usesPCREOnlyFeatures(_ pattern: String) -> Bool {
        let pcreTokens = [
            "\\w",
            "\\d",
            "\\s",
            "(?=",
            "(?<!",
            "(?<=",
            "(?!",
            "(?>",
            "\\b",
            "[[:",
            "\\Q",
            "\\E",
            "(?i)",
            "(?m)",
            "(?s)",
            "(?x)"
        ]
        return pcreTokens.contains { pattern.contains($0) } || containsInlineOptionGroup(pattern)
    }

    private static func containsInlineOptionGroup(_ pattern: String) -> Bool {
        var searchStart = pattern.startIndex
        while let intro = pattern.range(of: "(?", range: searchStart ..< pattern.endIndex) {
            var index = intro.upperBound
            var sawFlag = false
            var awaitingFlagAfterHyphen = false

            while index < pattern.endIndex {
                let ch = pattern[index]
                if isInlineOptionFlag(ch) {
                    sawFlag = true
                    awaitingFlagAfterHyphen = false
                    index = pattern.index(after: index)
                    continue
                }
                if ch == "-" {
                    awaitingFlagAfterHyphen = true
                    index = pattern.index(after: index)
                    continue
                }
                if ch == ")" || ch == ":", sawFlag, !awaitingFlagAfterHyphen {
                    return true
                }
                break
            }

            searchStart = intro.upperBound
        }
        return false
    }

    private static func isInlineOptionFlag(_ ch: Character) -> Bool {
        switch ch {
        case "i", "m", "s", "x", "U", "J":
            true
        default:
            false
        }
    }
}

package enum SearchPatternErrorFormatter {
    package static func parts(for pattern: String, isRegex: Bool, error: SearchPatternError) -> (issue: String, suggestion: String?) {
        let base = error.localizedDescription
        switch error {
        case .unmatchedParentheses:
            if isRegex {
                return (base, "Unmatched parentheses. Balance each '(' with a ')' or escape literal parentheses as '\\\\(' and '\\\\)'.")
            } else {
                return (base, "You're in literal mode. Parentheses match as regular characters; if you meant regex operators, set regex=true.")
            }
        case .unmatchedBrackets:
            if isRegex {
                return (base, "Missing closing bracket ']' in the character class. Close it or escape literal '[' as '\\\\['.")
            } else {
                return (base, "Literal search interprets '[' as plain text. To build character classes, enable regex=true.")
            }
        case .invalidEscape:
            if isRegex {
                return (base, "Invalid escape sequence. Use '\\\\\\\\' for a literal backslash, or double-escape special characters like '\\\\('.")
            } else {
                return (base, "Backslashes are literal in regex=false mode. Remove extra escapes or enable regex=true for regex syntax.")
            }
        case .invalidQuantifier:
            if isRegex {
                return (base, "Quantifiers like '*', '+', and '{n}' need a token before them. Add a leading '.' or escape the character with '\\\\*'.")
            } else {
                return (base, "Literal search treats '*' as a normal character. If you intended a wildcard, enable regex=true or escape with '\\\\*'.")
            }
        case let .invalidRegex(_, details):
            let issue = "Invalid regex pattern. \(details)"
            if RepoPromptPCRE2Adapter.isVariableLengthLookbehindError(pattern: pattern, details: details),
               let suggestion = RepoPromptPCRE2Adapter.variableLengthLookbehindSuggestion(pattern: pattern)
            {
                return (issue, suggestion)
            }
            if isRegex {
                return (issue, "Review the pattern for typos or unmatched groups. Escape literal characters with '\\\\'.")
            } else {
                return (issue, "If you intended to use regex features, set regex=true. Otherwise remove regex-only syntax.")
            }
        case .emptyAlternative:
            return (base, "Remove extra '|' characters or provide content on both sides of the alternation.")
        }
    }
}

// MARK: - Error types

/// Errors specific to search patterns
public enum SearchPatternError: Error, LocalizedError, RegexPatternFailure {
    case unmatchedParentheses(String)
    case unmatchedBrackets(String)
    case invalidEscape(String)
    case invalidQuantifier(String)
    case invalidRegex(String, String)
    case emptyAlternative(String)

    public var errorDescription: String? {
        switch self {
        case let .unmatchedParentheses(pattern):
            "Unmatched parentheses in pattern: '\(pattern)'. Check that all '(' have matching ')'."
        case let .unmatchedBrackets(pattern):
            "Unmatched brackets in pattern: '\(pattern)'. Check that all '[' have matching ']'."
        case let .invalidEscape(pattern):
            "Invalid escape sequence in pattern: '\(pattern)'. Use '\\\\' for literal backslash."
        case let .invalidQuantifier(pattern):
            "Invalid quantifier in pattern: '\(pattern)'. Check syntax like {n,m} or *+?."
        case let .invalidRegex(pattern, details):
            "Invalid regex pattern: '\(pattern)'. \(details)"
        case let .emptyAlternative(pattern):
            "Empty alternative in pattern: '\(pattern)'. Remove extra '|' characters."
        }
    }
}

/// Hard guards to avoid catastrophic regex compilation/back-tracking.
public struct SearchPatternTooComplexError: Error, LocalizedError, RegexPatternFailure {
    public var errorDescription: String? {
        """
        Search pattern was rejected because it is either excessively large \
        or shaped in a way that is known to cause catastrophic back-tracking \
        in the regex engine.  Please simplify the pattern or rewrite it \
        using non-nested quantifiers.
        """
    }
}
