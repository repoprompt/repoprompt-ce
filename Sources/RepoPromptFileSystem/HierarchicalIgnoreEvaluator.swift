import Foundation

/// Evaluates paths against a hierarchy of ignore rules, checking each prefix
/// to ensure parent directories that are ignored also ignore their children.
package final class HierarchicalIgnoreEvaluator {
    /// A provider of ignore rules for a given directory path
    package protocol RulesProvider {
        /// Get the effective ignore rules for a directory
        /// - Parameters:
        ///   - directoryPath: The relative path to the directory (empty string for root)
        /// - Returns: The ignore rules that apply at this directory level
        func rulesForDirectory(_ directoryPath: String) async throws -> IgnoreRules
    }

    private let rulesProvider: RulesProvider

    package init(rulesProvider: RulesProvider) {
        self.rulesProvider = rulesProvider
    }

    /// Check if a path is ignored, considering all parent directories
    /// - Parameters:
    ///   - relativePath: The relative path to check
    ///   - isDirectory: Whether the final component is a directory
    /// - Returns: true if the path or any parent directory is ignored
    package func isIgnored(relativePath: String, isDirectory: Bool) async throws -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        return try await isIgnored(components: components, isDirectory: isDirectory)
    }

    /// Check if a path is ignored, considering all parent directories
    /// - Parameters:
    ///   - components: Pre-split path components
    ///   - isDirectory: Whether the final component is a directory
    /// - Returns: true if the path or any parent directory is ignored
    package func isIgnored(components: [String], isDirectory finalIsDirectory: Bool) async throws -> Bool {
        guard !components.isEmpty else {
            return false
        }

        var pathSoFar = ""
        var lastOutcome: CompiledIgnoreRules.MatchOutcome?
        var lockedRules: IgnoreRules?

        for (index, component) in components.enumerated() {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordHierarchicalComponentEvaluation()
            #endif
            let isLastComponent = (index == components.count - 1)
            let isDirectory = isLastComponent ? finalIsDirectory : true
            pathSoFar = index == 0 ? component : "\(pathSoFar)/\(component)"
            let parentPath = index == 0 ? "" : components[0 ..< index].joined(separator: "/")

            let rules: IgnoreRules
            if let locked = lockedRules {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordHierarchicalLockedRulesReuse()
                #endif
                rules = locked
            } else {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordHierarchicalRulesLookup()
                #endif
                rules = try await rulesProvider.rulesForDirectory(parentPath)
            }

            let pathComps = pathSoFar.split(separator: "/")
            if let outcome = rules.matchOutcome(relativePathComponents: pathComps, isDirectory: isDirectory) {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordHierarchicalOutcomeMatch()
                #endif
                lastOutcome = outcome
                switch outcome {
                case .ignore:
                    if lockedRules == nil {
                        #if DEBUG
                            IgnoreDebugMetricsRecorder.recordHierarchicalLock()
                        #endif
                        lockedRules = rules
                    }
                case .allow:
                    if lockedRules != nil {
                        #if DEBUG
                            IgnoreDebugMetricsRecorder.recordHierarchicalUnlock()
                        #endif
                    }
                    lockedRules = nil
                case .noMatch:
                    break
                }
            }
        }

        return lastOutcome == .ignore
    }
}

/// A simple rules provider that uses a cache and fallback
public final class CachedRulesProvider: HierarchicalIgnoreEvaluator.RulesProvider {
    private let cache: [String: IgnoreRules]
    private let rootRules: IgnoreRules
    private let fallbackProvider: ((String) async throws -> IgnoreRules)?

    package init(
        cache: [String: IgnoreRules],
        rootRules: IgnoreRules,
        fallbackProvider: ((String) async throws -> IgnoreRules)? = nil
    ) {
        self.cache = cache
        self.rootRules = rootRules
        self.fallbackProvider = fallbackProvider
    }

    package func rulesForDirectory(_ directoryPath: String) async throws -> IgnoreRules {
        // Check cache first
        if let cached = cache[directoryPath] {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordHierarchicalRulesCacheHit()
            #endif
            return cached
        }

        // Root directory uses root rules
        if directoryPath.isEmpty {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordHierarchicalRulesCacheHit()
            #endif
            return rootRules
        }

        #if DEBUG
            IgnoreDebugMetricsRecorder.recordHierarchicalRulesCacheMiss()
        #endif

        // Try fallback provider if available
        if let provider = fallbackProvider {
            return try await provider(directoryPath)
        }

        // Default to root rules if no specific rules found
        return rootRules
    }
}
