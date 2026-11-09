import Foundation

/// User-editable rewrite guidance, separate from the rewriter's input-safety/output protocol.
package enum AgentRepromptGuidance {
    package static let maximumUTF8Bytes = 16 * 1024
    package static let defaultText = """
    Clarify my message without changing the task. Unpack clearly implied meaning when thin; compress repetition when sprawling; minimally edit clear messages. Short does not mean incomplete.

    Preserve every ask, constraint, condition, permission, priority and uncertainty. Keep questions distinct from actions. Keep names, identifiers and quotes exact. Remove venting without losing the problem or urgency.

    Never invent facts, requirements, solutions, steps, tests or success criteria. Use the shortest sufficient Markdown: no fixed template, duplicated sections, unsolicited suggestions or commentary. Delete anything that adds work or merely adds words.
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
