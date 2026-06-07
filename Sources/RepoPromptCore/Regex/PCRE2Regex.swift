import CSwiftPCRE2

public final class PCRE2Regex: @unchecked Sendable {
    /// A reusable, single-consumer matching session.
    ///
    /// A session may be reused across multiple subjects to avoid per-match allocation
    /// churn, but it owns mutable PCRE2 match state and is not thread-safe. Do not use
    /// the same session concurrently from multiple tasks or threads.
    public final class MatchSession {
        fileprivate let regex: PCRE2Regex
        fileprivate let matchData: OpaquePointer
        fileprivate let matchContext: OpaquePointer?

        fileprivate init(regex: PCRE2Regex, matchLimits: PCRE2MatchLimits?) throws {
            let createdMatchData = try regex.makeMatchData()
            do {
                let createdMatchContext = try regex.makeMatchContext(limits: matchLimits)
                self.regex = regex
                matchData = createdMatchData
                matchContext = createdMatchContext
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

        public func firstMatch(
            in subject: String,
            startOffset: Int = 0,
            options: PCRE2MatchOptions = .trustedSwiftString
        ) throws -> PCRE2Match? {
            try regex.withSubjectBuffer(for: subject) { buffer in
                try regex.match(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext)
            }
        }

        public func firstMatch(
            in subject: Substring,
            startOffset: Int = 0,
            options: PCRE2MatchOptions = .trustedSwiftString
        ) throws -> PCRE2Match? {
            try regex.withSubjectBuffer(for: subject) { buffer in
                try regex.match(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext)
            }
        }

        public func containsMatch(
            in subject: String,
            startOffset: Int = 0,
            options: PCRE2MatchOptions = .trustedSwiftString
        ) throws -> Bool {
            try regex.withSubjectBuffer(for: subject) { buffer in
                try regex.containsMatch(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext)
            }
        }

        public func containsMatch(
            in subject: Substring,
            startOffset: Int = 0,
            options: PCRE2MatchOptions = .trustedSwiftString
        ) throws -> Bool {
            try regex.withSubjectBuffer(for: subject) { buffer in
                try regex.containsMatch(in: buffer, startOffset: startOffset, options: options, matchData: matchData, matchContext: matchContext)
            }
        }
    }

    public let pattern: String
    public let compileOptions: PCRE2CompileOptions
    public let jitStatus: PCRE2JITStatus

    private let code: OpaquePointer

    public init(
        _ pattern: String,
        options: PCRE2CompileOptions = .defaultRegex,
        jit: PCRE2JITMode = .auto
    ) throws {
        self.pattern = pattern
        compileOptions = options

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

        code = compiled
        jitStatus = resolvedJITStatus
    }

    deinit {
        rp_pcre2_code_free_8(code)
    }

    public func withMatchSession<R>(
        matchLimits: PCRE2MatchLimits? = nil,
        _ body: (MatchSession) throws -> R
    ) throws -> R {
        let session = try MatchSession(regex: self, matchLimits: matchLimits)
        return try body(session)
    }

    public func firstMatch(
        in subject: String,
        options: PCRE2MatchOptions = .trustedSwiftString,
        matchLimits: PCRE2MatchLimits? = nil
    ) throws -> PCRE2Match? {
        try withMatchSession(matchLimits: matchLimits) { session in
            try session.firstMatch(in: subject, options: options)
        }
    }

    public func firstMatch(
        in subject: Substring,
        options: PCRE2MatchOptions = .trustedSwiftString,
        matchLimits: PCRE2MatchLimits? = nil
    ) throws -> PCRE2Match? {
        try withMatchSession(matchLimits: matchLimits) { session in
            try session.firstMatch(in: subject, options: options)
        }
    }

    public func enumerateMatches(
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

        for index in 0 ..< count {
            let lower = Int(ovector[index * 2])
            let upper = Int(ovector[index * 2 + 1])
            if lower == unset || upper == unset {
                ranges.append(nil)
            } else {
                ranges.append(lower ..< upper)
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

public struct PCRE2LinePrefilter: Sendable, Equatable {
    public let asciiRequiredAlternatives: [String]
    public let caseInsensitive: Bool

    public init(asciiRequiredAlternatives: [String], caseInsensitive: Bool) {
        self.asciiRequiredAlternatives = asciiRequiredAlternatives
        self.caseInsensitive = caseInsensitive
    }
}

public struct PCRE2LineScanOptions: Sendable, Equatable {
    public let maxLineUTF8Length: Int?
    public let collectMatches: Bool
    public let maxCollectedMatches: Int?
    public let cancellationCheckStride: Int
    public let prefilter: PCRE2LinePrefilter?

    public init(
        maxLineUTF8Length: Int? = nil,
        collectMatches: Bool = true,
        maxCollectedMatches: Int? = nil,
        cancellationCheckStride: Int = 256,
        prefilter: PCRE2LinePrefilter? = nil
    ) {
        self.maxLineUTF8Length = maxLineUTF8Length
        self.collectMatches = collectMatches
        self.maxCollectedMatches = maxCollectedMatches
        self.cancellationCheckStride = max(1, cancellationCheckStride)
        self.prefilter = prefilter
    }
}

public struct PCRE2LineScanResult: Sendable, Equatable {
    public let matchingLineNumbers: [Int]
    public let lineMatchCount: Int

    public init(matchingLineNumbers: [Int], lineMatchCount: Int) {
        self.matchingLineNumbers = matchingLineNumbers
        self.lineMatchCount = lineMatchCount
    }
}

public struct PCRE2LineRangeHit: Sendable, Equatable {
    public let lineNumber: Int
    public let byteRange: Range<Int>

    public init(lineNumber: Int, byteRange: Range<Int>) {
        self.lineNumber = lineNumber
        self.byteRange = byteRange
    }
}

public struct PCRE2LineRangeScanResult: Sendable, Equatable {
    public let hits: [PCRE2LineRangeHit]
    public let lineMatchCount: Int

    public init(hits: [PCRE2LineRangeHit], lineMatchCount: Int) {
        self.hits = hits
        self.lineMatchCount = lineMatchCount
    }
}

public enum PCRE2LineMode: Sendable, Equatable {
    case crlf
}

public struct PCRE2ASCIIMarkerLinePattern: Sendable, Equatable {
    private static let speculativeCollectCapacity = 64
    private static let maximumRequestedCollectCapacity = 16384

    public let marker: String
    public let digitCount: UInt32
    public let requiredPrefix: String
    public let caseInsensitive: Bool
    private let markerBytes: [UInt8]
    private let requiredPrefixBytes: [UInt8]

    public init?(marker: String, digitCount: UInt32, requiredPrefix: String, caseInsensitive: Bool) {
        guard digitCount > 0,
              !marker.isEmpty,
              !requiredPrefix.isEmpty,
              marker.utf8.allSatisfy({ PCRE2ASCIIWholeWordLiteral.isASCIIWordByte($0) }),
              requiredPrefix.utf8.allSatisfy({ PCRE2ASCIIWholeWordLiteral.isASCIIWordByte($0) })
        else {
            return nil
        }
        self.marker = marker
        self.digitCount = digitCount
        self.requiredPrefix = requiredPrefix
        self.caseInsensitive = caseInsensitive
        markerBytes = marker.utf8.map { caseInsensitive ? PCRE2ASCIIWholeWordLiteral.asciiLowercase($0) : $0 }
        requiredPrefixBytes = requiredPrefix.utf8.map { caseInsensitive ? PCRE2ASCIIWholeWordLiteral.asciiLowercase($0) : $0 }
    }

    public func countMatchingLines(in subject: String) -> Int? {
        scanMatchingLines(in: subject, collectMatches: false)?.lineMatchCount
    }

    public func scanMatchingLineRanges(
        in subject: String,
        maxCollectedMatches: Int,
        shouldCancel: () -> Bool = { false }
    ) -> PCRE2LineRangeScanResult? {
        guard maxCollectedMatches > 0 else { return PCRE2LineRangeScanResult(hits: [], lineMatchCount: 0) }
        if shouldCancel() { return PCRE2LineRangeScanResult(hits: [], lineMatchCount: 0) }
        guard !markerBytes.isEmpty, !requiredPrefixBytes.isEmpty else { return nil }

        func scan(_ buffer: UnsafeBufferPointer<UInt8>) -> PCRE2LineRangeScanResult? {
            func collect(capacity requestedCapacity: Int) -> PCRE2LineRangeScanResult? {
                let capacity = max(0, min(maxCollectedMatches, requestedCapacity))
                var lineNumbers = Array(repeating: 0, count: capacity)
                var lineStarts = Array(repeating: 0, count: capacity)
                var lineEnds = Array(repeating: 0, count: capacity)
                var collectedCount = 0
                var lineCount = 0
                var nonASCII: Int32 = 0
                let rc = lineNumbers.withUnsafeMutableBufferPointer { lineNumberBuffer in
                    lineStarts.withUnsafeMutableBufferPointer { lineStartBuffer in
                        lineEnds.withUnsafeMutableBufferPointer { lineEndBuffer in
                            markerBytes.withUnsafeBufferPointer { markerBuffer in
                                requiredPrefixBytes.withUnsafeBufferPointer { prefixBuffer in
                                    withPCRE2BytePointer(for: buffer) { subjectBase in
                                        withPCRE2BytePointer(for: markerBuffer) { markerBase in
                                            withPCRE2BytePointer(for: prefixBuffer) { prefixBase in
                                                rp_pcre2_ascii_marker_line_range_scan_8(
                                                    subjectBase,
                                                    buffer.count,
                                                    markerBase,
                                                    markerBuffer.count,
                                                    digitCount,
                                                    prefixBase,
                                                    prefixBuffer.count,
                                                    caseInsensitive ? 1 : 0,
                                                    lineNumberBuffer.baseAddress,
                                                    lineStartBuffer.baseAddress,
                                                    lineEndBuffer.baseAddress,
                                                    lineNumberBuffer.count,
                                                    &collectedCount,
                                                    &lineCount,
                                                    &nonASCII
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                guard rc == 0, nonASCII == 0 else { return nil }
                let hits = (0 ..< collectedCount).map { index in
                    PCRE2LineRangeHit(lineNumber: lineNumbers[index], byteRange: lineStarts[index] ..< lineEnds[index])
                }
                return PCRE2LineRangeScanResult(hits: hits, lineMatchCount: lineCount)
            }

            let speculativeCapacity = min(maxCollectedMatches, Self.speculativeCollectCapacity)
            guard let speculative = collect(capacity: speculativeCapacity) else { return nil }
            if speculative.lineMatchCount <= speculativeCapacity || speculativeCapacity == maxCollectedMatches {
                return speculative
            }
            return collect(capacity: min(maxCollectedMatches, speculative.lineMatchCount))
        }

        if let contiguous = subject.utf8.withContiguousStorageIfAvailable({ buffer in
            scan(buffer)
        }) {
            return contiguous
        }
        let bytes = Array(subject.utf8)
        return bytes.withUnsafeBufferPointer { scan($0) }
    }

    public func scanMatchingLines(
        in subject: String,
        collectMatches: Bool,
        maxCollectedMatches: Int? = nil,
        shouldCancel: () -> Bool = { false }
    ) -> PCRE2LineScanResult? {
        if shouldCancel() { return PCRE2LineScanResult(matchingLineNumbers: [], lineMatchCount: 0) }
        guard !markerBytes.isEmpty, !requiredPrefixBytes.isEmpty else { return nil }

        func scan(_ buffer: UnsafeBufferPointer<UInt8>) -> PCRE2LineScanResult? {
            var lineCount = 0
            var nonASCII: Int32 = 0

            func runScan(lineNumbers: UnsafeMutablePointer<Int>?, capacity: Int, collectedCount: inout Int) -> Int32 {
                markerBytes.withUnsafeBufferPointer { markerBuffer in
                    requiredPrefixBytes.withUnsafeBufferPointer { prefixBuffer in
                        withPCRE2BytePointer(for: buffer) { subjectBase in
                            withPCRE2BytePointer(for: markerBuffer) { markerBase in
                                withPCRE2BytePointer(for: prefixBuffer) { prefixBase in
                                    rp_pcre2_ascii_marker_line_scan_8(
                                        subjectBase,
                                        buffer.count,
                                        markerBase,
                                        markerBuffer.count,
                                        digitCount,
                                        prefixBase,
                                        prefixBuffer.count,
                                        caseInsensitive ? 1 : 0,
                                        lineNumbers,
                                        capacity,
                                        &collectedCount,
                                        &lineCount,
                                        &nonASCII
                                    )
                                }
                            }
                        }
                    }
                }
            }

            func countOnlyResult() -> PCRE2LineScanResult? {
                var ignoredCollectedCount = 0
                lineCount = 0
                nonASCII = 0
                let rc = runScan(lineNumbers: nil, capacity: 0, collectedCount: &ignoredCollectedCount)
                guard rc == 0, nonASCII == 0 else { return nil }
                return PCRE2LineScanResult(matchingLineNumbers: [], lineMatchCount: lineCount)
            }

            func collectResult(capacity: Int) -> PCRE2LineScanResult? {
                guard capacity > 0 else { return countOnlyResult() }
                var collectedLines = Array(repeating: 0, count: capacity)
                var collectedCount = 0
                lineCount = 0
                nonASCII = 0
                let rc = collectedLines.withUnsafeMutableBufferPointer { lineBuffer in
                    runScan(lineNumbers: lineBuffer.baseAddress, capacity: lineBuffer.count, collectedCount: &collectedCount)
                }
                guard rc == 0, nonASCII == 0 else { return nil }
                return PCRE2LineScanResult(matchingLineNumbers: Array(collectedLines.prefix(collectedCount)), lineMatchCount: lineCount)
            }

            guard collectMatches else { return countOnlyResult() }
            if let maxCollectedMatches {
                guard maxCollectedMatches > 0 else { return countOnlyResult() }
                if maxCollectedMatches > Self.maximumRequestedCollectCapacity {
                    guard let counted = countOnlyResult() else { return nil }
                    let exactCapacity = min(maxCollectedMatches, counted.lineMatchCount)
                    guard exactCapacity > 0 else { return counted }
                    return collectResult(capacity: exactCapacity)
                }
                return collectResult(capacity: maxCollectedMatches)
            }

            guard let speculative = collectResult(capacity: Self.speculativeCollectCapacity) else { return nil }
            if speculative.lineMatchCount <= Self.speculativeCollectCapacity {
                return speculative
            }
            return collectResult(capacity: speculative.lineMatchCount)
        }

        if let contiguous = subject.utf8.withContiguousStorageIfAvailable({ buffer in
            scan(buffer)
        }) {
            return contiguous
        }
        let bytes = Array(subject.utf8)
        return bytes.withUnsafeBufferPointer { scan($0) }
    }
}

public struct PCRE2ASCIIWholeWordLiteral: Sendable, Equatable {
    public let needle: String
    public let caseInsensitive: Bool

    public init?(needle: String, caseInsensitive: Bool) {
        guard !needle.isEmpty,
              needle.utf8.allSatisfy({ PCRE2ASCIIWholeWordLiteral.isASCIIWordByte($0) })
        else {
            return nil
        }
        self.needle = needle
        self.caseInsensitive = caseInsensitive
    }

    public func countMatchingLines(in subject: String) -> Int? {
        scanMatchingLines(in: subject, collectMatches: false)?.lineMatchCount
    }

    public func scanMatchingLines(
        in subject: String,
        lineMode: PCRE2LineMode = .crlf,
        collectMatches: Bool,
        maxCollectedMatches: Int? = nil,
        cancellationCheckStride: Int = 256,
        shouldCancel: () -> Bool = { false }
    ) -> PCRE2LineScanResult? {
        guard lineMode == .crlf else { return nil }
        if collectMatches, subject.utf8.count > Self.cScanCollectByteLimit {
            return nil
        }
        if shouldCancel() { return PCRE2LineScanResult(matchingLineNumbers: [], lineMatchCount: 0) }
        let needleBytes = needle.utf8.map { caseInsensitive ? Self.asciiLowercase($0) : $0 }
        guard !needleBytes.isEmpty else { return nil }

        func scan(_ buffer: UnsafeBufferPointer<UInt8>) -> PCRE2LineScanResult? {
            var lineCount = 0
            var nonASCII: Int32 = 0

            func runScan(lineNumbers: UnsafeMutablePointer<Int>?, capacity: Int, collectedCount: inout Int) -> Int32 {
                needleBytes.withUnsafeBufferPointer { needleBuffer in
                    withPCRE2BytePointer(for: buffer) { subjectBase in
                        withPCRE2BytePointer(for: needleBuffer) { needleBase in
                            rp_pcre2_ascii_whole_word_line_scan_8(
                                subjectBase,
                                buffer.count,
                                needleBase,
                                needleBuffer.count,
                                caseInsensitive ? 1 : 0,
                                lineNumbers,
                                capacity,
                                &collectedCount,
                                &lineCount,
                                &nonASCII
                            )
                        }
                    }
                }
            }

            var ignoredCollectedCount = 0
            let countRC = runScan(lineNumbers: nil, capacity: 0, collectedCount: &ignoredCollectedCount)
            guard countRC == 0, nonASCII == 0 else { return nil }
            guard collectMatches, lineCount > 0 else {
                return PCRE2LineScanResult(matchingLineNumbers: [], lineMatchCount: lineCount)
            }

            let capacity = min(maxCollectedMatches ?? lineCount, lineCount)
            guard capacity > 0 else {
                return PCRE2LineScanResult(matchingLineNumbers: [], lineMatchCount: lineCount)
            }

            var collectedLines = Array(repeating: 0, count: capacity)
            var collectedCount = 0
            lineCount = 0
            nonASCII = 0
            let collectRC = collectedLines.withUnsafeMutableBufferPointer { lineBuffer in
                runScan(lineNumbers: lineBuffer.baseAddress, capacity: lineBuffer.count, collectedCount: &collectedCount)
            }
            guard collectRC == 0, nonASCII == 0 else { return nil }
            return PCRE2LineScanResult(
                matchingLineNumbers: Array(collectedLines.prefix(collectedCount)),
                lineMatchCount: lineCount
            )
        }

        if let contiguous = subject.utf8.withContiguousStorageIfAvailable({ buffer in
            scan(buffer)
        }) {
            return contiguous
        }
        let bytes = Array(subject.utf8)
        return bytes.withUnsafeBufferPointer { scan($0) }
    }

    private static let cScanCollectByteLimit = 4 * 1024 * 1024

    private static func matchesWholeWordNeedle(
        at index: Int,
        in buffer: UnsafeBufferPointer<UInt8>,
        lineStart: Int,
        needle: [UInt8],
        caseInsensitive: Bool
    ) -> Bool {
        let first = caseInsensitive ? asciiLowercase(buffer[index]) : buffer[index]
        guard first == needle[0] else { return false }
        if needle.count > 1 {
            for offset in 1 ..< needle.count {
                let byte = buffer[index + offset]
                if byte == 10 || byte == 13 { return false }
                let hay = caseInsensitive ? asciiLowercase(byte) : byte
                if hay != needle[offset] { return false }
            }
        }

        let previousIsWord = index > lineStart && isASCIIWordByte(buffer[index - 1])
        let nextIndex = index + needle.count
        let nextIsWord = nextIndex < buffer.count && buffer[nextIndex] != 10 && buffer[nextIndex] != 13 && isASCIIWordByte(buffer[nextIndex])
        return !previousIsWord && !nextIsWord
    }

    private static func lineContainsWholeWordNeedle(
        _ buffer: UnsafeBufferPointer<UInt8>,
        range: Range<Int>,
        needle: [UInt8],
        caseInsensitive: Bool
    ) -> Bool {
        let count = needle.count
        guard count > 0, range.count >= count else { return false }
        var index = range.lowerBound
        let lastStart = range.upperBound - count
        while index <= lastStart {
            let current = caseInsensitive ? asciiLowercase(buffer[index]) : buffer[index]
            if current == needle[0] {
                var matched = true
                if count > 1 {
                    for offset in 1 ..< count {
                        let hay = caseInsensitive ? asciiLowercase(buffer[index + offset]) : buffer[index + offset]
                        if hay != needle[offset] {
                            matched = false
                            break
                        }
                    }
                }
                if matched {
                    let previousIsWord = index > range.lowerBound && isASCIIWordByte(buffer[index - 1])
                    let nextIndex = index + count
                    let nextIsWord = nextIndex < range.upperBound && isASCIIWordByte(buffer[nextIndex])
                    if !previousIsWord, !nextIsWord {
                        return true
                    }
                }
            }
            index += 1
        }
        return false
    }

    fileprivate static func isASCIIWordByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95
    }

    fileprivate static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }
}

public struct PCRE2AnchoredDeclarationLinePattern: Sendable, Equatable {
    public let caseInsensitive: Bool

    public init(caseInsensitive: Bool) {
        self.caseInsensitive = caseInsensitive
    }

    public func scanMatchingLines(
        in subject: String,
        collectMatches: Bool,
        maxCollectedMatches: Int? = nil,
        cancellationCheckStride: Int = 256,
        shouldCancel: () -> Bool = { false }
    ) -> PCRE2LineScanResult? {
        if subject.utf8.count <= Self.cScanByteLimit {
            return scanMatchingLinesWithC(
                in: subject,
                collectMatches: collectMatches,
                maxCollectedMatches: maxCollectedMatches,
                shouldCancel: shouldCancel
            )
        }
        return scanMatchingLinesWithSwift(
            in: subject,
            collectMatches: collectMatches,
            maxCollectedMatches: maxCollectedMatches,
            cancellationCheckStride: cancellationCheckStride,
            shouldCancel: shouldCancel
        )
    }

    private func scanMatchingLinesWithC(
        in subject: String,
        collectMatches: Bool,
        maxCollectedMatches: Int?,
        shouldCancel: () -> Bool
    ) -> PCRE2LineScanResult? {
        if shouldCancel() { return PCRE2LineScanResult(matchingLineNumbers: [], lineMatchCount: 0) }

        func scan(_ buffer: UnsafeBufferPointer<UInt8>) -> PCRE2LineScanResult? {
            var lineCount = 0
            var fallbackRequired: Int32 = 0

            func runScan(lineNumbers: UnsafeMutablePointer<Int>?, capacity: Int, collectedCount: inout Int) -> Int32 {
                withPCRE2BytePointer(for: buffer) { subjectBase in
                    rp_pcre2_ascii_declaration_line_scan_8(
                        subjectBase,
                        buffer.count,
                        caseInsensitive ? 1 : 0,
                        lineNumbers,
                        capacity,
                        &collectedCount,
                        &lineCount,
                        &fallbackRequired
                    )
                }
            }

            var ignoredCollectedCount = 0
            let countRC = runScan(lineNumbers: nil, capacity: 0, collectedCount: &ignoredCollectedCount)
            guard countRC == 0, fallbackRequired == 0 else { return nil }
            guard collectMatches, lineCount > 0 else {
                return PCRE2LineScanResult(matchingLineNumbers: [], lineMatchCount: lineCount)
            }

            let capacity = min(maxCollectedMatches ?? lineCount, lineCount)
            guard capacity > 0 else {
                return PCRE2LineScanResult(matchingLineNumbers: [], lineMatchCount: lineCount)
            }

            var collectedLines = Array(repeating: 0, count: capacity)
            var collectedCount = 0
            lineCount = 0
            fallbackRequired = 0
            let collectRC = collectedLines.withUnsafeMutableBufferPointer { lineBuffer in
                runScan(lineNumbers: lineBuffer.baseAddress, capacity: lineBuffer.count, collectedCount: &collectedCount)
            }
            guard collectRC == 0, fallbackRequired == 0 else { return nil }
            return PCRE2LineScanResult(
                matchingLineNumbers: Array(collectedLines.prefix(collectedCount)),
                lineMatchCount: lineCount
            )
        }

        if let contiguous = subject.utf8.withContiguousStorageIfAvailable({ buffer in
            scan(buffer)
        }) {
            return contiguous
        }
        let bytes = Array(subject.utf8)
        return bytes.withUnsafeBufferPointer { scan($0) }
    }

    private func scanMatchingLinesWithSwift(
        in subject: String,
        collectMatches: Bool,
        maxCollectedMatches: Int?,
        cancellationCheckStride: Int,
        shouldCancel: () -> Bool
    ) -> PCRE2LineScanResult? {
        guard subject.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        var matchingLines: [Int] = []
        if collectMatches { matchingLines.reserveCapacity(8) }
        var matchCount = 0

        func scan(_ buffer: UnsafeBufferPointer<UInt8>) {
            forEachPCRE2CRLFLine(in: buffer) { lineNumber, range in
                if lineNumber % max(1, cancellationCheckStride) == 0, shouldCancel() {
                    return false
                }
                if Self.matchesDeclarationLine(buffer, range: range, caseInsensitive: caseInsensitive) {
                    matchCount += 1
                    if collectMatches, maxCollectedMatches.map({ matchingLines.count < $0 }) ?? true {
                        matchingLines.append(lineNumber)
                    }
                }
                return true
            }
        }

        var usedContiguousStorage = false
        subject.utf8.withContiguousStorageIfAvailable { buffer in
            usedContiguousStorage = true
            scan(buffer)
        }
        if !usedContiguousStorage {
            let bytes = Array(subject.utf8)
            bytes.withUnsafeBufferPointer { scan($0) }
        }

        return PCRE2LineScanResult(matchingLineNumbers: matchingLines, lineMatchCount: matchCount)
    }

    private static let cScanByteLimit = 4 * 1024 * 1024

    private static func matchesDeclarationLine(_ buffer: UnsafeBufferPointer<UInt8>, range: Range<Int>, caseInsensitive: Bool) -> Bool {
        var index = range.lowerBound
        while index < range.upperBound, isHorizontalWhitespace(buffer[index]) {
            index += 1
        }

        let saved = index
        if consumeWord("final", in: buffer, range: range, index: &index, caseInsensitive: caseInsensitive) {
            guard index < range.upperBound, isHorizontalWhitespace(buffer[index]) else { return false }
            repeat {
                index += 1
            } while index < range.upperBound && isHorizontalWhitespace(buffer[index])
        } else {
            index = saved
        }

        let matchedKeyword = consumeWord("class", in: buffer, range: range, index: &index, caseInsensitive: caseInsensitive)
            || consumeWord("struct", in: buffer, range: range, index: &index, caseInsensitive: caseInsensitive)
            || consumeWord("func", in: buffer, range: range, index: &index, caseInsensitive: caseInsensitive)
        guard matchedKeyword,
              index < range.upperBound,
              isHorizontalWhitespace(buffer[index]) else { return false }
        repeat {
            index += 1
        } while index < range.upperBound && isHorizontalWhitespace(buffer[index])
        guard index < range.upperBound else {
            return false
        }
        let first = buffer[index]
        guard (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95 else { return false }
        return true
    }

    private static func consumeWord(_ word: String, in buffer: UnsafeBufferPointer<UInt8>, range: Range<Int>, index: inout Int, caseInsensitive: Bool) -> Bool {
        let start = index
        for expected in word.utf8 {
            guard index < range.upperBound else { index = start
                return false
            }
            let hay = caseInsensitive ? PCRE2ASCIIWholeWordLiteral.asciiLowercase(buffer[index]) : buffer[index]
            guard hay == expected else { index = start
                return false
            }
            index += 1
        }
        return true
    }

    private static func isHorizontalWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case 9, 11, 12, 32:
            true
        default:
            false
        }
    }
}

public struct PCRE2PathSuffixPattern: Sendable, Equatable {
    public let suffixes: [String]
    public let basenamePrefix: String?
    public let singleDigitRange: ClosedRange<UInt8>?

    public init(suffixes: [String], basenamePrefix: String? = nil, singleDigitRange: ClosedRange<UInt8>? = nil) {
        self.suffixes = suffixes
        self.basenamePrefix = basenamePrefix
        self.singleDigitRange = singleDigitRange
    }

    public func matches(_ candidate: String, caseInsensitive: Bool) -> Bool {
        let haystack = caseInsensitive ? candidate.lowercased() : candidate
        let basenameStart = haystack.lastIndex(of: "/").map { haystack.index(after: $0) } ?? haystack.startIndex
        let basename = haystack[basenameStart...]
        for suffix in suffixes {
            let effectiveSuffix = caseInsensitive ? suffix.lowercased() : suffix
            if let basenamePrefix {
                let effectivePrefix = caseInsensitive ? basenamePrefix.lowercased() : basenamePrefix
                if let singleDigitRange {
                    for digit in singleDigitRange {
                        let scalar = UnicodeScalar(Int(digit)) ?? UnicodeScalar(48)!
                        if basename.hasSuffix(effectivePrefix + String(scalar) + effectiveSuffix) {
                            return true
                        }
                    }
                    continue
                }
                if basename.hasSuffix(effectivePrefix + effectiveSuffix) {
                    return true
                }
                continue
            }
            if haystack.hasSuffix(effectiveSuffix) {
                return true
            }
        }
        return false
    }
}

public extension PCRE2Regex.MatchSession {
    func scanMatchingLines(
        in subject: String,
        options: PCRE2LineScanOptions,
        shouldCancel: () -> Bool = { false }
    ) throws -> PCRE2LineScanResult {
        let prefilterNeedles = options.prefilter?.preparedNeedles() ?? []
        var matchingLines: [Int] = []
        if options.collectMatches {
            matchingLines.reserveCapacity(8)
        }
        var matchCount = 0
        var cancelled = false

        try regex.withSubjectBuffer(for: subject) { buffer in
            try forEachPCRE2CRLFLine(in: buffer) { lineNumber, range in
                if lineNumber % options.cancellationCheckStride == 0, shouldCancel() {
                    cancelled = true
                    return false
                }
                if let maxLineUTF8Length = options.maxLineUTF8Length, range.count > maxLineUTF8Length {
                    return true
                }
                if !prefilterNeedles.isEmpty, !lineContainsAnyPrefilterNeedle(buffer, range: range, needles: prefilterNeedles, caseInsensitive: options.prefilter?.caseInsensitive ?? false) {
                    return true
                }
                let base = buffer.baseAddress?.advanced(by: range.lowerBound)
                let lineBuffer = UnsafeBufferPointer(start: base, count: range.count)
                if try regex.containsMatch(in: lineBuffer, startOffset: 0, options: .trustedSwiftString, matchData: matchData, matchContext: matchContext) {
                    matchCount += 1
                    if options.collectMatches, options.maxCollectedMatches.map({ matchingLines.count < $0 }) ?? true {
                        matchingLines.append(lineNumber)
                    }
                }
                return true
            }
        }

        if cancelled {
            return PCRE2LineScanResult(matchingLineNumbers: matchingLines, lineMatchCount: matchCount)
        }
        return PCRE2LineScanResult(matchingLineNumbers: matchingLines, lineMatchCount: matchCount)
    }
}

private extension PCRE2LinePrefilter {
    func preparedNeedles() -> [[UInt8]] {
        asciiRequiredAlternatives.compactMap { alternative in
            let bytes = alternative.utf8.map { caseInsensitive ? PCRE2ASCIIWholeWordLiteral.asciiLowercase($0) : $0 }
            guard !bytes.isEmpty, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
            return bytes
        }
    }
}

private func lineContainsAnyPrefilterNeedle(
    _ buffer: UnsafeBufferPointer<UInt8>,
    range: Range<Int>,
    needles: [[UInt8]],
    caseInsensitive: Bool
) -> Bool {
    for needle in needles {
        guard range.count >= needle.count else { continue }
        var index = range.lowerBound
        let lastStart = range.upperBound - needle.count
        while index <= lastStart {
            var matched = true
            for offset in 0 ..< needle.count {
                let hay = caseInsensitive ? PCRE2ASCIIWholeWordLiteral.asciiLowercase(buffer[index + offset]) : buffer[index + offset]
                if hay != needle[offset] {
                    matched = false
                    break
                }
            }
            if matched { return true }
            index += 1
        }
    }
    return false
}

@discardableResult
private func forEachPCRE2CRLFLine(
    in buffer: UnsafeBufferPointer<UInt8>,
    _ body: (Int, Range<Int>) throws -> Bool
) rethrows -> Bool {
    guard buffer.count > 0 else { return true }

    var lineNumber = 0
    var lineStart = 0
    var index = 0
    while index < buffer.count {
        let byte = buffer[index]
        if byte == 10 || byte == 13 {
            if try !body(lineNumber, lineStart ..< index) {
                return false
            }
            lineNumber += 1
            index += 1
            if byte == 13, index < buffer.count, buffer[index] == 10 {
                index += 1
            }
            lineStart = index
        } else {
            index += 1
        }
    }

    if lineStart < buffer.count {
        return try body(lineNumber, lineStart ..< buffer.count)
    }
    return true
}

private func withPCRE2BytePointer<R>(
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
            "JIT mode is disabled"
        case let .unavailable(reason):
            reason
        case let .compiled(sizeBytes):
            "compiled (\(sizeBytes) bytes)"
        case let .fallback(errorCode, message):
            "JIT compile failed (\(errorCode)): \(message)"
        }
    }
}
