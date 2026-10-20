import Foundation

/// User-editable wording preferences, never the rewriter's safety/output contract.
package enum AgentRepromptGuidance {
    package static let maximumUTF8Bytes = 16 * 1024
    package static let defaultText = """
    Rewrite my message into a balanced task brief for an implementing agent. Preserve my intent, scope, important wording, named entities, uncertainty, and explicit constraints. Keep distinctive wording where it already communicates well; improve organization rather than replacing my voice unnecessarily.

    Cover the goal, constraints, acceptance criteria, relevant known context, assumptions, and open questions when the supplied information supports those sections. Omit empty sections. Acceptance criteria must restate outcomes I requested, not introduce new obligations.

    Never invent requirements, repository facts, APIs, files, deadlines, platform choices, or implementation decisions. Never prescribe implementation steps, architectures, testing requirements, migrations, or delegation unless I requested them. A clearer brief is not an implementation plan.

    Distinguish supplied facts from assumptions. Do not convert uncertainty into a requirement. Avoid assumptions where a question would materially change scope, safety, correctness, or the requested outcome.

    Ask only load-bearing questions that cannot reasonably be left open. Prefer a useful brief with explicit open questions over a long interview. Do not ask about information already supplied, or ask me to choose incidental implementation details.

    For a short or already-clear message, make minimal changes.

    Request repository context only when my message refers to code, behavior, or conventions you can't resolve from what I wrote. Prefer no context for clear requests, a focused Oracle question when the current selection likely has the answer, and Context Builder only when the relevant files are unknown. Use what you learn to name things the way the codebase does, not to add work I didn't ask for.
    """

    package static func normalizedOverride(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
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
