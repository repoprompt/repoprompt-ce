import CSwiftPCRE2

package enum PCRE2BuildConfiguration: Sendable {
	/// True when PCRE2 was compiled with build-time JIT support.
	///
	/// Runtime JIT compilation may still fall back because executable memory or a
	/// specific pattern is unavailable/unsupported, but this must remain true for
	/// JIT-capable wrapper builds.
	package static var isJITSupported: Bool {
		rp_pcre2_config_jit_8() == 1
	}
}

package enum PCRE2JITStatus: Sendable, Equatable {
	case disabled
	case unavailable(reason: String)
	case compiled(sizeBytes: Int)
	case fallback(errorCode: Int32, message: String)

	package var isCompiled: Bool {
		if case .compiled = self { return true }
		return false
	}
}
