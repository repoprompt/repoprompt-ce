import Foundation

/// Stale-schema session index handling for ``HistorySessionScanner``.
///
/// Indexes whose `schemaVersion` differs from ``AgentSessionMetadataIndex/currentSchemaVersion``
/// are never decoded. A bounded head read identifies them cheaply so they do not consume the
/// inventory's index-count/byte budgets or trigger `workspace.json` identity reads, and they are
/// cached without records at zero estimated bytes.
extension HistorySessionScanner {
    /// Upper bound for the cheap stale-schema check. The writer emits `schemaVersion` first,
    /// so a few KB answers the question without reading or charging the full index.
    static let schemaVersionHeadSniffBytes = 4096

    /// Stale-schema entries keep no records and only the storage-directory identity, so they
    /// are cached at zero estimated bytes: thousands of them must not evict usable entries.
    func rememberStaleIndexScan(
        _ cacheKey: String,
        indexSignature: FileSignature,
        workspaceSignature: FileSignature?,
        identity: (name: String, id: UUID?),
        indexSchemaVersion: Int
    ) {
        rememberIndexScan(
            cacheKey,
            indexSignature: indexSignature,
            workspaceSignature: workspaceSignature,
            identity: identity,
            indexSchemaVersion: indexSchemaVersion,
            records: [],
            estimatedByteCount: 0
        )
    }

    /// Reads at most ``schemaVersionHeadSniffBytes`` and returns the first `schemaVersion`
    /// value only when it is complete inside that prefix. Because the full-data sniff also
    /// uses the first occurrence, a conclusive head answer matches it; `nil` means
    /// inconclusive and callers fall back to the full read.
    nonisolated func headSchemaVersionSniff(of fileURL: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: Self.schemaVersionHeadSniffBytes),
              !head.isEmpty
        else { return nil }
        return Self.schemaVersionSniff(
            in: String(decoding: head, as: UTF8.self),
            valueMayBeTruncated: head.count >= Self.schemaVersionHeadSniffBytes
        )
    }

    nonisolated func schemaVersionSniff(from data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.schemaVersionSniff(in: text, valueMayBeTruncated: false)
    }

    private static func schemaVersionSniff(in text: String, valueMayBeTruncated: Bool) -> Int? {
        guard let keyRange = text.range(of: "\"schemaVersion\"") else { return nil }
        guard let colon = text[keyRange.upperBound...].firstIndex(of: ":") else { return nil }
        var index = text.index(after: colon)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        let start = index
        while index < text.endIndex, text[index].isNumber || text[index] == "-" {
            index = text.index(after: index)
        }
        guard start < index else { return nil }
        if valueMayBeTruncated, index == text.endIndex { return nil }
        return Int(text[start ..< index])
    }
}
