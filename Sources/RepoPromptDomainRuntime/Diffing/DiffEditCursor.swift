import Foundation

/// Lightweight utility that remembers, _per distinct processed search block_,
/// the next line from which a subsequent match should start.
/// The processed key is identical to the one used by `DiffGenerationUtility`.
package struct DiffEditCursor {
    /// processedKey → zero-based line where the next search for that key starts scanning (0 == from the top)
    private var map: [String: Int] = [:]

    /// Returns the correct `searchStartLine` for the **next** search of `raw`.
    mutating func startLine(for raw: [String]?) -> Int {
        guard let raw, !raw.isEmpty else { return 0 }
        return map[Self.key(from: raw)] ?? 0
    }

    /// Advances the key's scan position after a successful diff, from the supplied chunk (the last one for a replace-all).
    /// Unchanged matches emit no chunk, so this doesn't prove the key is exhausted.
    mutating func advanceCursor(for raw: [String]?, firstChunk: DiffChunk?) {
        guard
            let raw, !raw.isEmpty,
            let first = firstChunk
        else { return }

        let consumed = raw.count
        let k = Self.key(from: raw)
        map[k] = max(map[k] ?? 0, first.startLine + consumed)
    }

    // MARK: ‑ Internal helpers

    private static func key(from raw: [String]) -> String {
        raw.map {
            DiffGenerationUtility
                .processLine($0, precision: .high) // same normalisation as generator
                .removedTagsHigh
        }
        .joined(separator: "\n")
    }
}
