import Foundation

/// Pure helper for create preflight validation and root-alias checks.
package enum CreatePathPreflight {
    /// Controls how strict the preflight validation is for multi-root workspaces.
    package enum Mode {
        /// Current behavior: always require alias prefix or absolute path when multiple roots are loaded.
        case strictRequireAliasInMultiRoot
        /// Relaxed mode for tool flows: allow relative paths without alias if they can be resolved
        /// unambiguously to a single root by a higher-level resolver.
        case allowImplicitRootIfUnambiguous
    }

    package typealias Root = WorkspaceRootRef

    package enum AliasPrefixCheck: Equatable {
        case notPrefixed
        case uniqueRoot(root: Root, alias: String)
        case ambiguous(alias: String, matchingRoots: [Root])
    }

    package enum Error: Swift.Error, Equatable {
        case emptyPath
        case ambiguousAlias(alias: String, matchingRoots: [Root])
        case missingAliasWithMultipleRoots(loadedRoots: [Root])
    }

    package struct Result: Equatable {
        package let normalizedPath: String
        package let aliasCheck: AliasPrefixCheck
        package let isAbsolute: Bool
    }

    package static func validate(
        userPath: String,
        visibleRoots: [Root],
        mode: Mode = .strictRequireAliasInMultiRoot
    ) throws -> Result {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Error.emptyPath
        }

        let standardized = StandardizedPath.absolute(trimmed)
        let isAbsolute = standardized.hasPrefix("/")

        let aliasCheck: AliasPrefixCheck
        if !isAbsolute {
            aliasCheck = checkAliasPrefix(
                standardized,
                visibleRoots: visibleRoots,
                requireRemainder: true
            )
            switch aliasCheck {
            case let .ambiguous(alias, matchingRoots):
                throw Error.ambiguousAlias(alias: alias, matchingRoots: matchingRoots)
            case .notPrefixed:
                if visibleRoots.count > 1, mode == .strictRequireAliasInMultiRoot {
                    throw Error.missingAliasWithMultipleRoots(loadedRoots: visibleRoots)
                }
            case .uniqueRoot:
                break
            }
        } else {
            aliasCheck = .notPrefixed
        }

        return Result(normalizedPath: standardized, aliasCheck: aliasCheck, isAbsolute: isAbsolute)
    }

    package static func checkAliasPrefix(
        _ userPath: String,
        visibleRoots: [Root],
        requireRemainder: Bool
    ) -> AliasPrefixCheck {
        switch WorkspaceAliasResolver.resolve(
            userPath: userPath,
            roots: visibleRoots,
            options: RootAliasOptions(
                requireRemainder: requireRemainder,
                allowCompatibilityAlias: true,
                // Keep explicit alias detection in preflight. Tool-create performs richer
                // literal-vs-alias depth disambiguation later in
                // `WorkspaceFilesViewModel.resolvedLiteralCreateResult(...)`.
                // Setting this to true would suppress alias info needed downstream.
                disambiguateRealSubpath: false
            )
        ) {
        case .notAliasPrefixed, .bareRoot:
            .notPrefixed
        case let .prefixed(root, alias, _):
            .uniqueRoot(root: root, alias: alias)
        case let .ambiguous(alias, matchingRoots):
            .ambiguous(alias: alias, matchingRoots: matchingRoots)
        }
    }
}
