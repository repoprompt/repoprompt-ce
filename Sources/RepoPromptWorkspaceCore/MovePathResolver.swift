import Foundation

/// Root-scoped move/rename destination resolution with alias disambiguation.
package enum MovePathResolver {
    package typealias Root = WorkspaceRootRef

    package enum AliasPrefixCheck {
        case notPrefixed
        case uniqueRoot(root: Root, alias: String)
        case ambiguous(alias: String, matchingRoots: [Root])
    }

    package enum Error: Swift.Error, Equatable {
        case emptyDestination
        case destinationOutsideRoot(root: Root)
        case ambiguousAlias(alias: String, matchingRoots: [Root])
        case crossRootAlias(alias: String, resolvedRoot: Root)
    }

    package static func resolveRelativePathInRoot(
        userPath: String,
        sourceRoot: Root,
        visibleRoots: [Root]
    ) throws -> String {
        let standardized = StandardizedPath.absolute(userPath)
        let trimmed = standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            throw Error.emptyDestination
        }

        if standardized.hasPrefix("/") {
            let rootPath = sourceRoot.standardizedFullPath
            guard isDescendant(standardized, of: rootPath) else {
                throw Error.destinationOutsideRoot(root: sourceRoot)
            }
            let remainder = String(
                standardized.dropFirst(rootPath.count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
            return try validatedRelativeDestination(remainder, within: sourceRoot)
        }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: visibleRoots,
            options: RootAliasOptions(
                requireRemainder: true,
                allowCompatibilityAlias: true,
                // Move/rename intentionally keeps canonical alias-first semantics:
                // a single leading alias picks the root, and a literal same-name subfolder
                // must be explicit via a double prefix (RootName/RootName/...).
                // Do not couple move resolution to create-time literal preference rules.
                disambiguateRealSubpath: false
            )
        ) {
        case let .ambiguous(alias, matchingRoots):
            throw Error.ambiguousAlias(alias: alias, matchingRoots: matchingRoots)
        case let .prefixed(resolvedRoot, alias, remainder):
            if resolvedRoot.id != sourceRoot.id {
                throw Error.crossRootAlias(alias: alias, resolvedRoot: resolvedRoot)
            }
            return try validatedRelativeDestination(remainder, within: sourceRoot)
        case .notAliasPrefixed, .bareRoot:
            break
        }

        return try validatedRelativeDestination(standardized, within: sourceRoot)
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
                // Move/rename intentionally keeps canonical alias-first semantics:
                // a single leading alias picks the root, and a literal same-name subfolder
                // must be explicit via a double prefix (RootName/RootName/...).
                // Do not couple move resolution to create-time literal preference rules.
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

@inline(__always)
private func validatedRelativeDestination(
    _ relativePath: String,
    within root: MovePathResolver.Root
) throws -> String {
    let rootPath = root.standardizedFullPath
    let normalizedRelativePath = StandardizedPath.relative(relativePath)
    guard !normalizedRelativePath.isEmpty else {
        throw MovePathResolver.Error.emptyDestination
    }
    let absoluteDestination = StandardizedPath.absolute(
        StandardizedPath.join(
            standardizedRoot: rootPath,
            standardizedRelativePath: normalizedRelativePath
        )
    )
    guard StandardizedPath.isDescendant(absoluteDestination, of: rootPath) else {
        throw MovePathResolver.Error.destinationOutsideRoot(root: root)
    }
    return String(
        absoluteDestination.dropFirst(rootPath.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    )
}

@inline(__always)
private func isDescendant(_ path: String, of parent: String) -> Bool {
    let stdSelf = StandardizedPath.absolute(path)
    let stdParent = StandardizedPath.absolute(parent)
    return StandardizedPath.isDescendant(stdSelf, of: stdParent)
}
