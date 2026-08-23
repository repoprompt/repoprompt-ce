import Foundation

/// Shared Codex service-tier eligibility used by both the desktop picker and
/// the headless composer catalog. Model availability still comes exclusively
/// from Codex app-server `model/list`; this type only derives the same tier
/// variants RepoPrompt Desktop exposes for those returned models.
public enum CodexServiceTierAvailability {
    public static let fastServiceTier = "fast"
    public static let fastCostWarningText = "Fast service tier uses your usage limits about 2× faster."

    public static func isFastEligible(baseModelID: String) -> Bool {
        guard let version = gptVersion(from: baseModelID) else { return false }
        return version.major > 5 || (version.major == 5 && version.minor >= 3)
    }

    private static func gptVersion(from baseModelID: String) -> (major: Int, minor: Int)? {
        let normalized = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("gpt-") else { return nil }

        let versionStart = normalized.index(normalized.startIndex, offsetBy: 4)
        var versionEnd = versionStart
        while versionEnd < normalized.endIndex {
            let character = normalized[versionEnd]
            guard character.isNumber || character == "." else { break }
            versionEnd = normalized.index(after: versionEnd)
        }

        let versionString = String(normalized[versionStart ..< versionEnd])
        let components = versionString.split(separator: ".", omittingEmptySubsequences: false)
        guard let majorString = components.first,
              let major = Int(majorString) else { return nil }
        let minor: Int
        if components.count > 1 {
            guard let parsedMinor = Int(components[1]) else { return nil }
            minor = parsedMinor
        } else {
            minor = 0
        }
        return (major, minor)
    }
}
