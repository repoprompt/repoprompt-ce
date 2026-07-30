import CSwiftPCRE2

/// Thread-safe compiled PCRE2 pattern.
///
/// Safety invariant for `@unchecked Sendable`: initialization, including JIT
/// compilation, completes before publication and the compiled `pcre2_code` is
/// immutable afterward. Every ordinary match allocates independent match data
/// and context. A live call retains this instance, so deinitialization cannot
/// race with matching. `MatchSession` owns mutable match state, is deliberately
/// not `Sendable`, and must remain confined to one sequential consumer.
package final class PCRE2Regex: @unchecked Sendable {
	/// A reusable, single-consumer matching session.
	///
	/// A session may be reused across multiple subjects to avoid per-match allocation
	/// churn, but it owns mutable PCRE2 match state and is not thread-safe. Do not use
	/// the same session concurrently from multiple tasks or threads.
	package final class MatchSession {
		fileprivate let regex: PCRE2Regex
		fileprivate let matchData: OpaquePointer
		fileprivate let matchContext: OpaquePointer?

		fileprivate init(regex: PCRE2Regex, matchLimits: PCRE2MatchLimits?) throws {
			let createdMatchData = try regex.makeMatchData()
			do {
				let createdMatchContext = try regex.makeMatchContext(limits: matchLimits)
				self.regex = regex
				self.matchData = createdMatchData
				self.matchContext = createdMatchContext
			} catch {
				rp_pcre2_match_data_free_8(createdMatchData)
				throw error
			}
		}

		deinit {
			rp_pcre2_match_data_free_8(matchData)
			if let matchContext {
				rp_pcre2_match_context_free_8(matchContext)
			}
		}

		package func firstMatch(
			in subject: String,
			startOffset: Int = 0,
			options: PCRE2MatchOptions = .trustedSwiftString
		) throws -> PCRE2Match? {
			try regex.withSubjectBuffer(for: subject) { buffer in
				try regex.match(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext)
			}
		}

		package func firstMatch(
			in subject: Substring,
			startOffset: Int = 0,
			options: PCRE2MatchOptions = .trustedSwiftString
		) throws -> PCRE2Match? {
			try regex.withSubjectBuffer(for: subject) { buffer in
				try regex.match(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext)
			}
		}

		package func containsMatch(
			in subject: String,
			startOffset: Int = 0,
			options: PCRE2MatchOptions = .trustedSwiftString
		) throws -> Bool {
			try regex.withSubjectBuffer(for: subject) { buffer in
				try regex.containsMatch(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext)
			}
		}

		package func containsMatch(
			in subject: Substring,
			startOffset: Int = 0,
			options: PCRE2MatchOptions = .trustedSwiftString
		) throws -> Bool {
			try regex.withSubjectBuffer(for: subject) { buffer in
				try regex.containsMatch(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext)
			}
		}

		/// Runs `body` synchronously while the subject's UTF-8 storage is valid.
		///
		/// The buffer must not escape this closure. No task or actor hop occurs.
		package func withSubjectUTF8Buffer<R>(
			for subject: String,
			_ body: (UnsafeBufferPointer<UInt8>) throws -> R
		) throws -> R {
			try regex.withSubjectBuffer(for: subject, body)
		}

		/// Matches against a closure-scoped UTF-8 buffer using this session's
		/// single-consumer mutable match state.
		package func containsMatch(
			inUTF8Buffer buffer: UnsafeBufferPointer<UInt8>,
			startOffset: Int = 0,
			options: PCRE2MatchOptions = .trustedSwiftString
		) throws -> Bool {
			try regex.containsMatch(
				in: buffer,
				startOffset: startOffset,
				options: options,
				matchData: matchData,
				matchContext: matchContext
			)
		}
	}

	package let pattern: String
	package let compileOptions: PCRE2CompileOptions
	package let jitStatus: PCRE2JITStatus

	private let code: OpaquePointer

	package init(
		_ pattern: String,
		options: PCRE2CompileOptions = .defaultRegex,
		jit: PCRE2JITMode = .auto
	) throws {
		self.pattern = pattern
		self.compileOptions = options

		var errorCode: Int32 = 0
		var errorOffset = 0
		let patternBytes = Array(pattern.utf8)
		let compiled: OpaquePointer? = patternBytes.withUnsafeBufferPointer { pointer in
			withPCRE2BytePointer(for: pointer) { base in
				rp_pcre2_compile_8(base, pointer.count, options.rawValue, &errorCode, &errorOffset)
			}
		}

		guard let compiled else {
			throw PCRE2Error.compile(
				pattern: pattern,
				offset: errorOffset,
				code: errorCode,
				message: pcre2ErrorMessage(errorCode)
			)
		}

		let resolvedJITStatus: PCRE2JITStatus
		switch jit {
		case .disabled:
			resolvedJITStatus = .disabled
		case .auto, .required:
			let status = Self.compileJITIfPossible(compiled)
			switch (jit, status) {
			case (.required, .compiled):
				resolvedJITStatus = status
			case (.required, .disabled), (.required, .unavailable), (.required, .fallback):
				rp_pcre2_code_free_8(compiled)
				throw PCRE2Error.jitRequiredButUnavailable(status.descriptionForRequiredMode)
			default:
				resolvedJITStatus = status
			}
		}

		self.code = compiled
		self.jitStatus = resolvedJITStatus
	}

	deinit {
		rp_pcre2_code_free_8(code)
	}

	package func withMatchSession<R>(
		matchLimits: PCRE2MatchLimits? = nil,
		_ body: (MatchSession) throws -> R
	) throws -> R {
		let session = try MatchSession(regex: self, matchLimits: matchLimits)
		return try body(session)
	}

	package func firstMatch(
		in subject: String,
		options: PCRE2MatchOptions = .trustedSwiftString,
		matchLimits: PCRE2MatchLimits? = nil
	) throws -> PCRE2Match? {
		try withMatchSession(matchLimits: matchLimits) { session in
			try session.firstMatch(in: subject, options: options)
		}
	}

	package func firstMatch(
		in subject: Substring,
		options: PCRE2MatchOptions = .trustedSwiftString,
		matchLimits: PCRE2MatchLimits? = nil
	) throws -> PCRE2Match? {
		try withMatchSession(matchLimits: matchLimits) { session in
			try session.firstMatch(in: subject, options: options)
		}
	}

	package func enumerateMatches(
		in subject: String,
		options: PCRE2MatchOptions = .trustedSwiftString,
		limit: Int? = nil,
		matchLimits: PCRE2MatchLimits? = nil,
		_ body: (PCRE2Match) throws -> Bool
	) throws {
		let byteCount = subject.utf8.count
		var startOffset = 0
		var emitted = 0

		let matchData = try makeMatchData()
		defer { rp_pcre2_match_data_free_8(matchData) }

		let matchContext = try makeMatchContext(limits: matchLimits)
		defer {
			if let matchContext {
				rp_pcre2_match_context_free_8(matchContext)
			}
		}

		try withSubjectBuffer(for: subject) { buffer in
			while startOffset <= byteCount {
				if let limit, emitted >= limit { return }
				guard let match = try match(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext) else {
					return
				}

				emitted += 1
				let shouldContinue = try body(match)
				if !shouldContinue { return }

				if match.byteRange.isEmpty {
					let next = Self.nextUTF8ScalarBoundary(in: subject, after: startOffset)
					if next <= startOffset { return }
					startOffset = next
				} else {
					startOffset = match.byteRange.upperBound
				}
			}
		}
	}

	private func withSubjectBuffer<R>(
		for subject: String,
		_ body: (UnsafeBufferPointer<UInt8>) throws -> R
	) throws -> R {
		if let result = try subject.utf8.withContiguousStorageIfAvailable({ buffer in
			try body(buffer)
		}) {
			return result
		}

		let subjectBytes = Array(subject.utf8)
		return try subjectBytes.withUnsafeBufferPointer { buffer in
			try body(buffer)
		}
	}

	private func withSubjectBuffer<R>(
		for subject: Substring,
		_ body: (UnsafeBufferPointer<UInt8>) throws -> R
	) throws -> R {
		if let result = try subject.utf8.withContiguousStorageIfAvailable({ buffer in
			try body(buffer)
		}) {
			return result
		}

		let subjectBytes = Array(subject.utf8)
		return try subjectBytes.withUnsafeBufferPointer { buffer in
			try body(buffer)
		}
	}

	private func makeMatchData() throws -> OpaquePointer {
		guard let matchData = rp_pcre2_match_data_create_from_pattern_8(code) else {
			throw PCRE2Error.internalInvariant("pcre2_match_data_create_from_pattern returned nil")
		}
		return matchData
	}

	private func makeMatchContext(limits: PCRE2MatchLimits?) throws -> OpaquePointer? {
		guard let limits else { return nil }
		guard let context = rp_pcre2_match_context_create_8() else {
			throw PCRE2Error.internalInvariant("pcre2_match_context_create returned nil")
		}

		do {
			if let limit = limits.matchLimit {
				try applyMatchContextLimit(rp_pcre2_set_match_limit_8(context, limit), name: "match")
			}
			if let limit = limits.depthLimit {
				try applyMatchContextLimit(rp_pcre2_set_depth_limit_8(context, limit), name: "depth")
			}
			if let limit = limits.heapLimitKiB {
				try applyMatchContextLimit(rp_pcre2_set_heap_limit_8(context, limit), name: "heap")
			}
			return context
		} catch {
			rp_pcre2_match_context_free_8(context)
			throw error
		}
	}

	private func applyMatchContextLimit(_ rc: Int32, name: String) throws {
		guard rc == 0 else {
			throw PCRE2Error.internalInvariant("pcre2_set_\(name)_limit failed (\(rc)): \(pcre2ErrorMessage(rc))")
		}
	}

	private func match(
		in buffer: UnsafeBufferPointer<UInt8>,
		startOffset: Int,
		options: PCRE2MatchOptions,
		matchData: OpaquePointer,
		matchContext: OpaquePointer?
	) throws -> PCRE2Match? {
		let rc = rawMatchReturnCode(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext)

		if rc == rp_pcre2_error_nomatch_8() {
			return nil
		}
		guard rc >= 0 else {
			throw Self.matchError(for: rc)
		}

		let count = Int(rp_pcre2_get_ovector_count_8(matchData))
		guard let ovector = rp_pcre2_get_ovector_pointer_8(matchData) else {
			throw PCRE2Error.internalInvariant("pcre2_get_ovector_pointer returned nil")
		}
		let unset = Int(rp_pcre2_unset_8())
		var ranges: [Range<Int>?] = []
		ranges.reserveCapacity(count)

		for index in 0..<count {
			let lower = Int(ovector[index * 2])
			let upper = Int(ovector[index * 2 + 1])
			if lower == unset || upper == unset {
				ranges.append(nil)
			} else {
				ranges.append(lower..<upper)
			}
		}

		guard let fullRange = ranges.first ?? nil else {
			throw PCRE2Error.internalInvariant("match succeeded without a full-match range")
		}
		return PCRE2Match(byteRange: fullRange, captureByteRanges: ranges)
	}

	private func containsMatch(
		in buffer: UnsafeBufferPointer<UInt8>,
		startOffset: Int,
		options: PCRE2MatchOptions,
		matchData: OpaquePointer,
		matchContext: OpaquePointer?
	) throws -> Bool {
		let rc = rawMatchReturnCode(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext)

		if rc == rp_pcre2_error_nomatch_8() {
			return false
		}
		guard rc >= 0 else {
			throw Self.matchError(for: rc)
		}
		return true
	}

	private func rawMatchReturnCode(
		in buffer: UnsafeBufferPointer<UInt8>,
		startOffset: Int,
		options: PCRE2MatchOptions,
		matchData: OpaquePointer,
		matchContext: OpaquePointer?
	) -> Int32 {
		withPCRE2BytePointer(for: buffer) { base in
			if jitStatus.isCompiled {
				let jitRC = rp_pcre2_jit_match_with_context_8(code, base, buffer.count, startOffset, options.rawValue, matchData, matchContext)
				if jitRC != rp_pcre2_error_jit_badoption_8() {
					return jitRC
				}
			}
			return rp_pcre2_match_with_context_8(code, base, buffer.count, startOffset, options.rawValue, matchData, matchContext)
		}
	}

	private static func matchError(for code: Int32) -> PCRE2Error {
		let message = pcre2ErrorMessage(code)
		if let kind = limitKind(for: code) {
			return .matchLimitExceeded(kind: kind, code: code, message: message)
		}
		return .match(code: code, message: message)
	}

	private static func limitKind(for code: Int32) -> PCRE2LimitKind? {
		if code == rp_pcre2_error_matchlimit_8() {
			return .match
		}
		if code == rp_pcre2_error_depthlimit_8() {
			return .depth
		}
		if code == rp_pcre2_error_heaplimit_8() {
			return .heap
		}
		if code == rp_pcre2_error_jit_stacklimit_8() {
			return .jitStack
		}
		return nil
	}

	private static func compileJITIfPossible(_ code: OpaquePointer) -> PCRE2JITStatus {
		let configured = rp_pcre2_config_jit_8()
		if configured <= 0 {
			return .unavailable(reason: configured == 0 ? "PCRE2 was built without JIT support" : pcre2ErrorMessage(configured))
		}

		let rc = rp_pcre2_jit_compile_8(code, rp_pcre2_jit_complete_8())
		guard rc == 0 else {
			return .fallback(errorCode: rc, message: pcre2ErrorMessage(rc))
		}

		var size = 0
		let infoRC = rp_pcre2_jit_size_8(code, &size)
		guard infoRC == 0 else {
			return .fallback(errorCode: infoRC, message: pcre2ErrorMessage(infoRC))
		}
		if size > 0 {
			return .compiled(sizeBytes: size)
		}
		return .unavailable(reason: "PCRE2 accepted JIT compilation but reported no JIT code size")
	}

	private static func nextUTF8ScalarBoundary(in subject: String, after byteOffset: Int) -> Int {
		let byteCount = subject.utf8.count
		if byteOffset >= byteCount { return byteCount }

		var lower = 0
		for scalar in subject.unicodeScalars {
			let upper = lower + scalar.utf8.count
			if byteOffset < upper {
				return upper
			}
			lower = upper
		}
		return byteCount
	}
}


package func withPCRE2BytePointer<R>(
	for buffer: UnsafeBufferPointer<UInt8>,
	_ body: (UnsafePointer<UInt8>) -> R
) -> R {
	if let base = buffer.baseAddress {
		return body(base)
	}
	var emptyByte: UInt8 = 0
	return withUnsafePointer(to: &emptyByte) { pointer in
		body(pointer)
	}
}

private extension PCRE2JITStatus {
	var descriptionForRequiredMode: String {
		switch self {
		case .disabled:
			return "JIT mode is disabled"
		case let .unavailable(reason):
			return reason
		case let .compiled(sizeBytes):
			return "compiled (\(sizeBytes) bytes)"
		case let .fallback(errorCode, message):
			return "JIT compile failed (\(errorCode)): \(message)"
		}
	}
}
