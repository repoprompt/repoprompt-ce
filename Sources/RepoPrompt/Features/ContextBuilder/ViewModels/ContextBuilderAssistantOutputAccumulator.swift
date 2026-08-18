import Foundation

/// Accumulates Context Builder assistant output without repeatedly copying the full response.
/// Full output is materialized only when a terminal consumer requests it, while the compact
/// preview is maintained incrementally with the same whitespace/truncation semantics as the
/// previous whole-string implementation.
struct ContextBuilderAssistantOutputAccumulator {
    static let previewLimit = 160

    private var chunks: [String] = []
    private var lastContentMessageID: String?
    private var normalizedPreviewSuffix = ""
    private var normalizedCharacterCount = 0
    private var hasNormalizedContent = false
    private var pendingNormalizedWhitespace = false
    private var trailingNewlineCountCapped = 0

    private(set) var accumulatedCharacterCount = 0
    private(set) var fullOutputMaterializationCount = 0

    var preview: String? {
        guard hasNormalizedContent else { return nil }
        if normalizedCharacterCount <= Self.previewLimit {
            return normalizedPreviewSuffix
        }
        let suffixCount = max(Self.previewLimit - 1, 1)
        return "…" + String(normalizedPreviewSuffix.suffix(suffixCount))
    }

    @discardableResult
    mutating func append(_ delta: String, messageID: String? = nil) -> Bool {
        guard !delta.isEmpty else { return false }

        let previousPreview = preview
        let normalizedMessageID = messageID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentMessageID = normalizedMessageID?.isEmpty == false ? normalizedMessageID : nil
        let separator = boundarySeparator(next: delta, nextMessageID: contentMessageID)

        appendChunk(separator)
        appendChunk(delta)
        lastContentMessageID = contentMessageID
        return preview != previousPreview
    }

    @discardableResult
    mutating func replace(with output: String) -> Bool {
        let previousPreview = preview
        chunks = output.isEmpty ? [] : [output]
        lastContentMessageID = nil
        resetPreviewState()
        trailingNewlineCountCapped = 0
        processPreviewCharacters(in: output)
        updateTrailingNewlineCount(with: output)
        accumulatedCharacterCount = output.count
        return preview != previousPreview
    }

    mutating func fullOutput() -> String? {
        guard !chunks.isEmpty else { return nil }
        fullOutputMaterializationCount += 1
        return chunks.joined()
    }

    private mutating func appendChunk(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        chunks.append(chunk)
        accumulatedCharacterCount += chunk.count
        processPreviewCharacters(in: chunk)
        updateTrailingNewlineCount(with: chunk)
    }

    private func boundarySeparator(next: String, nextMessageID: String?) -> String {
        guard !chunks.isEmpty,
              let previousMessageID = lastContentMessageID,
              !previousMessageID.isEmpty,
              let nextMessageID,
              !nextMessageID.isEmpty,
              previousMessageID != nextMessageID
        else {
            return ""
        }

        let newlineCount = trailingNewlineCountCapped + leadingNewlineCount(in: next)
        guard newlineCount < 2 else { return "" }
        return String(repeating: "\n", count: 2 - newlineCount)
    }

    private func leadingNewlineCount(in text: String) -> Int {
        // Iterate UTF-8 bytes to avoid grapheme-cluster decoding on potentially
        // malformed bridged NSString values from LLM streaming chunks.
        // CRLF (\r
) is treated as a single newline, matching Swift's grapheme cluster behaviour.
        var count = 0
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x0A { // LF
                count += 1
                i += 1
            } else if byte == 0x0D { // CR
                count += 1
                i += 1
                if i < bytes.count, bytes[i] == 0x0A { i += 1 } // skip LF in CRLF
            } else {
                break
            }
            if count >= 2 { break }
        }
        return count
    }

    private mutating func updateTrailingNewlineCount(with text: String) {
        // Iterate UTF-8 bytes in reverse, treating \r\n as one newline.
        let bytes = Array(text.utf8)
        var suffixCount = 0
        var i = bytes.count - 1
        while i >= 0 {
            let byte = bytes[i]
            if byte == 0x0A { // LF — check for preceding CR
                if i > 0, bytes[i - 1] == 0x0D { i -= 1 } // consume CR of CRLF
                suffixCount += 1
                i -= 1
            } else if byte == 0x0D { // lone CR
                suffixCount += 1
                i -= 1
            } else {
                trailingNewlineCountCapped = suffixCount
                return
            }
            if suffixCount >= 2 {
                trailingNewlineCountCapped = 2
                return
            }
        }
        trailingNewlineCountCapped = min(2, trailingNewlineCountCapped + suffixCount)
    }

    private mutating func resetPreviewState() {
        normalizedPreviewSuffix = ""
        normalizedCharacterCount = 0
        hasNormalizedContent = false
        pendingNormalizedWhitespace = false
    }

    private mutating func processPreviewCharacters(in text: String) {
        // Iterate UTF-8 bytes to classify characters safely, avoiding grapheme-cluster
        // decoding on potentially malformed bridged NSString values from LLM stream chunks.
        // We reconstruct each Unicode scalar from its raw bytes and validate it before use.
        // Note: multi-scalar grapheme clusters (e.g. emoji with skin-tone modifiers) are
        // emitted as individual scalars in the preview — an acceptable approximation.
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]

            // Determine scalar byte width from the leading UTF-8 byte
            let width: Int
            if byte < 0x80 {
                width = 1
            } else if byte & 0xE0 == 0xC0 {
                width = 2
            } else if byte & 0xF0 == 0xE0 {
                width = 3
            } else if byte & 0xF8 == 0xF0 {
                width = 4
            } else {
                // Continuation byte or invalid leading byte — skip
                i += 1
                continue
            }

            // Ensure we have all bytes for this scalar; truncated tail means end of chunk
            guard i + width <= bytes.count else { break }

            let scalarBytes = Array(bytes[i ..< i + width])
            i += width

            // Construct a String from these UTF-8 bytes; skip if the sequence is invalid
            guard let scalarString = String(bytes: scalarBytes, encoding: .utf8),
                  let scalar = scalarString.unicodeScalars.first
            else { continue }

            // Classify ASCII whitespace: tab (0x09), LF (0x0A), VT (0x0B), FF (0x0C),
            // CR (0x0D), space (0x20). Do NOT treat all bytes ≤ 0x20 as whitespace.
            let isWhitespace = byte == 0x09 || byte == 0x0A || byte == 0x0B
                            || byte == 0x0C || byte == 0x0D || byte == 0x20
            if isWhitespace {
                if hasNormalizedContent {
                    pendingNormalizedWhitespace = true
                }
                continue
            }

            if pendingNormalizedWhitespace, hasNormalizedContent {
                appendNormalizedPreviewCharacter(" ")
            }
            pendingNormalizedWhitespace = false
            appendNormalizedPreviewCharacter(Character(scalar))
            hasNormalizedContent = true
        }
    }

    private mutating func appendNormalizedPreviewCharacter(_ character: Character) {
        normalizedCharacterCount += 1
        normalizedPreviewSuffix.append(character)
        if normalizedPreviewSuffix.count > Self.previewLimit {
            normalizedPreviewSuffix.removeFirst(normalizedPreviewSuffix.count - Self.previewLimit)
        }
    }
}
