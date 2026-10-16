import Foundation
import RepoPromptSettingsCore

extension GitInclusion {
    static func fromMCPScope(_ raw: String?) -> GitInclusion? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "none":
            return .none
        case "selected":
            return .selected
        case "all":
            return .complete
        default:
            return nil
        }
    }
}
