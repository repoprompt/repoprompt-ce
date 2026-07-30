import Foundation

package struct WorkspaceRootRef: Hashable, Sendable {
    package let id: UUID
    package let name: String
    package let fullPath: String
    package let standardizedFullPath: String

    package init(id: UUID, name: String, fullPath: String) {
        self.id = id
        self.name = name
        self.fullPath = fullPath
        standardizedFullPath = StandardizedPath.absolute(fullPath)
    }

    package var compatibilityAlias: String {
        (standardizedFullPath as NSString).lastPathComponent
    }

    package var renderedLabel: String {
        "\(name) → \(fullPath)"
    }
}

package enum RootAliasResolution: Equatable {
    case notAliasPrefixed
    case bareRoot(root: WorkspaceRootRef, alias: String)
    case prefixed(root: WorkspaceRootRef, alias: String, remainder: String)
    case ambiguous(alias: String, matchingRoots: [WorkspaceRootRef])
}

package struct RootAliasOptions {
    package let requireRemainder: Bool
    package let allowCompatibilityAlias: Bool
    /// When true, suppresses alias interpretation only if a same-name top-level subpath
    /// exists under the matched root. This is a shallow top-level check only; it does not
    /// compare the full remainder chain or score deeper structure.
    /// Tool-create flows use richer literal-vs-alias depth scoring in
    /// `WorkspaceFilesViewModel.resolvedLiteralCreateResult(...)`.
    package let disambiguateRealSubpath: Bool

    package init(
        requireRemainder: Bool,
        allowCompatibilityAlias: Bool = true,
        disambiguateRealSubpath: Bool = false
    ) {
        self.requireRemainder = requireRemainder
        self.allowCompatibilityAlias = allowCompatibilityAlias
        self.disambiguateRealSubpath = disambiguateRealSubpath
    }
}

package enum WorkspaceAliasResolver {
    package static func resolve(
        userPath: String,
        roots: [WorkspaceRootRef],
        options: RootAliasOptions,
        rootHasRealSubpath: ((WorkspaceRootRef, String) -> Bool)? = nil
    ) -> RootAliasResolution {
        let standardized = StandardizedPath.absolute(userPath)
        guard !standardized.hasPrefix("/") else { return .notAliasPrefixed }

        let candidate = standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !candidate.isEmpty else { return .notAliasPrefixed }

        let components = candidate.split(separator: "/").map(String.init)
        if options.requireRemainder {
            guard components.count >= 2 else { return .notAliasPrefixed }
        } else {
            guard !components.isEmpty else { return .notAliasPrefixed }
        }

        guard let alias = components.first, !alias.isEmpty else { return .notAliasPrefixed }
        guard !roots.isEmpty else { return .notAliasPrefixed }

        let generatedAliasResolution = resolveNonAbsoluteGeneratedAlias(
            components: components,
            roots: roots,
            options: options,
            minimumComponentCount: 2
        )
        if generatedAliasResolution != .notAliasPrefixed {
            return generatedAliasResolution
        }

        let canonicalMatches = roots.filter { $0.name.caseInsensitiveCompare(alias) == .orderedSame }
        if canonicalMatches.count > 1 {
            return .ambiguous(alias: alias, matchingRoots: canonicalMatches)
        }

        let resolvedRoot: WorkspaceRootRef?
        if let root = canonicalMatches.first {
            resolvedRoot = root
        } else if options.allowCompatibilityAlias {
            let compatibilityMatches = roots.filter {
                $0.compatibilityAlias.caseInsensitiveCompare(alias) == .orderedSame
            }
            if compatibilityMatches.count > 1 {
                return .ambiguous(alias: alias, matchingRoots: compatibilityMatches)
            }
            resolvedRoot = compatibilityMatches.first
        } else {
            resolvedRoot = nil
        }

        if let root = resolvedRoot {
            if options.disambiguateRealSubpath, rootHasRealSubpath?(root, alias) == true {
                return .notAliasPrefixed
            }

            let remainder = components.dropFirst().joined(separator: "/")
            if remainder.isEmpty {
                return .bareRoot(root: root, alias: alias)
            }
            return .prefixed(root: root, alias: alias, remainder: remainder)
        }

        return resolveNonAbsoluteGeneratedAlias(
            components: components,
            roots: roots,
            options: options,
            minimumComponentCount: 1
        )
    }

    private static func resolveNonAbsoluteGeneratedAlias(
        components: [String],
        roots: [WorkspaceRootRef],
        options: RootAliasOptions,
        minimumComponentCount: Int
    ) -> RootAliasResolution {
        let aliasByRoot = Dictionary(grouping: roots) { root in
            ClientPathFormatter.nonAbsoluteRootAlias(root: root, visibleRoots: roots).lowercased()
        }
        let lowerBound = max(1, minimumComponentCount)
        guard components.count >= lowerBound else { return .notAliasPrefixed }
        for aliasLength in stride(from: components.count, through: lowerBound, by: -1) {
            let alias = components.prefix(aliasLength).joined(separator: "/")
            let remainder = components.dropFirst(aliasLength).joined(separator: "/")
            if options.requireRemainder, remainder.isEmpty { continue }
            guard let matches = aliasByRoot[alias.lowercased()] else { continue }
            if matches.count > 1 {
                return .ambiguous(alias: alias, matchingRoots: matches)
            }
            guard let root = matches.first else { continue }
            if remainder.isEmpty {
                return .bareRoot(root: root, alias: alias)
            }
            return .prefixed(root: root, alias: alias, remainder: remainder)
        }
        return .notAliasPrefixed
    }
}

package enum PathResolutionIssue: Equatable {
    case emptyInput
    case invalidPathCharacters(input: String, reason: String)
    case ambiguousAlias(alias: String, matchingRoots: [WorkspaceRootRef])
    case ambiguousRootMatch(input: String, candidateRoots: [WorkspaceRootRef])
    case pathOutsideWorkspace(input: String, visibleRoots: [WorkspaceRootRef])
    case destinationOutsideSourceRoot(input: String, sourceRoot: WorkspaceRootRef)
    case unsupportedPseudoAbsoluteAlias(input: String)
    case unresolved(input: String)
}

package enum PathResolutionIssueRenderer {
    package static func message(for issue: PathResolutionIssue) -> String {
        switch issue {
        case .emptyInput:
            return "Path is required."
        case let .invalidPathCharacters(input, reason):
            return "Path '\(StandardizedPath.diagnosticEscaped(input))' contains invalid characters: \(reason)."
        case let .ambiguousAlias(alias, matchingRoots):
            let rendered = matchingRoots.map(\.renderedLabel).joined(separator: "; ")
            return "Ambiguous root alias '\(alias)'. It matches multiple loaded roots: \(rendered). Use an absolute path or rename roots so aliases are unique."
        case let .ambiguousRootMatch(input, candidateRoots):
            let rendered = candidateRoots.map(\.renderedLabel).joined(separator: "; ")
            return "Path '\(input)' matches multiple workspace roots: \(rendered). Use a root-prefixed or absolute path to disambiguate."
        case let .pathOutsideWorkspace(input, visibleRoots):
            let rendered = visibleRoots.map(\.renderedLabel).joined(separator: "; ")
            return "The requested path '\(input)' is not inside any loaded folder. Loaded roots: \(rendered)."
        case let .destinationOutsideSourceRoot(input, sourceRoot):
            return "Path '\(input)' must remain inside the source root: \(sourceRoot.renderedLabel)."
        case let .unsupportedPseudoAbsoluteAlias(input):
            return "Path '\(input)' looks like '/RootName/...'. Drop the leading slash or use a true absolute path inside a loaded root."
        case let .unresolved(input):
            return "Could not resolve '\(input)' within the current workspace."
        }
    }
}

package enum ClientPathFormatter {
    package static func nonAbsoluteDisplayPath(
        root: WorkspaceRootRef,
        relativePath: String,
        visibleRoots: [WorkspaceRootRef]
    ) -> String {
        let standardizedRelative = StandardizedPath.relative(relativePath)
        let alias = nonAbsoluteRootAlias(root: root, visibleRoots: visibleRoots)
        if visibleRoots.count <= 1 {
            return standardizedRelative.isEmpty ? alias : standardizedRelative
        }
        return standardizedRelative.isEmpty ? alias : "\(alias)/\(standardizedRelative)"
    }

    package static func nonAbsoluteRootAlias(root: WorkspaceRootRef, visibleRoots: [WorkspaceRootRef]) -> String {
        if visibleRoots.count <= 1 {
            return root.name
        }
        let canonicalMatches = visibleRoots.filter { $0.name.caseInsensitiveCompare(root.name) == .orderedSame }
        if canonicalMatches.count <= 1 {
            return root.name
        }

        let rootComponents = pathComponents(for: root.standardizedFullPath)
        for suffixLength in 2 ... max(2, rootComponents.count) {
            let suffix = rootComponents.suffix(suffixLength).joined(separator: "/")
            let matches = visibleRoots.filter {
                pathComponents(for: $0.standardizedFullPath).suffix(suffixLength).joined(separator: "/").caseInsensitiveCompare(suffix) == .orderedSame
            }
            if matches.count == 1 {
                return suffix
            }
        }
        return root.name
    }

    private static func pathComponents(for standardizedPath: String) -> [String] {
        standardizedPath
            .split(separator: "/")
            .map(String.init)
    }

    package static func displayPath(
        root: WorkspaceRootRef,
        relativePath: String,
        visibleRoots: [WorkspaceRootRef]
    ) -> String {
        let standardizedRelative = StandardizedPath.relative(relativePath)
        if visibleRoots.count <= 1 {
            return standardizedRelative.isEmpty ? root.name : standardizedRelative
        }

        let canonicalMatches = visibleRoots.filter { $0.name.caseInsensitiveCompare(root.name) == .orderedSame }
        if canonicalMatches.count == 1 {
            return standardizedRelative.isEmpty ? root.name : "\(root.name)/\(standardizedRelative)"
        }

        if standardizedRelative.isEmpty {
            return root.standardizedFullPath
        }
        return StandardizedPath.join(
            standardizedRoot: root.standardizedFullPath,
            standardizedRelativePath: standardizedRelative
        )
    }

    package static func displayAbsolutePath(
        fullPath: String,
        visibleRoots: [WorkspaceRootRef]
    ) -> String {
        let standardized = StandardizedPath.absolute(fullPath)
        let matchingRoot = visibleRoots
            .filter {
                let root = $0.standardizedFullPath
                return standardized == root || standardized.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        guard let root = matchingRoot else { return standardized }
        let relative = String(standardized.dropFirst(root.standardizedFullPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return displayPath(root: root, relativePath: relative, visibleRoots: visibleRoots)
    }
}
