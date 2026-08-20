import Foundation

public enum ApplyEditsStatus: String, Equatable {
    case success
    case partial
    case failed
}

public struct ApplyEditsStats: Equatable {
    public let linesChanged: Int
    public let chunks: Int
}

public struct ApplyEditsLineStats: Equatable {
    public let addedLines: Int
    public let deletedLines: Int
}

public struct ApplyEditsResult: Equatable {
    public let updatedText: String
    public let diffChunks: [DiffChunk]
    public let unifiedDiff: String?
    public let toolCardUnifiedDiff: String?
    public let stats: ApplyEditsStats?
    public let note: String?
    public let fileCreated: Bool
    public let fileOverwritten: Bool
    public let editsRequested: Int
    public let editsApplied: Int
    public let status: ApplyEditsStatus
    public let outcomes: [EditOutcome]?

    public func withFileMetadata(created: Bool, overwritten: Bool) -> ApplyEditsResult {
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

public extension ApplyEditsResult {
    public func toolCardLineStats() -> ApplyEditsLineStats? {
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
    public func unifiedDiffForToolCard(filePath: String) -> String? {
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
