import Foundation
import MCP

/// Shared pure helpers for workspace-oriented MCP window tools.
///
/// The prompt/workspace_context, file/discovery, and manage_selection providers
/// share path display, search-argument, and small DTO-shaping helpers here so
/// provider implementations do not reach back into `MCPServerViewModel` for
/// static utility behavior.
enum MCPWindowWorkspaceToolHelpers {
    static let defaultCodeStructureMaxResults = 10
    static let codeStructureTokenBudget = 6000
    static let codeStructureSeparatorTokenCost = TokenCalculationService.estimateTokens(for: "\n\n")

    struct CodeStructureBudgetCandidate: Equatable {
        let key: String
        let estimatedTokens: Int
    }

    struct CodeStructureBudgetSelection: Equatable {
        let includedKeys: [String]
        let omittedByMaxResults: Int
        let omittedByTokenBudget: Int

        var omittedTotal: Int {
            omittedByMaxResults + omittedByTokenBudget
        }
    }

    static func prefixedRelativePath(forPath path: String, rootRefs: [WorkspaceRootRef]) -> String {
        ClientPathFormatter.displayAbsolutePath(fullPath: path, visibleRoots: rootRefs)
    }

    static func mcpDisplayPath(
        forPath path: String,
        visibleRoots: [WorkspaceRootRef],
        allRoots: [WorkspaceRootRef]
    ) -> String {
        let visible = ClientPathFormatter.displayAbsolutePath(fullPath: path, visibleRoots: visibleRoots)
        if visible != StandardizedPath.absolute(path) {
            return visible
        }
        return ClientPathFormatter.displayAbsolutePath(fullPath: path, visibleRoots: allRoots)
    }

    static func makeCachedMCPDisplayPathResolver(
        visibleRoots: [WorkspaceRootRef],
        allRoots: [WorkspaceRootRef]
    ) -> (String) -> String {
        var cache: [String: String] = [:]
        return { rawPath in
            if let cached = cache[rawPath] {
                return cached
            }
            let result = mcpDisplayPath(forPath: rawPath, visibleRoots: visibleRoots, allRoots: allRoots)
            cache[rawPath] = result
            return result
        }
    }

    static func friendlySearchErrorParts(
        for pattern: String,
        isRegex: Bool,
        error: SearchPatternError
    ) -> (issue: String, suggestion: String?) {
        SearchPatternErrorFormatter.parts(for: pattern, isRegex: isRegex, error: error)
    }

    static func sanitizeSearchScopeInputs(_ inputs: [String]) -> [String] {
        var seen = Set<String>()
        var sanitized: [String] = []
        sanitized.reserveCapacity(inputs.count)
        for input in inputs {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                sanitized.append(trimmed)
            }
        }
        return sanitized
    }

    static func pathFilterSuggestion(
        hadPathFilter: Bool,
        scopedFileCount: Int?
    ) -> String? {
        guard hadPathFilter, (scopedFileCount ?? 0) == 0 else { return nil }
        return "The specified path filter resolved to no files in the current workspace. Use get_file_tree to inspect the project structure and confirm the path."
    }

    static func parseContextAlias(_ args: [String: Value]) -> Int? {
        if let alias = args["-C"] {
            if let value = alias.intValue {
                return value
            }
            if let string = alias.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = Int(string)
            {
                return parsed
            }
        }

        for (key, value) in args {
            let lower = key.lowercased()
            guard lower.hasPrefix("-c") else { continue }

            if lower == "-c" {
                if let intValue = value.intValue {
                    return intValue
                }
                if let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let parsed = Int(string)
                {
                    return parsed
                }
                continue
            }

            var suffix = key.dropFirst(2)
            while let first = suffix.first, first == ":" || first == "=" || first == " " {
                suffix = suffix.dropFirst()
            }
            let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Int(trimmed) {
                return parsed
            }
        }

        return nil
    }

    static func applyCodeStructureOutputBudget(
        _ candidates: [CodeStructureBudgetCandidate],
        maxResults: Int,
        tokenBudget: Int = codeStructureTokenBudget,
        separatorTokens: Int = codeStructureSeparatorTokenCost
    ) -> CodeStructureBudgetSelection {
        let effectiveMaxResults = max(0, maxResults)
        let effectiveTokenBudget = max(0, tokenBudget)
        let countCapped = Array(candidates.prefix(effectiveMaxResults))
        let omittedByMaxResults = max(0, candidates.count - countCapped.count)

        var includedKeys: [String] = []
        var usedTokens = 0

        for candidate in countCapped {
            let isFirstEntry = includedKeys.isEmpty
            let entryCost = isFirstEntry ? candidate.estimatedTokens : candidate.estimatedTokens + max(0, separatorTokens)
            if !isFirstEntry, usedTokens + entryCost > effectiveTokenBudget {
                break
            }
            includedKeys.append(candidate.key)
            usedTokens += entryCost
        }

        return CodeStructureBudgetSelection(
            includedKeys: includedKeys,
            omittedByMaxResults: omittedByMaxResults,
            omittedByTokenBudget: max(0, countCapped.count - includedKeys.count)
        )
    }
}
