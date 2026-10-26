/// Comparison keys for the existing preset dirty-indicator String ports.
/// Core path values are absolute/relative syntax keys, not checked-file roles.
/// This is not a file lookup, a root binding or a native identity producer.
package enum WorkspacePresetSelectionComparison {
    private enum PathKey: Hashable {
        case absolute(WorkspaceAbsolutePath)
        case relative(WorkspaceRelativePath)
        /// Legacy relative dot normalization can produce the empty root spelling.
        case emptyRelative
    }

    package static func normalizedLegacyComparisonPath(_ rawPath: String) -> String? {
        guard !rawPath.isEmpty, !StandardizedPath.containsNUL(rawPath) else { return nil }
        // Retain the preset format's existing lexical and legacy tilde grammar.
        // Filename whitespace is native text, not human field framing.
        let standardized = StandardizedPath.absolute(rawPath)
        if standardized.hasPrefix("/") {
            return standardized
        }
        return StandardizedPath.relative(rawPath)
    }

    package static func isDirty(
        presetPaths: [String],
        selectionPaths: [(absolute: String, relative: String)]
    ) -> Bool {
        do {
            var presetKeys = Set<PathKey>()
            for rawPath in presetPaths {
                // Preserve legacy omission of explicitly empty entries.
                if rawPath.isEmpty { continue }
                guard let normalized = normalizedLegacyComparisonPath(rawPath) else { return true }
                try presetKeys.insert(key(normalized))
            }

            var selectionKeys = Set<PathKey>()
            var eachSelection: [[PathKey]] = []
            for path in selectionPaths {
                var keys: [PathKey] = []
                if !path.absolute.isEmpty {
                    try keys.append(.absolute(WorkspaceAbsolutePath.nativeText(path.absolute)))
                }
                try keys.append(
                    path.relative.isEmpty
                        ? .emptyRelative
                        : .relative(WorkspaceRelativePath.nativeText(path.relative))
                )
                selectionKeys.formUnion(keys)
                eachSelection.append(keys)
            }

            let presetCovered = presetKeys.isSubset(of: selectionKeys)
            let selectionCovered = eachSelection.allSatisfy { keys in
                keys.contains { presetKeys.contains($0) }
            }
            return !(presetCovered && selectionCovered)
        } catch {
            // Existing syntax factories reject NUL/malformed absolute or relative text. Such a
            // represented input cannot certify that the selection matches.
            return true
        }
    }

    private static func key(_ normalizedPath: String) throws -> PathKey {
        if normalizedPath.hasPrefix("/") {
            return try .absolute(WorkspaceAbsolutePath.nativeText(normalizedPath))
        }
        if normalizedPath.isEmpty { return .emptyRelative }
        return try .relative(WorkspaceRelativePath.nativeText(normalizedPath))
    }
}
