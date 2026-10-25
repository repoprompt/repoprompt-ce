import Foundation

/// Validates one revision operand, not a Git option or a list of argv tokens.
/// Keep `--` for the revision/path boundary: placing it before a revision makes
/// commands such as diff and show interpret that revision as a path instead.
public enum GitRevisionArgument {
    public struct InvalidRevision: Error, LocalizedError, Sendable {
        public var errorDescription: String? {
            "Invalid Git revision operand: expected a nonempty revision, not an option or control characters."
        }
    }

    public static func validate(_ revision: String) throws {
        let trimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"),
              !revision.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw InvalidRevision()
        }
    }
}
