import Foundation

// Holds multiple "layers" of compiled patterns (from .gitignore, .repo_ignore, etc.), combined.

enum IgnoreRuleAuthority {
    case mandatoryGit
    case secondary
}

enum IgnoreRulePolicy {
    case gitRoot(repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix)
    case nonGitRoot

    var enforcesGitIgnoreFloor: Bool {
        if case .gitRoot = self { return true }
        return false
    }

    func repositoryRelativeComponents(appending components: [Substring]) -> [Substring] {
        guard case let .gitRoot(prefix) = self, !prefix.value.isEmpty else { return components }
        let suffix = components.isEmpty ? "" : "/" + components.joined(separator: "/")
        return (prefix.value + suffix).split(separator: "/")
    }

    func repositoryRelativePath(appending path: String) -> String {
        guard case let .gitRoot(prefix) = self, !prefix.value.isEmpty else { return path }
        return path.isEmpty ? prefix.value : prefix.value + "/" + path
    }
}

final class IgnoreRules {
    // MARK: - Internal persistent node

    fileprivate final class RulesNode {
        let compiled: CompiledIgnoreRules
        let authority: IgnoreRuleAuthority
        let parent: RulesNode?
        /// Number of layers from root to this node (root = 1)
        let depth: Int
        /// Aggregate flag indicating if **any** ancestor has negative patterns
        let hasNegative: Bool
        let traversalPrefixes: Set<String>
        let traversalPatterns: Set<NegationTraversalPattern>
        let traversalDiagnostics: NegationTraversalDiagnostics
        let gitTraversalPrefixes: Set<String>
        let gitTraversalPatterns: Set<NegationTraversalPattern>

        init(compiled: CompiledIgnoreRules, authority: IgnoreRuleAuthority, parent: RulesNode?) {
            self.compiled = compiled
            self.authority = authority
            self.parent = parent
            depth = (parent?.depth ?? 0) + 1
            hasNegative = compiled.hasAnyNegativePattern || (parent?.hasNegative ?? false)
            if let parentPrefixes = parent?.traversalPrefixes {
                traversalPrefixes = parentPrefixes.union(compiled.negationTraversalPrefixes)
            } else {
                traversalPrefixes = compiled.negationTraversalPrefixes
            }
            if let parentPatterns = parent?.traversalPatterns {
                traversalPatterns = parentPatterns.union(compiled.negationTraversalPatterns)
            } else {
                traversalPatterns = compiled.negationTraversalPatterns
            }
            let basenameOnlyNegationCount = (parent?.traversalDiagnostics.basenameOnlyNegationCount ?? 0)
                + compiled.traversalDiagnostics.basenameOnlyNegationCount
            traversalDiagnostics = NegationTraversalDiagnostics(
                exactPrefixCount: traversalPrefixes.count,
                patternHintCount: traversalPatterns.count,
                broadPatternHintCount: traversalPatterns.filter(\.isBroad).count,
                basenameOnlyNegationCount: basenameOnlyNegationCount
            )
            if authority == .mandatoryGit {
                gitTraversalPrefixes = (parent?.gitTraversalPrefixes ?? [])
                    .union(compiled.negationTraversalPrefixes)
                gitTraversalPatterns = (parent?.gitTraversalPatterns ?? [])
                    .union(compiled.negationTraversalPatterns)
            } else {
                gitTraversalPrefixes = parent?.gitTraversalPrefixes ?? []
                gitTraversalPatterns = parent?.gitTraversalPatterns ?? []
            }
        }
    }

    // MARK: - Storage

    /// Tail of the linked chain (highest priority layer)
    private var tail: RulesNode
    private var cachedSnapshot: IgnoreRulesSnapshot?
    private let policy: IgnoreRulePolicy

    // MARK: - Initialisers

    /// Creates a new instance that starts with the shared default ignore layer.
    init(policy: IgnoreRulePolicy) {
        tail = IgnoreRules.baseNode
        self.policy = policy
    }

    /// Private designated initialiser used by `clone()` to share the same chain.
    private init(tail: RulesNode, policy: IgnoreRulePolicy) {
        self.tail = tail
        self.policy = policy
    }

    // MARK: - Public API

    func addCompiledLayer(
        _ compiled: CompiledIgnoreRules,
        authority: IgnoreRuleAuthority
    ) {
        cachedSnapshot = nil
        tail = RulesNode(compiled: compiled, authority: authority, parent: tail)
    }

    /// Return `true` if, after consulting all layers from highest to lowest,
    /// the path should be ignored.  (String-based entry point – kept for
    /// backward compatibility, now delegates to the component-based fast path.)
    func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        let comps = relativePath.split(separator: "/")
        return matchOutcome(relativePathComponents: comps, isDirectory: isDirectory) == .ignore
    }

    /// Fast overload that accepts **pre-split** path components to avoid the
    /// repeated allocation from `split(separator:)` in tight loops.
    func isIgnored(relativePathComponents comps: [Substring], isDirectory: Bool) -> Bool {
        matchOutcome(relativePathComponents: comps, isDirectory: isDirectory) == .ignore
    }

    /// Returns the highest-priority match outcome for the given path, or nil if
    /// no pattern matches. This is used by hierarchical evaluators that need to
    /// understand whether a match was produced by an ignore or negation rule.
    func matchOutcome(relativePathComponents comps: [Substring], isDirectory: Bool) -> CompiledIgnoreRules.MatchOutcome? {
        let repositoryComponents = policy.repositoryRelativeComponents(appending: comps)
        if policy.enforcesGitIgnoreFloor {
            let gitOutcome = matchOutcome(
                relativePathComponents: repositoryComponents,
                isDirectory: isDirectory,
                authority: .mandatoryGit
            )
            if gitOutcome == .ignore { return .ignore }
            if let secondaryOutcome = matchOutcome(
                relativePathComponents: repositoryComponents,
                isDirectory: isDirectory,
                authority: .secondary
            ) {
                return secondaryOutcome
            }
            return gitOutcome
        }
        var node: RulesNode? = tail
        while let current = node {
            switch current.compiled.outcome(for: repositoryComponents, isDirectory: isDirectory) {
            case .ignore: return .ignore
            case .allow: return .allow
            case .noMatch: break // Keep searching in lower-priority layers
            }
            node = current.parent
        }
        return nil
    }

    private func matchOutcome(
        relativePathComponents comps: [Substring],
        isDirectory: Bool,
        authority: IgnoreRuleAuthority
    ) -> CompiledIgnoreRules.MatchOutcome? {
        var node: RulesNode? = tail
        while let current = node {
            defer { node = current.parent }
            guard current.authority == authority else { continue }
            switch current.compiled.outcome(for: comps, isDirectory: isDirectory) {
            case .ignore: return .ignore
            case .allow: return .allow
            case .noMatch: break
            }
        }
        return nil
    }

    /// Fast aggregate check used by directory traversal code.
    func hasAnyNegativePatterns() -> Bool {
        tail.hasNegative
    }

    /// Returns true if any negative rule requires us to keep scanning the
    /// directory located at `path` (relative to the repository root).
    func requiresTraversal(for path: String) -> Bool {
        #if DEBUG
            IgnoreDebugMetricsRecorder.recordTraversalRequiresCheck()
        #endif
        let repositoryPath = policy.repositoryRelativePath(appending: path)
        let components = repositoryPath.split(separator: "/")
        let gitRejected = policy.enforcesGitIgnoreFloor
            && matchOutcome(
                relativePathComponents: components,
                isDirectory: true,
                authority: .mandatoryGit
            ) == .ignore
        let prefixes = gitRejected ? tail.gitTraversalPrefixes : tail.traversalPrefixes
        let patterns = gitRejected ? tail.gitTraversalPatterns : tail.traversalPatterns
        if prefixes.contains(repositoryPath) {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordTraversalExactPrefixHit()
            #endif
            return true
        }
        for pattern in patterns {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordTraversalPatternCheck()
            #endif
            if pattern.matches(directoryPath: repositoryPath) {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordTraversalPatternHit()
                #endif
                return true
            }
        }
        return false
    }

    var traversalDiagnostics: NegationTraversalDiagnostics {
        tail.traversalDiagnostics
    }

    /// Returns a shallow clone that *shares* all rule layers with the original.
    func clone() -> IgnoreRules {
        IgnoreRules(tail: tail, policy: policy)
    }

    /// The number of rule layers (including defaults).
    var depth: Int {
        tail.depth
    }

    /// Immutable snapshot safe to send off-actor.
    func snapshot() -> IgnoreRulesSnapshot {
        if let cached = cachedSnapshot {
            return cached
        }
        var layers: [CompiledIgnoreRules] = []
        var gitLayers: [CompiledIgnoreRules] = []
        var secondaryLayers: [CompiledIgnoreRules] = []
        layers.reserveCapacity(tail.depth)
        var node: RulesNode? = tail
        while let current = node {
            layers.append(current.compiled)
            switch current.authority {
            case .mandatoryGit: gitLayers.append(current.compiled)
            case .secondary: secondaryLayers.append(current.compiled)
            }
            node = current.parent
        }
        let snapshot = IgnoreRulesSnapshot(
            layers: layers,
            gitLayers: gitLayers,
            secondaryLayers: secondaryLayers,
            policy: policy,
            hasNegative: tail.hasNegative,
            traversalPrefixes: tail.traversalPrefixes,
            traversalPatterns: tail.traversalPatterns,
            gitTraversalPrefixes: tail.gitTraversalPrefixes,
            gitTraversalPatterns: tail.gitTraversalPatterns,
            traversalDiagnostics: tail.traversalDiagnostics
        )
        cachedSnapshot = snapshot
        return snapshot
    }

    // MARK: - Static shared default layer

    /// The literal default ignore patterns, extracted from the previous impl.
    private static let mandatoryGitIgnoreContent = """
    .git
    """

    private static let secondaryDefaultIgnoreContent = """
    # Other version-control and system files
    .svn
    .DS_Store
    Thumbs.db
    """

    private static let mandatoryGitBaseNode: RulesNode = {
        let compiled = GitignoreCompiler.compile(content: mandatoryGitIgnoreContent)
        return RulesNode(compiled: compiled, authority: .mandatoryGit, parent: nil)
    }()

    /// Secondary built-ins retain their historical low priority and never
    /// masquerade as Git's mandatory authority.
    private static let baseNode: RulesNode = {
        let compiled = GitignoreCompiler.compile(content: secondaryDefaultIgnoreContent)
        return RulesNode(compiled: compiled, authority: .secondary, parent: mandatoryGitBaseNode)
    }()
}

struct IgnoreRulesSnapshot {
    fileprivate let layers: [CompiledIgnoreRules]
    fileprivate let gitLayers: [CompiledIgnoreRules]
    fileprivate let secondaryLayers: [CompiledIgnoreRules]
    private let policy: IgnoreRulePolicy
    private let hasNegative: Bool
    private let traversalPrefixes: Set<String>
    private let traversalPatterns: Set<NegationTraversalPattern>
    private let gitTraversalPrefixes: Set<String>
    private let gitTraversalPatterns: Set<NegationTraversalPattern>
    let traversalDiagnostics: NegationTraversalDiagnostics

    fileprivate init(
        layers: [CompiledIgnoreRules],
        gitLayers: [CompiledIgnoreRules],
        secondaryLayers: [CompiledIgnoreRules],
        policy: IgnoreRulePolicy,
        hasNegative: Bool,
        traversalPrefixes: Set<String>,
        traversalPatterns: Set<NegationTraversalPattern>,
        gitTraversalPrefixes: Set<String>,
        gitTraversalPatterns: Set<NegationTraversalPattern>,
        traversalDiagnostics: NegationTraversalDiagnostics
    ) {
        self.layers = layers
        self.gitLayers = gitLayers
        self.secondaryLayers = secondaryLayers
        self.policy = policy
        self.hasNegative = hasNegative
        self.traversalPrefixes = traversalPrefixes
        self.traversalPatterns = traversalPatterns
        self.gitTraversalPrefixes = gitTraversalPrefixes
        self.gitTraversalPatterns = gitTraversalPatterns
        self.traversalDiagnostics = traversalDiagnostics
    }

    func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        let comps = relativePath.split(separator: "/")
        return matchOutcome(relativePathComponents: comps, isDirectory: isDirectory) == .ignore
    }

    func isIgnored(relativePathComponents comps: [Substring], isDirectory: Bool) -> Bool {
        matchOutcome(relativePathComponents: comps, isDirectory: isDirectory) == .ignore
    }

    func matchOutcome(
        relativePathComponents comps: [Substring],
        isDirectory: Bool
    ) -> CompiledIgnoreRules.MatchOutcome? {
        let repositoryComponents = policy.repositoryRelativeComponents(appending: comps)
        if policy.enforcesGitIgnoreFloor {
            let gitOutcome = Self.matchOutcome(
                in: gitLayers,
                relativePathComponents: repositoryComponents,
                isDirectory: isDirectory
            )
            if gitOutcome == .ignore { return .ignore }
            return Self.matchOutcome(
                in: secondaryLayers,
                relativePathComponents: repositoryComponents,
                isDirectory: isDirectory
            ) ?? gitOutcome
        }
        return Self.matchOutcome(
            in: layers,
            relativePathComponents: repositoryComponents,
            isDirectory: isDirectory
        )
    }

    private static func matchOutcome(
        in layers: [CompiledIgnoreRules],
        relativePathComponents comps: [Substring],
        isDirectory: Bool
    ) -> CompiledIgnoreRules.MatchOutcome? {
        for compiled in layers {
            switch compiled.outcome(for: comps, isDirectory: isDirectory) {
            case .ignore: return .ignore
            case .allow: return .allow
            case .noMatch: break
            }
        }
        return nil
    }

    func hasAnyNegativePatterns() -> Bool {
        hasNegative
    }

    func requiresTraversal(for path: String) -> Bool {
        #if DEBUG
            IgnoreDebugMetricsRecorder.recordTraversalRequiresCheck()
        #endif
        let repositoryPath = policy.repositoryRelativePath(appending: path)
        let gitRejected = policy.enforcesGitIgnoreFloor
            && Self.matchOutcome(
                in: gitLayers,
                relativePathComponents: repositoryPath.split(separator: "/"),
                isDirectory: true
            ) == .ignore
        let prefixes = gitRejected ? gitTraversalPrefixes : traversalPrefixes
        let patterns = gitRejected ? gitTraversalPatterns : traversalPatterns
        if prefixes.contains(repositoryPath) {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordTraversalExactPrefixHit()
            #endif
            return true
        }
        for pattern in patterns {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordTraversalPatternCheck()
            #endif
            if pattern.matches(directoryPath: repositoryPath) {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordTraversalPatternHit()
                #endif
                return true
            }
        }
        return false
    }
}
