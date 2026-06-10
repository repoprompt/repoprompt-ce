import Foundation

// Wildmatch bit-flags (duplicated from wildmatch.h)
private let WM_NOESCAPE: UInt32 = 0x01
private let WM_PATHNAME: UInt32 = 0x02
private let WM_PERIOD: UInt32 = 0x04
private let WM_LEADING_DIR: UInt32 = 0x08
private let WM_CASEFOLD: UInt32 = 0x10
private let WM_PREFIX_DIRS: UInt32 = 0x20
private let WM_WILDSTAR: UInt32 = 0x40

private let WM_MATCH: Int32 = 0 // Success (same as C macro)

/// Flags we always use for Git-style ignores
private let WM_DEFAULT_FLAGS: UInt32 = WM_PATHNAME | WM_NOESCAPE | WM_WILDSTAR

/// Check if a gitignore match function returned WM_MATCH
@inline(__always)
private func isMatch(_ result: Int32) -> Bool {
    result == WM_MATCH
}

/// Represents a single line of a `.gitignore`-style file, parsed and
/// normalized for matching logic.
public struct GitPattern: Sendable {
    /// The original pattern text, with leading/trailing slash removed if necessary.
    let pattern: String

    /// If true, this pattern is `!something`, meaning it *unignores* matching paths.
    let isNegation: Bool

    /// If true, pattern must match only directories (like trailing slash in Git).
    let directoryOnly: Bool

    /// If true, pattern is anchored to the ignore-file directory.
    /// Leading-slash patterns and slash-containing patterns match from that scoped root.
    let absolute: Bool

    /// Conservative metadata used to avoid full wildcard matching when a path
    /// cannot possibly match this pattern.
    let prefilter: GitPatternPrefilter
}

enum GitPatternPrefilter: Equatable {
    case always
    case basenameLiteral(String)
    case directoryBasenameLiteral(String)
    case anchoredLiteralPath(String)
    case anchoredDirectoryPrefix(String)
    case basenameSuffix(String)

    var requiresCheck: Bool {
        if case .always = self {
            return false
        }
        return true
    }
}

struct NegationTraversalDiagnostics: Equatable {
    let exactPrefixCount: Int
    let patternHintCount: Int
    let broadPatternHintCount: Int
    let basenameOnlyNegationCount: Int

    static let empty = NegationTraversalDiagnostics(
        exactPrefixCount: 0,
        patternHintCount: 0,
        broadPatternHintCount: 0,
        basenameOnlyNegationCount: 0
    )

    func adding(_ other: NegationTraversalDiagnostics) -> NegationTraversalDiagnostics {
        NegationTraversalDiagnostics(
            exactPrefixCount: exactPrefixCount + other.exactPrefixCount,
            patternHintCount: patternHintCount + other.patternHintCount,
            broadPatternHintCount: broadPatternHintCount + other.broadPatternHintCount,
            basenameOnlyNegationCount: basenameOnlyNegationCount + other.basenameOnlyNegationCount
        )
    }
}

struct NegationTraversalPattern: Hashable {
    let pattern: String
    let absolute: Bool
    let isBroad: Bool

    func matches(directoryPath: String) -> Bool {
        if pattern == "**" {
            return true
        }
        guard !directoryPath.isEmpty else { return false }

        if pattern.hasSuffix("/**") {
            let basePattern = String(pattern.dropLast(3))
            if !basePattern.isEmpty, matchesPattern(basePattern, directoryPath: directoryPath) {
                return true
            }
        }

        return matchesPattern(pattern, directoryPath: directoryPath)
    }

    private func matchesPattern(_ pattern: String, directoryPath: String) -> Bool {
        pattern.withCString { patC in
            directoryPath.withCString { pathC in
                let result = absolute
                    ? repo_gitignore_match_anchored(patC, pathC)
                    : repo_gitignore_match_anywhere(patC, pathC)
                return isMatch(result)
            }
        }
    }
}

/// Holds the final compiled set of patterns for one file’s `.gitignore` content.
public struct CompiledIgnoreRules: Sendable {
    /// Each entry is one pattern line, in order of appearance in file.
    /// (Later lines have higher precedence when we do the final check.)
    private let patterns: [GitPattern]
    let negationTraversalPrefixes: Set<String>
    let negationTraversalPatterns: Set<NegationTraversalPattern>
    let traversalDiagnostics: NegationTraversalDiagnostics

    /// Quick check for "do we have any negative pattern?"
    public var hasAnyNegativePattern: Bool {
        patterns.contains { $0.isNegation }
    }

    /// Result of evaluating this layer against a single path.
    public enum MatchOutcome {
        /// A positive pattern matched – the path must be ignored.
        case ignore
        /// A negative pattern matched – the path must be kept.
        case allow
        /// No pattern in this layer matched.
        case noMatch
    }

    init(
        patterns: [GitPattern],
        negationTraversalPrefixes: Set<String> = [],
        negationTraversalPatterns: Set<NegationTraversalPattern> = [],
        traversalDiagnostics: NegationTraversalDiagnostics = .empty
    ) {
        self.patterns = patterns
        self.negationTraversalPrefixes = negationTraversalPrefixes
        self.negationTraversalPatterns = negationTraversalPatterns
        self.traversalDiagnostics = traversalDiagnostics
    }

    /// Evaluate this layer and return the first deciding pattern (searching from
    /// last to first, mirroring Git’s precedence rules).
    ///
    /// - Parameters:
    ///   - path: The path to test, relative to the repository root.
    ///   - isDirectory: Whether the path represents a directory.
    /// Primary implementation - components-based to avoid repeated splits
    public func outcome(for components: [Substring], isDirectory: Bool) -> MatchOutcome {
        let path = components.joined(separator: "/")
        #if DEBUG
            var patternVisits = 0
            var patternAttempts = 0
            var prefilterChecks = 0
            var prefilterSkips = 0
            defer {
                IgnoreDebugMetricsRecorder.recordOutcomeEvaluation(
                    patternVisits: patternVisits,
                    patternAttempts: patternAttempts,
                    prefilterChecks: prefilterChecks,
                    prefilterSkips: prefilterSkips
                )
            }
        #endif

        for pattern in patterns.reversed() {
            #if DEBUG
                patternVisits += 1
                if pattern.prefilter.requiresCheck {
                    prefilterChecks += 1
                }
            #endif
            if !prefilterMayMatch(
                pattern.prefilter,
                components: components,
                path: path,
                isDirectory: isDirectory
            ) {
                #if DEBUG
                    prefilterSkips += 1
                #endif
                continue
            }
            #if DEBUG
                patternAttempts += 1
            #endif
            if matchOnePattern(path: path, components: components, isDirectory: isDirectory, pat: pattern) {
                return pattern.isNegation ? .allow : .ignore
            }
        }
        return .noMatch
    }

    /// String-based convenience wrapper
    public func outcome(for path: String, isDirectory: Bool) -> MatchOutcome {
        // Handle empty path - gitignore semantics: only ** matches empty path
        guard !path.isEmpty else {
            #if DEBUG
                var patternVisits = 0
                var patternAttempts = 0
                defer {
                    IgnoreDebugMetricsRecorder.recordOutcomeEvaluation(
                        patternVisits: patternVisits,
                        patternAttempts: patternAttempts
                    )
                }
            #endif

            for pattern in patterns.reversed() {
                #if DEBUG
                    patternVisits += 1
                #endif
                // Only non-anchored "**" pattern should match empty path
                if pattern.pattern == "**", !pattern.isNegation, !pattern.absolute {
                    return .ignore
                }
            }
            return .noMatch
        }
        let components = path.split(separator: "/")
        return outcome(for: components, isDirectory: isDirectory)
    }

    /// Returns `true` if, after considering all patterns (from first to last),
    /// this path is ultimately "denied" (ignored).
    ///
    /// We iterate from last pattern to first to find the first match.
    /// If the matched pattern is negative => unignored => return false
    /// Else => ignored => return true.
    /// If no pattern matches => return false (not ignored).
    public func denies(_ path: String, isDirectory: Bool) -> Bool {
        outcome(for: path, isDirectory: isDirectory) == .ignore
    }

    /// Returns true if any negation rule requires us to keep traversing the
    /// directory at `path` even if other patterns would ignore it.
    func requiresTraversal(for path: String) -> Bool {
        #if DEBUG
            IgnoreDebugMetricsRecorder.recordTraversalRequiresCheck()
        #endif
        if negationTraversalPrefixes.contains(path) {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordTraversalExactPrefixHit()
            #endif
            return true
        }
        for pattern in negationTraversalPatterns {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordTraversalPatternCheck()
            #endif
            if pattern.matches(directoryPath: path) {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordTraversalPatternHit()
                #endif
                return true
            }
        }
        return false
    }

    // MARK: - Matching logic

    /// Returns `true` if `path` matches this pattern, respecting directory-only or absolute logic.
    private func matchOnePattern(path: String, components: [Substring], isDirectory: Bool, pat: GitPattern) -> Bool {
        // Directory-only patterns ----------------------------------------------
        if pat.directoryOnly {
            // Directory-only patterns match the directory itself and anything below it.
            // For files, only parent directories are candidates. For directories, the
            // path itself and all ancestors are candidates.
            let lastCandidateIndex = isDirectory ? components.count - 1 : components.count - 2
            guard lastCandidateIndex >= 0 else { return false }

            for i in 0 ... lastCandidateIndex {
                let directoryComps = Array(components[0 ... i])
                let directoryPath = directoryComps.joined(separator: "/")
                if matchesTrailingDoubleStarBase(path: directoryPath, components: directoryComps, isDirectory: true, pat: pat) {
                    return true
                }
                if matchesScopedPattern(path: directoryPath, components: directoryComps, pattern: pat.pattern, absolute: pat.absolute) {
                    return true
                }
            }
            return false
        }

        // Regular patterns ------------------------------------------------------
        if matchesTrailingDoubleStarBase(path: path, components: components, isDirectory: isDirectory, pat: pat) {
            return true
        }
        return matchesScopedPattern(path: path, components: components, pattern: pat.pattern, absolute: pat.absolute)
    }

    private func prefilterMayMatch(
        _ prefilter: GitPatternPrefilter,
        components: [Substring],
        path: String,
        isDirectory: Bool
    ) -> Bool {
        switch prefilter {
        case .always:
            return true
        case let .basenameLiteral(name):
            return components.contains { $0 == name }
        case let .directoryBasenameLiteral(name):
            let count = directoryCandidateComponentCount(components: components, isDirectory: isDirectory)
            guard count > 0 else { return false }
            return components.prefix(count).contains { $0 == name }
        case let .anchoredLiteralPath(literalPath):
            guard !literalPath.isEmpty else { return true }
            return path == literalPath || path.hasPrefix(literalPath + "/")
        case let .anchoredDirectoryPrefix(directoryPath):
            guard !directoryPath.isEmpty else { return true }
            return path == directoryPath || path.hasPrefix(directoryPath + "/")
        case let .basenameSuffix(suffix):
            return components.contains { $0.hasSuffix(suffix) }
        }
    }

    private func directoryCandidateComponentCount(components: [Substring], isDirectory: Bool) -> Int {
        isDirectory ? components.count : max(components.count - 1, 0)
    }

    private func matchesTrailingDoubleStarBase(path: String, components: [Substring], isDirectory: Bool, pat: GitPattern) -> Bool {
        guard isDirectory, pat.pattern.hasSuffix("/**") else { return false }
        let basePattern = String(pat.pattern.dropLast(3))
        guard !basePattern.isEmpty else { return false }
        #if DEBUG
            IgnoreDebugMetricsRecorder.recordTrailingDoubleStarBaseCheck()
        #endif
        return matchesScopedPattern(path: path, components: components, pattern: basePattern, absolute: pat.absolute)
    }

    private func matchesScopedPattern(path: String, components: [Substring], pattern: String, absolute: Bool) -> Bool {
        absolute
            ? matchesPathAnchored(path, pattern)
            : matchesPathAnywhere(path, pattern)
    }

    private func matchesPathAnchored(_ path: String, _ pattern: String) -> Bool {
        pattern.withCString { patC in
            path.withCString { pathC in
                isMatch(repo_gitignore_match_anchored(patC, pathC))
            }
        }
    }

    /// For non-absolute patterns, we use the C implementation
    private func matchesPathAnywhere(_ path: String, _ pattern: String) -> Bool {
        pattern.withCString { patC in
            path.withCString { pathC in
                isMatch(repo_gitignore_match_anywhere(patC, pathC))
            }
        }
    }

    // All low-level pattern matching (globMatch, matchComponent, findClosingBracket,
    // matchCharacterClass, matchPatternCompsInPath, matchCompsIterative)
    // is now handled by the C wildmatch implementation.
}

// MARK: - The Compiler

public enum GitignoreCompiler {
    /// Given the raw text of a `.gitignore` (or similar) file, parse out lines
    /// into a `CompiledIgnoreRules` object with full negative/positive pattern logic.
    public static func compile(content: String, directoryPath: String = "") -> CompiledIgnoreRules {
        let lines = content.components(separatedBy: .newlines)
        var patterns = [GitPattern]()
        var traversalPrefixes = Set<String>()
        var traversalPatterns = Set<NegationTraversalPattern>()
        var basenameOnlyNegationCount = 0

        for line in lines {
            line.withCString { lineC in
                var parsedPattern = repo_gitignore_pattern()

                // Parse the line using C function
                if repo_parse_gitignore_line(lineC, &parsedPattern) {
                    // Convert C array to Swift String
                    let patternStr = withUnsafeBytes(of: parsedPattern.pattern) { bytes in
                        let cString = bytes.bindMemory(to: CChar.self).baseAddress!
                        return String(cString: cString)
                    }

                    let anchoredToIgnoreFileDirectory = parsedPattern.absolute || patternStr.contains("/")
                    var adjustedPattern = patternStr
                    if anchoredToIgnoreFileDirectory, !directoryPath.isEmpty {
                        let prefix = directoryPath.hasSuffix("/") ? String(directoryPath.dropLast()) : directoryPath
                        if !prefix.isEmpty {
                            adjustedPattern = "\(prefix)/\(adjustedPattern)"
                        }
                    }

                    let interned = PatternPool.shared.intern(adjustedPattern)
                    let prefilter = makePrefilter(
                        pattern: interned,
                        directoryOnly: parsedPattern.directory_only,
                        absolute: anchoredToIgnoreFileDirectory
                    )

                    let pat = GitPattern(
                        pattern: interned,
                        isNegation: parsedPattern.is_negation,
                        directoryOnly: parsedPattern.directory_only,
                        absolute: anchoredToIgnoreFileDirectory,
                        prefilter: prefilter
                    )
                    patterns.append(pat)

                    if pat.isNegation {
                        let hints = traversalHints(for: pat)
                        traversalPrefixes.formUnion(hints.prefixes)
                        traversalPatterns.formUnion(hints.patterns)
                        basenameOnlyNegationCount += hints.basenameOnlyNegationCount
                    }
                }
            }
        }

        let diagnostics = NegationTraversalDiagnostics(
            exactPrefixCount: traversalPrefixes.count,
            patternHintCount: traversalPatterns.count,
            broadPatternHintCount: traversalPatterns.filter(\.isBroad).count,
            basenameOnlyNegationCount: basenameOnlyNegationCount
        )

        #if DEBUG
            IgnoreDebugMetricsRecorder.recordCompile(
                rawLineCount: lines.count,
                patternCount: patterns.count,
                negationPatternCount: patterns.filter(\.isNegation).count,
                diagnostics: diagnostics
            )
        #endif

        return CompiledIgnoreRules(
            patterns: patterns,
            negationTraversalPrefixes: traversalPrefixes,
            negationTraversalPatterns: traversalPatterns,
            traversalDiagnostics: diagnostics
        )
    }

    private static let maxTraversalVariants = 32

    private static func makePrefilter(
        pattern: String,
        directoryOnly: Bool,
        absolute: Bool
    ) -> GitPatternPrefilter {
        guard !pattern.isEmpty else { return .always }
        guard !pattern.contains("\\") else { return .always }
        guard !pattern.contains("**") else { return .always }
        guard !pattern.contains("?") else { return .always }
        guard !pattern.contains("[") && !pattern.contains("]") else { return .always }

        let containsSlash = pattern.contains("/")
        let starCount = pattern.reduce(0) { partialResult, character in
            partialResult + (character == "*" ? 1 : 0)
        }

        if starCount > 0 {
            if starCount == 1,
               !containsSlash,
               !directoryOnly,
               pattern.hasPrefix("*."),
               pattern.count > 2
            {
                return .basenameSuffix(String(pattern.dropFirst()))
            }
            return .always
        }

        if absolute || containsSlash {
            return directoryOnly
                ? .anchoredDirectoryPrefix(pattern)
                : .anchoredLiteralPath(pattern)
        }

        return directoryOnly
            ? .directoryBasenameLiteral(pattern)
            : .basenameLiteral(pattern)
    }

    private struct TraversalHints {
        var prefixes: Set<String> = []
        var patterns: Set<NegationTraversalPattern> = []
        var basenameOnlyNegationCount = 0
    }

    private static func traversalHints(for pattern: GitPattern) -> TraversalHints {
        let components = pattern.pattern.split(separator: "/").map(String.init)
        let limit = pattern.directoryOnly ? components.count : max(components.count - 1, 0)
        guard limit > 0 else {
            return TraversalHints(basenameOnlyNegationCount: 1)
        }

        var hints = TraversalHints()
        for prefixLength in 1 ... limit {
            let prefixComponents = Array(components.prefix(prefixLength))
            // A parent-less "**/file" negation should not force traversal into
            // every ignored directory; deeper hints such as "**/logs" still matter.
            if prefixComponents.count == 1, prefixComponents.first == "**" {
                continue
            }
            if let literalVariants = literalPrefixVariants(for: prefixComponents) {
                for variant in literalVariants {
                    let prefix = variant.joined(separator: "/")
                    if !prefix.isEmpty {
                        hints.prefixes.insert(prefix)
                    }
                }
            } else {
                let patternHint = prefixComponents.joined(separator: "/")
                if !patternHint.isEmpty {
                    let interned = PatternPool.shared.intern(patternHint)
                    hints.patterns.insert(NegationTraversalPattern(
                        pattern: interned,
                        absolute: pattern.absolute,
                        isBroad: isBroadTraversalPattern(prefixComponents)
                    ))
                }
            }
        }

        return hints
    }

    private static func literalPrefixVariants(for components: [String]) -> [[String]]? {
        var variants: [[String]] = [[]]

        for part in components {
            if part.isEmpty { continue }
            guard let expansions = expandLiteralComponent(part) else {
                return nil
            }
            var next: [[String]] = []
            for variant in variants {
                for literal in expansions {
                    var newVariant = variant
                    newVariant.append(literal)
                    next.append(newVariant)
                    if next.count > maxTraversalVariants {
                        return nil
                    }
                }
            }
            variants = next
        }

        return variants
    }

    private static func isBroadTraversalPattern(_ components: [String]) -> Bool {
        guard let first = components.first else { return false }
        if first == "**" || first == "*" || first == "**/*" {
            return true
        }
        if first.hasPrefix("**/") || first.hasPrefix("*") || first.hasPrefix("?") {
            return true
        }
        return false
    }

    private static func expandLiteralComponent(_ component: String) -> [String]? {
        var results = [""]
        var idx = component.startIndex

        while idx < component.endIndex {
            let char = component[idx]
            if char == "[" {
                guard let close = component[idx...].firstIndex(of: "]"),
                      close > idx
                else {
                    return nil
                }
                let content = component[component.index(after: idx) ..< close]
                guard let choices = expandSimpleCaseFold(content) else {
                    return nil
                }
                results = combineLiteralOptions(base: results, additions: choices)
                if results.count > maxTraversalVariants {
                    return nil
                }
                idx = component.index(after: close)
            } else if char == "*" || char == "?" {
                return nil
            } else if char == "\\" {
                idx = component.index(after: idx)
                guard idx < component.endIndex else { return nil }
                let literal = String(component[idx])
                results = combineLiteralOptions(base: results, additions: [literal])
                if results.count > maxTraversalVariants {
                    return nil
                }
                idx = component.index(after: idx)
            } else {
                results = combineLiteralOptions(base: results, additions: [String(char)])
                if results.count > maxTraversalVariants {
                    return nil
                }
                idx = component.index(after: idx)
            }
        }

        return results
    }

    private static func combineLiteralOptions(base: [String], additions: [String]) -> [String] {
        var combined: [String] = []
        combined.reserveCapacity(base.count * additions.count)
        for prefix in base {
            for suffix in additions {
                combined.append(prefix + suffix)
            }
        }
        return combined
    }

    private static func expandSimpleCaseFold(_ content: Substring) -> [String]? {
        guard content.count == 2 else { return nil }
        guard let first = content.first, let second = content.last else { return nil }
        guard first.isLetter, second.isLetter else { return nil }
        let lowerFirst = String(first).lowercased()
        let lowerSecond = String(second).lowercased()
        guard lowerFirst == lowerSecond else { return nil }
        return [String(first), String(second)]
    }
}
