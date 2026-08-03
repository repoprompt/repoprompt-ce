import Foundation

/// One-line verdict for every edit attempt (multi-edit only)
public struct EditOutcome: Codable, Equatable {
    public let index: Int // position in the `edits` array (0 for single-edit)
    public let status: String // "success" | "failed"
    public let error: String? // present when status == "failed"

    public init(index: Int, status: String, error: String?) {
        self.index = index
        self.status = status
        self.error = error
    }
}

/// Canonical data‑model consumed by `DiffBatchGenerator`.
public struct Edit {
    public let search: [String] // empty ⇒ full rewrite
    public let content: [String] // replacement block
    public let replaceAll: Bool // replace all occurrences (default: false)

    public init(search: [String], content: [String], replaceAll: Bool = false) {
        self.search = search
        self.content = content
        self.replaceAll = replaceAll
    }
}

/// High‑level utility that applies a batch of `{search,content}` edits to the
/// same file and returns the combined diff chunks **plus** per‑edit outcomes.
/// The `previews` return slot is retained for source compatibility and is empty.
package enum DiffBatchGenerator {
    package static func generate(
        originalLines orig: [String],
        edits: [Edit],
        precision prec: DiffPrecision,
        mcpAmbiguityCheck: Bool = false,
        tabPromotionEnabled: Bool = true
    ) async throws -> (chunks: [DiffChunk], outcomes: [EditOutcome], previews: [String]) {
        var cursor = DiffEditCursor()
        var outcomes: [EditOutcome] = []
        var allChunks: [DiffChunk] = []
        outcomes.reserveCapacity(edits.count)
        allChunks.reserveCapacity(edits.count)

        // Pre‑compute the high‑precision line‑index for first‑hit optimisation.
        var processed: [DiffGenerationUtility.LineData] = []
        processed.reserveCapacity(orig.count)
        for line in orig {
            processed.append(DiffGenerationUtility.processLine(line, precision: prec))
        }
        let indexMap = DiffGenerationUtility.buildLineIndexMapHigh(content: processed)

        for (idx, edit) in edits.enumerated() {
            do {
                let start = cursor.startLine(for: edit.search)

                // ✅ Sanitize replacement content (idempotent)
                let sanitizedContent = String.promoteEscapedTabsInEncodedLines(edit.content, enabled: tabPromotionEnabled)

                let diff = try await DiffGenerationUtility.generateDiff(
                    fileContent: orig,
                    lineIndexMap: start == 0 ? indexMap : nil, // optimisation only for first search
                    startSelector: nil,
                    endSelector: nil,
                    searchBlock: edit.search.isEmpty ? nil : edit.search,
                    newContent: sanitizedContent,
                    action: edit.search.isEmpty ? .rewrite : .modify,
                    diffPrecision: prec,
                    searchStartLine: start,
                    mcpAmbiguityCheck: edit.replaceAll ? false : mcpAmbiguityCheck,
                    replaceAll: edit.replaceAll,
                    tabPromotionEnabled: tabPromotionEnabled
                )

                guard !diff.isEmpty else {
                    throw DiffGenerationError.emptyContent
                }

                // Cursor bookkeeping
                cursor.advanceCursor(for: edit.search, firstChunk: diff.first)

                // Success bookkeeping
                allChunks.append(contentsOf: diff)
                outcomes.append(EditOutcome(index: idx, status: "success", error: nil))
            } catch {
                outcomes.append(EditOutcome(
                    index: idx,
                    status: "failed",
                    error: error.localizedDescription
                ))
            }
        }
        return (allChunks, outcomes, [])
    }
}
