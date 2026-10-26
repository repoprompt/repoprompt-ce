import Foundation

package enum RepoPromptRegexRuntime {
    package static var pcre2JITMode: PCRE2JITMode {
        pcre2JITMode(
            from: ProcessInfo.processInfo.environment["REPOPROMPT_PCRE2_JIT"]
        )
    }

    package static func pcre2JITMode(from rawValue: String?) -> PCRE2JITMode {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "0", "false", "off", "no", "disable", "disabled":
            return .disabled
        case "require", "required":
            return .required
        default:
            return .auto
        }
    }
}
