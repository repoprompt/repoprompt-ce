import Foundation

enum GitWorktreeDisplayLabelHumanizer {
    static func displayLabel(for rawLabel: String?) -> String? {
        guard let trimmed = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return humanizedAppManagedAgentLabel(trimmed) ?? trimmed
    }

    static func seededVisualIdentityLabel(
        sessionName: String?,
        worktreeName: String?,
        branch: String?,
        isMain: Bool
    ) -> String? {
        if let sessionLabel = meaningfulSessionLabel(sessionName) {
            return sessionLabel
        }
        if let label = displayLabel(for: worktreeName) ?? displayLabel(for: branch) {
            return label
        }
        return isMain ? "main" : nil
    }

    static func humanizedAppManagedAgentLabel(_ rawLabel: String) -> String? {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder: Substring
        if trimmed.hasPrefix("rp-agent-") {
            remainder = trimmed.dropFirst("rp-agent-".count)
        } else if trimmed.hasPrefix("rp/agent/") {
            remainder = trimmed.dropFirst("rp/agent/".count)
        } else {
            return nil
        }

        var parts = remainder.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let shortID = parts.removeFirst()
        guard isPlannerComponent(shortID), shortID.count == 8 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }

        if let suffix = parts.last, isNumericCollisionSuffix(suffix) {
            parts.removeLast()
        }
        if let suffix = parts.last, isShortHashComponent(suffix), parts.count > 1 {
            parts.removeLast()
        }
        guard !parts.isEmpty else { return nil }

        let slug = parts.joined(separator: "-")
        return slug == "agent" ? shortID : slug
    }

    private static func meaningfulSessionLabel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let defaultTitles: Set = ["Agent Session", "New Chat", "New Session"]
        guard !defaultTitles.contains(trimmed) else { return nil }
        return cappedSessionLabel(trimmed)
    }

    private static func cappedSessionLabel(_ label: String) -> String {
        let limit = 24
        guard label.count > limit else { return label }
        let hardLimit = label.index(label.startIndex, offsetBy: limit)
        if let boundary = label[..<hardLimit].lastIndex(where: { $0.isWhitespace || $0 == "-" || $0 == "_" }),
           label.distance(from: label.startIndex, to: boundary) >= 12
        {
            let prefix = label[..<boundary]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_")))
            if !prefix.isEmpty {
                return prefix
            }
        }
        return String(label[..<hardLimit])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPlannerComponent(_ value: String) -> Bool {
        value.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func isShortHashComponent(_ value: String) -> Bool {
        value.count == 8 && value.unicodeScalars.allSatisfy { scalar in
            (48 ... 57).contains(scalar.value) || (65 ... 70).contains(scalar.value) || (97 ... 102).contains(scalar.value)
        }
    }

    private static func isNumericCollisionSuffix(_ value: String) -> Bool {
        guard let number = Int(value), number >= 2 else { return false }
        return String(number) == value
    }
}
