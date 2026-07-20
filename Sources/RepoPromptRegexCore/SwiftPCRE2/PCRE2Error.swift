import CSwiftPCRE2
import Foundation

package enum PCRE2LimitKind: Sendable, Equatable {
	case match
	case depth
	case heap
	case jitStack

	var description: String {
		switch self {
		case .match:
			return "MATCHLIMIT"
		case .depth:
			return "DEPTHLIMIT"
		case .heap:
			return "HEAPLIMIT"
		case .jitStack:
			return "JIT_STACKLIMIT"
		}
	}
}

package enum PCRE2Error: Error, LocalizedError, Sendable, Equatable {
	case compile(pattern: String, offset: Int, code: Int32, message: String)
	case match(code: Int32, message: String)
	case matchLimitExceeded(kind: PCRE2LimitKind, code: Int32, message: String)
	case jitRequiredButUnavailable(String)
	case internalInvariant(String)

	package var errorDescription: String? {
		switch self {
		case let .compile(pattern, offset, code, message):
			return "PCRE2 compile error at byte offset \(offset) for pattern \(String(reflecting: pattern)) (\(code)): \(message)"
		case let .match(code, message):
			return "PCRE2 match error (\(code)): \(message)"
		case let .matchLimitExceeded(kind, code, message):
			return "PCRE2 match limit exceeded (\(kind.description), \(code)): \(message)"
		case let .jitRequiredButUnavailable(message):
			return "PCRE2 JIT required but unavailable: \(message)"
		case let .internalInvariant(message):
			return "PCRE2 wrapper invariant failed: \(message)"
		}
	}
}

internal func pcre2ErrorMessage(_ code: Int32) -> String {
	var buffer = [UInt8](repeating: 0, count: 512)
	let rc = buffer.withUnsafeMutableBufferPointer { pointer in
		rp_pcre2_get_error_message_8(Int32(code), pointer.baseAddress, pointer.count)
	}
	guard rc >= 0 else {
		return "unknown PCRE2 error \(code)"
	}
	let length = buffer.firstIndex(of: 0) ?? Int(rc)
	return String(decoding: buffer[..<length], as: UTF8.self)
}
