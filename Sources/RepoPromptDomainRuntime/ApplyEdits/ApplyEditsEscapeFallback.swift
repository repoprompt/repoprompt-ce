import Foundation

package struct ApplyEditsEscapeFallback {
    private let decoder: EscapeDecoder
    private let mode: EscapeDecodingMode

    package init(decoder: EscapeDecoder = EscapeDecoder(), mode: EscapeDecodingMode = .cStyle) {
        self.decoder = decoder
        self.mode = mode
    }

    package func resolveSingle(search: String, replace: String, in originalText: String) -> (search: String, replace: String, usedFallback: Bool) {
        resolve(search: search, replace: replace, in: originalText)
    }

    package func resolveBatch(edits: [ApplyEditsOperation], in originalText: String) -> (edits: [ApplyEditsOperation], usedFallbackCount: Int) {
        var fallbackCount = 0
        let resolvedEdits = edits.map { edit in
            let resolved = resolve(search: edit.search, replace: edit.replace, in: originalText)
            if resolved.usedFallback {
                fallbackCount += 1
            }
            if resolved.search == edit.search, resolved.replace == edit.replace {
                return edit
            }
            return ApplyEditsOperation(search: resolved.search, replace: resolved.replace, replaceAll: edit.replaceAll)
        }
        return (resolvedEdits, fallbackCount)
    }

    private func resolve(search: String, replace: String, in originalText: String) -> (search: String, replace: String, usedFallback: Bool) {
        guard !search.isEmpty else {
            return (search, replace, false)
        }
        if originalText.contains(search) {
            return (search, replace, false)
        }
        guard search.contains("\\") else {
            return (search, replace, false)
        }

        let decodedSearch = decoder.decode(search, mode: mode)
        guard decodedSearch != search else {
            return (search, replace, false)
        }
        guard originalText.contains(decodedSearch) else {
            return (search, replace, false)
        }

        let decodedReplace = decoder.decode(replace, mode: mode)
        return (decodedSearch, decodedReplace, true)
    }
}
