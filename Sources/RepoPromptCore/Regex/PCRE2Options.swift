import CSwiftPCRE2

public struct PCRE2CompileOptions: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let utf = PCRE2CompileOptions(rawValue: rp_pcre2_option_utf_8())
    public static let unicodeProperties = PCRE2CompileOptions(rawValue: rp_pcre2_option_ucp_8())
    public static let caseless = PCRE2CompileOptions(rawValue: rp_pcre2_option_caseless_8())
    public static let multiline = PCRE2CompileOptions(rawValue: rp_pcre2_option_multiline_8())
    public static let dotMatchesNewline = PCRE2CompileOptions(rawValue: rp_pcre2_option_dotall_8())

    public static let defaultRegex: PCRE2CompileOptions = [.utf, .unicodeProperties]
}

public struct PCRE2MatchOptions: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let noUTFCheck = PCRE2MatchOptions(rawValue: rp_pcre2_option_no_utf_check_8())
    public static let notBOL = PCRE2MatchOptions(rawValue: rp_pcre2_option_notbol_8())
    public static let notEOL = PCRE2MatchOptions(rawValue: rp_pcre2_option_noteol_8())

    public static let trustedSwiftString: PCRE2MatchOptions = [.noUTFCheck]
}

public struct PCRE2MatchLimits: Sendable, Equatable {
    public let matchLimit: UInt32?
    public let depthLimit: UInt32?
    public let heapLimitKiB: UInt32?

    public init(matchLimit: UInt32? = nil, depthLimit: UInt32? = nil, heapLimitKiB: UInt32? = nil) {
        self.matchLimit = matchLimit
        self.depthLimit = depthLimit
        self.heapLimitKiB = heapLimitKiB
    }
}

public enum PCRE2JITMode: Sendable, Equatable {
    case disabled
    case auto
    case required
}
