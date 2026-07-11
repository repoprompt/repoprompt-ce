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
        var count = 0
        for character in text {
            guard character.isNewline else { break }
            count += 1
            if count >= 2 {
                break
            }
        }
        return count
    }

    private mutating func updateTrailingNewlineCount(with text: String) {
        var suffixCount = 0
        for character in text.reversed() {
            guard character.isNewline else {
                trailingNewlineCountCapped = suffixCount
                return
            }
            suffixCount += 1
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
        for character in text {
            if character.isWhitespace {
                if hasNormalizedContent {
                    pendingNormalizedWhitespace = true
                }
                continue
            }

            if pendingNormalizedWhitespace, hasNormalizedContent {
                appendNormalizedPreviewCharacter(" ")
            }
            pendingNormalizedWhitespace = false
            appendNormalizedPreviewCharacter(character)
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
