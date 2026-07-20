import CSwiftPCRE2

package struct PCRE2CompileOptions: OptionSet, Sendable {
	package let rawValue: UInt32

	package init(rawValue: UInt32) {
		self.rawValue = rawValue
	}

	package static let utf = PCRE2CompileOptions(rawValue: rp_pcre2_option_utf_8())
	package static let unicodeProperties = PCRE2CompileOptions(rawValue: rp_pcre2_option_ucp_8())
	package static let caseless = PCRE2CompileOptions(rawValue: rp_pcre2_option_caseless_8())
	package static let multiline = PCRE2CompileOptions(rawValue: rp_pcre2_option_multiline_8())
	package static let dotMatchesNewline = PCRE2CompileOptions(rawValue: rp_pcre2_option_dotall_8())

	package static let defaultRegex: PCRE2CompileOptions = [.utf, .unicodeProperties]
}
package struct PCRE2MatchOptions: OptionSet, Sendable {
	package let rawValue: UInt32

	package init(rawValue: UInt32) {
		self.rawValue = rawValue
	}

	package static let noUTFCheck = PCRE2MatchOptions(rawValue: rp_pcre2_option_no_utf_check_8())
	package static let notBOL = PCRE2MatchOptions(rawValue: rp_pcre2_option_notbol_8())
	package static let notEOL = PCRE2MatchOptions(rawValue: rp_pcre2_option_noteol_8())

	package static let trustedSwiftString: PCRE2MatchOptions = [.noUTFCheck]
}

package struct PCRE2MatchLimits: Sendable, Equatable {
	package let matchLimit: UInt32?
	package let depthLimit: UInt32?
	package let heapLimitKiB: UInt32?

	package init(matchLimit: UInt32? = nil, depthLimit: UInt32? = nil, heapLimitKiB: UInt32? = nil) {
		self.matchLimit = matchLimit
		self.depthLimit = depthLimit
		self.heapLimitKiB = heapLimitKiB
	}
}

package enum PCRE2JITMode: Sendable, Equatable {
	case disabled
	case auto
	case required
}
