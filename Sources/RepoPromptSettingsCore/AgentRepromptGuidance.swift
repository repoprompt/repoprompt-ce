import Foundation

/// User-editable wording preferences, never the rewriter's safety/output contract.
package enum AgentRepromptGuidance {
    package static let maximumUTF8Bytes = 16 * 1024
    package static let defaultText = """
    Rewrite my message so it is clear and direct for an implementing agent. Keep my intent, scope, voice, named entities and explicit constraints. Keep my wording where it already communicates well; improve organization rather than replacing my voice.

    Write natural Markdown. Use headings only when a long, multi-part message needs them. Include acceptance criteria only when I stated the outcomes.

    State what I said, plainly and with confidence. Do not guess at what I might mean, suggest files, or point out what I left unsaid.

    For a short, trivial or already-clear message, return it near-identically. Do not expand it into a formal task plan.
    """

    package static func normalizedOverride(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != defaultText else { return nil }
        return text
    }

    package static func effectiveText(_ override: String?) -> String {
        normalizedOverride(override) ?? defaultText
    }

    /// Oversized values are rejected by the editor, not silently truncated by persistence.
    package static func isWithinLimit(_ text: String) -> Bool {
        text.utf8.count <= maximumUTF8Bytes
    }
}
