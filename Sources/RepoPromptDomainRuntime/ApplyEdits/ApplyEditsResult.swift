import Foundation

package enum ApplyEditsStatus: String, Equatable {
    case success
    case partial
    case failed
}

package struct ApplyEditsStats: Equatable {
    package let linesChanged: Int
    package let chunks: Int
}

package struct ApplyEditsLineStats: Equatable {
    package let addedLines: Int
    package let deletedLines: Int
}

package struct ApplyEditsResult: Equatable {
    package let updatedText: String
    package let diffChunks: [DiffChunk]
    package let unifiedDiff: String?
    package let toolCardUnifiedDiff: String?
    package let stats: ApplyEditsStats?
    package let note: String?
    package let fileCreated: Bool
    package let fileOverwritten: Bool
    package let editsRequested: Int
    package let editsApplied: Int
    package let status: ApplyEditsStatus
    package let outcomes: [EditOutcome]?

    package func withFileMetadata(created: Bool, overwritten: Bool) -> ApplyEditsResult {
        ApplyEditsResult(
            updatedText: updatedText,
            diffChunks: diffChunks,
            unifiedDiff: unifiedDiff,
            toolCardUnifiedDiff: toolCardUnifiedDiff,
            stats: stats,
            note: note,
            fileCreated: created,
            fileOverwritten: overwritten,
            editsRequested: editsRequested,
            editsApplied: editsApplied,
            status: status,
            outcomes: outcomes
        )
    }
}

package extension ApplyEditsResult {
    package func toolCardLineStats() -> ApplyEditsLineStats? {
        guard !diffChunks.isEmpty else { return nil }
        var addedLines = 0
        var deletedLines = 0
        for chunk in diffChunks {
            for line in chunk.lines {
                switch line.type {
                case .addition:
                    addedLines += 1
                case .removal:
                    deletedLines += 1
                case .context:
                    continue
                }
            }
        }
        return ApplyEditsLineStats(addedLines: addedLines, deletedLines: deletedLines)
    }

    /// UI-safe unified diff source:
    /// - Prefer explicit verbose diff when present.
    /// - Otherwise synthesize from applied diff chunks for tool-card rendering.
    package func unifiedDiffForToolCard(filePath: String) -> String? {
        if let toolCardUnifiedDiff, !toolCardUnifiedDiff.isEmpty {
            return toolCardUnifiedDiff
        }
        if let unifiedDiff, !unifiedDiff.isEmpty {
            return unifiedDiff
        }
        guard !diffChunks.isEmpty else { return nil }
        let decodedChunks = diffChunks.map { $0.withDecodedIndentation() }
        return UnifiedDiffGenerator.buildFromEditChunks(
            filePath: filePath,
            chunks: decodedChunks,
            startLineBase: .oneBased
        )
    }
}
