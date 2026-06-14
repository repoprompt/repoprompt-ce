import Foundation

// Wildmatch flags for pattern matching
private let WM_NOESCAPE: UInt32 = 0x01
private let WM_PATHNAME: UInt32 = 0x02
private let WM_CASEFOLD: UInt32 = 0x10 // must match wildmatch.h
private let WM_WILDSTAR: UInt32 = 0x40 // must match wildmatch.h
private let WM_MATCH: Int32 = 0

// MARK: - Regex Engine Selection

/// Represents the regex engines used by file search.
private enum RegexEngine {
    case pcre2(PCRE2Regex)
    case asciiWholeWord(PCRE2ASCIIWholeWordLiteral)
    case anchoredDeclaration(PCRE2AnchoredDeclarationLinePattern, PCRE2Regex)
    case asciiMarker(PCRE2ASCIIMarkerLinePattern, RepoPromptPCRE2CompileRequest)
}

private final class PCRE2RegexBox: NSObject {
    let regex: PCRE2Regex

    init(regex: PCRE2Regex) {
        self.regex = regex
    }
}

// MARK: - Regex Cache for Performance Optimization

/// Caches compiled PCRE2 patterns used by file search fast paths.
private actor RegexCache {
    static let pcre2Compiled: NSCache<NSString, PCRE2RegexBox> = {
        let cache = NSCache<NSString, PCRE2RegexBox>()
        cache.countLimit = 256
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func pcre2Regex(for request: RepoPromptPCRE2CompileRequest) throws -> PCRE2Regex {
        let key = "\(request.pattern)|\(request.caseInsensitive)|\(request.multilineAnchors)|\(request.jitMode)" as NSString

        if let cached = pcre2Compiled.object(forKey: key) {
            return cached.regex
        }

        let regex = try RepoPromptPCRE2Adapter.compile(request)
        pcre2Compiled.setObject(
            PCRE2RegexBox(regex: regex),
            forKey: key,
            cost: estimatedCost(for: request)
        )
        return regex
    }

    private static func estimatedCost(for request: RepoPromptPCRE2CompileRequest) -> Int {
        max(16 * 1024, request.pattern.utf8.count * 4)
    }
}

/// One matching line in a file.
///
/// `lineNumber` is **0‑based** (the first line in the file is numbered `0`).
/// MCP tool output converts to 1-based line numbers for display (`file_search`),
/// while internal indexing stays 0-based for array operations.
struct SearchMatch: Hashable, Codable {
    let filePath: String
    let lineNumber: Int // 0‑based
    let lineText: String // original text (no newline)
    let contextBefore: [String]? // Lines before the match (when contextLines > 0)
    let contextAfter: [String]? // Lines after the match (when contextLines > 0)

    init(filePath: String, lineNumber: Int, lineText: String, contextBefore: [String]? = nil, contextAfter: [String]? = nil) {
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

// MARK: – NEW unified-search support –––––––––––––––––––––––––––––––––

/**
 Search strategy requested by the caller.

 * `.auto`    – decide heuristically (path vs content vs both – see FileSearchActor).
 * `.path`    – search **only** file paths.
 * `.content` – search **only** inside files.
 * `.both`    – execute *both* path and content search stages.
 */
enum SearchMode: String, Codable {
    case auto, path, content, both
}

/// Enhanced search options for fine-grained control
struct SearchOptions {
    var mode: SearchMode = .auto
    var caseInsensitive: Bool = true
    var wholeWord: Bool = false
    var includeExtensions: [String] = [] // e.g., [".js", ".ts", ".swift"]
    var excludePatterns: [String] = [] // e.g., ["node_modules", ".git", "*.log"]
    var contextLines: Int = 0 // Number of lines before/after match
    var maxResults: Int = 250
    var countOnly: Bool = false
    var fuzzySpaceMatching: Bool = true // Enable/disable fuzzy space matching
    var allowLiteralUnescapeFallback: Bool = true // Helpful rescue for over-escaped literals in auto flows
    var contentFreshnessPolicy: FileContentFreshnessPolicy = .cachedMetadata
}

/// Codable wrapper for regex pattern errors
struct PatternErrorInfo: Codable {
    let errorType: String
    let description: String

    init(_ error: RegexPatternFailure) {
        errorType = String(reflecting: Swift.type(of: error))
        description = error.localizedDescription
    }
}

/// Codable wrapper for per-file errors
struct PerFileError: Codable {
    let filePath: String
    let error: PatternErrorInfo

    init(filePath: String, error: RegexPatternFailure) {
        self.filePath = filePath
        self.error = PatternErrorInfo(error)
    }
}

/// Result returned by the new `FileSearchActor.searchUnified`.
struct SearchResults: Codable {
    /// Absolute file paths whose *path* matched the pattern (may be omitted).
    var paths: [String]?
    /// Individual in-file hits (same payload as `SearchMatch`, may be omitted).
    var matches: [SearchMatch]?
    /// Number of files that contained content matches (optional when count-only)
    var contentFileCount: Int?
    /// Total count of matches (useful for count-only mode)
    var totalCount: Int?
    /// Number of files actually searched after all filters are applied.
    var searchedFileCount: Int?
    /// Number of files admitted by the path scope before extension/exclude filtering.
    var scopedFileCount: Int?
    /// Error that occurred during path search phase
    var pathError: PatternErrorInfo?
    /// Error that occurred during content search phase
    var contentError: PatternErrorInfo?
    /// Per-file errors that occurred during scanning
    var perFileErrors: [PerFileError]?
    /// Optional warning surfaced when the requested pattern was implicitly repaired.
    var warningMessage: String?

    init(
        paths: [String] = [],
        matches: [SearchMatch] = [],
        contentFileCount: Int? = nil,
        totalCount: Int? = nil,
        searchedFileCount: Int? = nil,
        scopedFileCount: Int? = nil,
        pathError: RegexPatternFailure? = nil,
        contentError: RegexPatternFailure? = nil,
        perFileErrors: [(String, RegexPatternFailure)] = [],
        warningMessage: String? = nil
    ) {
        self.paths = paths.isEmpty ? nil : paths
        self.matches = matches.isEmpty ? nil : matches
        self.contentFileCount = contentFileCount
        self.totalCount = totalCount
        self.searchedFileCount = searchedFileCount
        self.scopedFileCount = scopedFileCount
        self.pathError = pathError.map(PatternErrorInfo.init)
        self.contentError = contentError.map(PatternErrorInfo.init)
        self.perFileErrors = perFileErrors.isEmpty ? nil : perFileErrors.map { path, error in
            PerFileError(filePath: path, error: error)
        }
        self.warningMessage = warningMessage
    }
}

private struct SearchHit {
    let lineNumber: Int
}

private struct SearchScanSummary {
    let hits: [SearchHit]
    let lineMatchCount: Int

    var matchedFile: Bool {
        lineMatchCount > 0
    }
}

private struct RegexScanTraits {
    let anchored: Bool
    let expensiveUnanchored: Bool
    let highRisk: Bool
    let linePrefilter: PCRE2LinePrefilter?
}

private struct SearchContentResult {
    let matches: [SearchMatch]
    let totalCount: Int
    let matchedFileCount: Int
    let perFileErrors: [(String, RegexPatternFailure)]
}

private struct SearchLineIndex {
    let lineRanges: [NSRange]
    let lineStartsUTF16: [Int]
    let lineStartsUTF8: [Int]

    init(content: String) {
        let nsContent = content as NSString
        guard !content.isEmpty else {
            lineRanges = []
            lineStartsUTF16 = []
            lineStartsUTF8 = []
            return
        }

        var ranges: [NSRange] = []
        var startsUTF16: [Int] = []
        var startsUTF8: [Int] = []
        ranges.reserveCapacity(32)
        startsUTF16.reserveCapacity(32)
        startsUTF8.reserveCapacity(32)

        var lineStartUTF16 = 0
        var lineStartUTF8 = 0
        var offsetUTF16 = 0
        var offsetUTF8 = 0
        let scalars = content.unicodeScalars
        var index = scalars.startIndex

        func appendLine(endingAtUTF16 endUTF16: Int) {
            startsUTF16.append(lineStartUTF16)
            startsUTF8.append(lineStartUTF8)
            ranges.append(NSRange(location: lineStartUTF16, length: endUTF16 - lineStartUTF16))
        }

        func consume(_ scalar: UnicodeScalar) {
            offsetUTF16 += scalar.utf16.count
            offsetUTF8 += scalar.utf8.count
        }

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar.value == 13 || scalar.value == 10 { // CR or LF
                appendLine(endingAtUTF16: offsetUTF16)
                consume(scalar)
                index = scalars.index(after: index)

                if scalar.value == 13, index < scalars.endIndex, scalars[index].value == 10 {
                    consume(scalars[index])
                    index = scalars.index(after: index)
                }

                lineStartUTF16 = offsetUTF16
                lineStartUTF8 = offsetUTF8
            } else {
                consume(scalar)
                index = scalars.index(after: index)
            }
        }

        if lineStartUTF16 < nsContent.length {
            startsUTF16.append(lineStartUTF16)
            startsUTF8.append(lineStartUTF8)
            ranges.append(NSRange(location: lineStartUTF16, length: nsContent.length - lineStartUTF16))
        }

        lineRanges = ranges
        lineStartsUTF16 = startsUTF16
        lineStartsUTF8 = startsUTF8
    }

    func lineNumber(forUTF16Offset offset: Int) -> Int {
        lineNumber(forOffset: offset, starts: lineStartsUTF16)
    }

    func lineNumber(forUTF8Offset offset: Int) -> Int {
        lineNumber(forOffset: offset, starts: lineStartsUTF8)
    }

    private func lineNumber(forOffset offset: Int, starts: [Int]) -> Int {
        guard !starts.isEmpty else { return -1 }

        var lo = 0
        var hi = starts.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= offset {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return max(0, min(lo - 1, starts.count - 1))
    }
}

private final class SearchLineIndexBox: NSObject {
    let lineIndex: SearchLineIndex
    let lineCount: Int

    init(lineIndex: SearchLineIndex) {
        self.lineIndex = lineIndex
        lineCount = lineIndex.lineRanges.count
    }
}

private enum SearchLineIndexCacheIdentity {
    case versioned(fileID: UUID, contentRevision: UInt64, utf16Length: Int)
    case hashed(filePath: String, utf16Length: Int, hash: UInt64)

    var utf16Length: Int {
        switch self {
        case let .versioned(_, _, length), let .hashed(_, length, _):
            length
        }
    }

    var scanKind: String {
        switch self {
        case .versioned:
            "revision"
        case .hashed:
            "hash-fallback"
        }
    }
}

private struct SearchDocument {
    let filePath: String
    let text: String
    let lineIndex: SearchLineIndex
    let contextLines: Int

    var nsText: NSString {
        text as NSString
    }

    var fullRange: NSRange {
        NSRange(location: 0, length: nsText.length)
    }

    var lineRanges: [NSRange] {
        lineIndex.lineRanges
    }

    func lineNumber(forUTF16Offset offset: Int) -> Int {
        lineIndex.lineNumber(forUTF16Offset: offset)
    }

    func lineNumber(forUTF8Offset offset: Int) -> Int {
        lineIndex.lineNumber(forUTF8Offset: offset)
    }

    func lineText(at lineNumber: Int) -> String {
        guard lineNumber >= 0, lineNumber < lineIndex.lineRanges.count else { return "" }
        return nsText.substring(with: lineIndex.lineRanges[lineNumber])
    }

    func lineSlice(at lineNumber: Int) -> Substring {
        guard lineNumber >= 0, lineNumber < lineIndex.lineRanges.count,
              let range = Range(lineIndex.lineRanges[lineNumber], in: text)
        else {
            return Substring()
        }
        return text[range]
    }

    func contextBefore(at lineNumber: Int) -> [String]? {
        guard contextLines > 0, lineNumber > 0 else { return nil }
        let start = max(0, lineNumber - contextLines)
        return (start ..< lineNumber).map { lineText(at: $0) }
    }

    func contextAfter(at lineNumber: Int) -> [String]? {
        guard contextLines > 0, lineNumber + 1 < lineIndex.lineRanges.count else { return nil }
        let end = min(lineIndex.lineRanges.count, lineNumber + contextLines + 1)
        guard lineNumber + 1 < end else { return nil }
        return ((lineNumber + 1) ..< end).map { lineText(at: $0) }
    }

    func materialize(_ hit: SearchHit) -> SearchMatch {
        SearchMatch(
            filePath: filePath,
            lineNumber: hit.lineNumber,
            lineText: lineText(at: hit.lineNumber),
            contextBefore: contextBefore(at: hit.lineNumber),
            contextAfter: contextAfter(at: hit.lineNumber)
        )
    }
}

private struct SearchDocumentBuildResult {
    let document: SearchDocument
}

private struct SearchFileScanBatch {
    let ordinal: Int
    let document: SearchDocument?
    let summary: SearchScanSummary
    let errors: [(String, RegexPatternFailure)]
}

private struct SearchScanPlan {
    let engine: RegexEngine?
    let literalPattern: String
    let caseInsensitive: Bool
    let wholeWord: Bool
    let fuzzySpaceMatching: Bool
    let contextLines: Int
    let countOnly: Bool
    let maxCollectedMatches: Int?
    let regexTraits: RegexScanTraits?
    let contentFreshnessPolicy: FileContentFreshnessPolicy
}

private struct SearchFileDescriptor {
    let id: UUID
    let name: String
    let relativePath: String
    let standardizedRelativePath: String
    let fullPath: String
    let standardizedFullPath: String
    let standardizedRootFolderPath: String
    let fileExtension: String?
    let contentSnapshot: (FileContentFreshnessPolicy) async throws -> FileSearchContentSnapshot

    init(file: FileViewModel) {
        id = file.id
        name = file.name
        relativePath = file.relativePath
        standardizedRelativePath = file.standardizedRelativePath
        fullPath = file.fullPath
        standardizedFullPath = file.standardizedFullPath
        standardizedRootFolderPath = file.standardizedRootFolderPath
        fileExtension = file.fileExtension
        contentSnapshot = { policy in
            await file.searchContentSnapshot(freshnessPolicy: policy)
        }
    }

    init(
        record: WorkspaceFileRecord,
        rootPath: String,
        store: WorkspaceFileContextStore
    ) {
        id = record.id
        name = record.name
        relativePath = record.relativePath
        standardizedRelativePath = record.standardizedRelativePath
        fullPath = record.fullPath
        standardizedFullPath = record.standardizedFullPath
        standardizedRootFolderPath = StandardizedPath.absolute(rootPath)
        fileExtension = {
            let ext = (record.name as NSString).pathExtension
            return ext.isEmpty ? nil : ext
        }()
        contentSnapshot = { policy in
            let freshnessPolicy = switch policy {
            case .validateDiskMetadata:
                "validateDiskMetadata"
            case .cachedMetadata:
                "cachedMetadata"
            }
            let freshnessState = EditFlowPerf.begin(
                EditFlowPerf.Stage.Search.contentFreshnessValidation,
                EditFlowPerf.Dimensions(
                    contentSource: "storeSnapshot",
                    freshnessPolicy: freshnessPolicy
                )
            )
            var outcome = "error"
            defer {
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Search.contentFreshnessValidation,
                    freshnessState,
                    EditFlowPerf.Dimensions(
                        outcome: outcome,
                        contentSource: "storeSnapshot",
                        freshnessPolicy: freshnessPolicy
                    )
                )
            }
            do {
                let snapshot = try await store.searchContentSnapshot(
                    for: record,
                    freshnessPolicy: policy
                )
                outcome = snapshot.isFresh ? "current" : "missing"
                return snapshot
            } catch is CancellationError {
                outcome = "cancelled"
                throw CancellationError()
            } catch {
                throw error
            }
        }
    }
}

private struct SearchFileInput {
    let ordinal: Int
    let file: SearchFileDescriptor
}

private struct SearchContentBatch {
    let index: Int
    let range: Range<Int>
}

private struct SearchContentBatchResult {
    let index: Int
    let fileResults: [SearchFileScanBatch]
}

private struct SearchPathScanPlan {
    let trimmedPattern: String
    let regex: PCRE2Regex?
    let pathSuffixPattern: PCRE2PathSuffixPattern?
    let caseInsensitive: Bool
    let isRegex: Bool
    let aliasByRootPath: [String: String]?
}

private struct SearchPathInput {
    let ordinal: Int
    let file: SearchFileDescriptor
}

private struct SearchPathBatch {
    let index: Int
    let range: Range<Int>
}

private struct SearchPathBatchResult {
    let index: Int
    let hits: [(ordinal: Int, path: String)]
}

struct OrderedSearchBatchWindow {
    let batchCount: Int
    let maxEnqueueLead: Int
    private(set) var nextBatchToEnqueue = 0
    private(set) var nextBatchToDrain = 0

    init(batchCount: Int, maxEnqueueLead: Int) {
        precondition(batchCount >= 0)
        precondition(maxEnqueueLead > 0)
        self.batchCount = batchCount
        self.maxEnqueueLead = maxEnqueueLead
    }

    var enqueueLead: Int {
        nextBatchToEnqueue - nextBatchToDrain
    }

    mutating func takeNextBatchToEnqueue() -> Int? {
        guard nextBatchToEnqueue < batchCount,
              nextBatchToEnqueue < nextBatchToDrain + maxEnqueueLead
        else { return nil }
        defer { nextBatchToEnqueue += 1 }
        return nextBatchToEnqueue
    }

    mutating func advanceDrainFrontier() {
        precondition(nextBatchToDrain < nextBatchToEnqueue)
        nextBatchToDrain += 1
    }
}

/// Ripgrep-style asynchronous searcher, fully cancellable.
actor FileSearchActor {
    private static func descriptors(
        for files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore
    ) -> [SearchFileDescriptor] {
        files.compactMap { file in
            guard let root = rootsByID[file.rootID] else { return nil }
            return SearchFileDescriptor(
                record: file,
                rootPath: root.standardizedFullPath,
                store: store
            )
        }
    }

    /// ------------------------------------------------------------------
    ///  HELPER METHODS FOR USER-FRIENDLY GLOBS
    /// ------------------------------------------------------------------
    /// Helper: does a glob end with a wildcard token?
    private static func endsWithWildcard(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        return last == "*" || last == "?"
    }

    /// Helper: generate friendly fallback candidates for path globs
    private static func pathGlobCandidates(for pattern: String) -> [String] {
        var cands: [String] = [pattern]
        let hasSlash = pattern.contains("/")
        let needsSuffixStar = !endsWithWildcard(pattern)

        // Try matching at any depth if user didn't scope with '/'
        if !hasSlash, !pattern.hasPrefix("**/") {
            cands.append("**/" + pattern)
        }
        // If user forgot a trailing wildcard, try broadening
        if needsSuffixStar {
            cands.append(pattern + "*")
            if !hasSlash, !pattern.hasPrefix("**/") {
                cands.append("**/" + pattern + "*")
            }
        }
        // Deduplicate while preserving order
        var seen = Set<String>()
        var out: [String] = []
        for c in cands where seen.insert(c).inserted {
            out.append(c)
        }
        return out
    }

    /// ------------------------------------------------------------------
    ///  SAFETY CONSTANTS
    /// ------------------------------------------------------------------
    /// For high-risk patterns (anchored + nested quantifier) we drop the
    /// threshold to 512 B to avoid catastrophic back-tracking on huge lines.
    private static let highRiskMaxLineLength = 512 // bytes

    /// PCRE2 calls are synchronous, so line-by-line fallback still caps risky line length.
    private static let pcre2RegexMaxLineLength = 64 * 1024 // 64 KB

    /// For very large files we avoid full-buffer PCRE2 scanning.
    /// Patterns like `xml.*trim` with unanchored greedy quantifiers can be extremely
    /// slow on large buffers because each C match call is synchronous and cannot be
    /// interrupted by cooperative cancellation.
    private static let maxPCRE2FullScanBytes = 1_000_000 // 1 MB

    /// Number of paths evaluated by each path worker task.
    private static let pathScanBatchSize = 128

    /// Maximum number of file-scan tasks that run in parallel.
    /// We default to the number of CPU cores (but at least 4) so the search
    /// stays responsive without flooding the executor with thousands of jobs.
    private static let maxConcurrentTasks = max(4, ProcessInfo.processInfo.activeProcessorCount)

    /// Resolves the measured production content-batch size from a stable worker count.
    /// The policy targets eight batches per worker, then clamps nonempty batches to 2...4 files.
    /// A single-file search remains a single-file batch.
    static func contentScanBatchSize(fileCount: Int, workerCount: Int) -> Int {
        guard fileCount > 0 else { return 0 }
        let resolvedWorkerCount = max(4, workerCount)
        let (filesPerWorkerTarget, overflowed) = resolvedWorkerCount.multipliedReportingOverflow(by: 8)
        let targetBatchSize: Int
        if overflowed || filesPerWorkerTarget >= fileCount {
            targetBatchSize = 1
        } else {
            let quotient = fileCount / filesPerWorkerTarget
            let remainder = fileCount % filesPerWorkerTarget
            targetBatchSize = quotient + (remainder == 0 ? 0 : 1)
        }
        return min(fileCount, min(4, max(2, targetBatchSize)))
    }

    /// Cache of numeric line indexes keyed by file path and content fingerprint.
    private static let lineIndexCache: NSCache<NSString, SearchLineIndexBox> = {
        let cache = NSCache<NSString, SearchLineIndexBox>()
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    // NEW: Regex meta detection for literal over-escape heuristics
    private static let regexMeta: Set<Character> = ["(", ")", "[", "]", "{", "}", ".", "*", "+", "?", "|", "^", "$"]

    /// Looks like a literal with unnecessary escapes (e.g., "\\(") and no "\\\\"
    private static func looksOverEscapedLiteral(_ s: String) -> Bool {
        if s.contains("\\\\") { return false } // double-backslash present → likely intended literal backslash
        let chars = Array(s)
        var i = 0
        var saw = false
        while i < chars.count - 1 {
            if chars[i] == "\\", regexMeta.contains(chars[i + 1]) {
                saw = true
                i += 2
            } else {
                i += 1
            }
        }
        return saw
    }

    /// Remove a single leading "\\" before regex meta characters only (for literal fallback)
    private static func unescapeLiteralRegexEscapes(_ s: String) -> String {
        let chars = Array(s)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if i < chars.count - 1, chars[i] == "\\", regexMeta.contains(chars[i + 1]) {
                out.append(chars[i + 1])
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }

    /// Repairs literal patterns that were double-escaped through JSON or tool layers.
    /// Example: `"frame\\\\("` → `"frame("`
    private static func repairedLiteralPattern(_ pattern: String) -> String? {
        var candidate = pattern
        if Self.looksOverEscapedRegex(candidate) {
            let compressed = Self.compressDoubleEscapesBeforeMeta(candidate)
            if compressed != candidate {
                candidate = compressed
                let chars = Array(candidate)
                if chars.count == 2, chars[0] == "\\", regexMeta.contains(chars[1]) {
                    return nil
                }
            }
        }
        guard Self.looksOverEscapedLiteral(candidate) else { return nil }
        let repaired = Self.unescapeLiteralRegexEscapes(candidate)
        return repaired != pattern ? repaired : nil
    }

    /// Detects patterns that likely have double-escapes before regex meta (e.g., "\\\\(")
    private static func looksOverEscapedRegex(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count >= 3 else { return false }
        var i = 0
        while i < chars.count - 2 {
            if chars[i] == "\\", chars[i + 1] == "\\", regexMeta.contains(chars[i + 2]) {
                return true
            }
            i += 1
        }
        return false
    }

    /// Compresses double backslashes into a single backslash when directly before regex meta.
    /// Example: "\\\\(" -> "\\(" (keeps intent to escape '(' for regex)
    private static func compressDoubleEscapesBeforeMeta(_ s: String) -> String {
        let chars = Array(s)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if i < chars.count - 2, chars[i] == "\\", chars[i + 1] == "\\", regexMeta.contains(chars[i + 2]) {
                // Keep a single escape before meta
                out.append("\\")
                out.append(chars[i + 2])
                i += 3
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }

    // MARK: - Engine Compilation Helper

    /// Compiles a regex pattern for file search. PCRE2 is the only supported search regex engine.
    private static func compileEngine(
        pattern: String,
        caseInsensitive: Bool,
        wholeWord: Bool,
        wasAutoCorrected: inout Bool?
    ) throws -> RegexEngine {
        let multilineAnchors = pattern.contains("^") || pattern.contains("$")

        if let asciiWholeWord = RepoPromptPCRE2Adapter.asciiWholeWordLiteralPlan(
            pattern: pattern,
            isRegex: true,
            wholeWord: wholeWord,
            caseInsensitive: caseInsensitive
        ) {
            return .asciiWholeWord(asciiWholeWord)
        }

        func pcre2CompileRequest(_ candidate: String) -> RepoPromptPCRE2CompileRequest {
            let effective = wholeWord ? "\\b\(candidate)\\b" : candidate
            return RepoPromptPCRE2CompileRequest(
                pattern: effective,
                caseInsensitive: caseInsensitive,
                multilineAnchors: multilineAnchors || effective.contains("^") || effective.contains("$")
            )
        }

        func compilePCRE2(_ candidate: String) throws -> PCRE2Regex {
            try RegexCache.pcre2Regex(for: pcre2CompileRequest(candidate))
        }

        if !wholeWord,
           let anchoredDeclaration = RepoPromptPCRE2Adapter.anchoredDeclarationLinePlan(for: pattern, caseInsensitive: caseInsensitive)
        {
            return try .anchoredDeclaration(anchoredDeclaration, compilePCRE2(pattern))
        }

        if !wholeWord,
           let asciiMarker = RepoPromptPCRE2Adapter.asciiMarkerLinePatternPlan(forRegex: pattern, caseInsensitive: caseInsensitive)
        {
            return .asciiMarker(asciiMarker, pcre2CompileRequest(pattern))
        }

        let result = try RepoPromptPCRE2Adapter.compileSearchRegexWithRepairsResult(
            pattern: pattern,
            caseInsensitive: caseInsensitive,
            wholeWord: wholeWord,
            multilineAnchors: multilineAnchors
        )
        if result.wasRepaired {
            wasAutoCorrected = true
        }
        return .pcre2(result.regex)
    }

    /// Compiles a regex for path-mode search only.
    /// Path candidates are single logical path strings, so `^` and `$` should bind
    /// to the candidate boundaries rather than enabling content-style multiline anchors.
    private static func compilePathRegex(
        pattern: String,
        caseInsensitive: Bool
    ) throws -> PCRE2Regex {
        func compileCandidate(_ candidate: String) throws -> PCRE2Regex {
            try RegexCache.pcre2Regex(for: RepoPromptPCRE2CompileRequest(
                pattern: candidate,
                caseInsensitive: caseInsensitive,
                multilineAnchors: false
            ))
        }

        var lastError: Error?
        do {
            return try compileCandidate(pattern)
        } catch {
            lastError = error
        }

        let compressed = Self.compressDoubleEscapesBeforeMeta(pattern)
        if compressed != pattern {
            do {
                return try compileCandidate(compressed)
            } catch {
                lastError = error
            }
        }

        do {
            let normalised = try RegexToolkit.normalise(pattern)
            var repairedPattern = normalised.text
            let compressedAfterNormalize = Self.compressDoubleEscapesBeforeMeta(repairedPattern)
            if compressedAfterNormalize != repairedPattern {
                repairedPattern = compressedAfterNormalize
            }
            return try compileCandidate(repairedPattern)
        } catch {
            lastError = error
        }

        throw RepoPromptPCRE2Adapter.searchPatternError(
            from: lastError ?? SearchPatternError.invalidRegex(pattern, "Failed to compile regular expression"),
            pattern: pattern
        )
    }

    private static func lineIndexCacheIdentity(
        for file: SearchFileDescriptor,
        content: String,
        contentRevision: UInt64?
    ) -> SearchLineIndexCacheIdentity {
        let utf16Length = content.utf16.count
        if let contentRevision {
            return .versioned(fileID: file.id, contentRevision: contentRevision, utf16Length: utf16Length)
        }

        return EditFlowPerf.measure(
            EditFlowPerf.Stage.Search.lineIndexCacheKey,
            EditFlowPerf.Dimensions(fileBytes: content.utf8.count, scanKind: "hash-fallback")
        ) {
            .hashed(filePath: file.fullPath, utf16Length: utf16Length, hash: content.fnv1a64())
        }
    }

    private static func lineIndexCacheKey(identity: SearchLineIndexCacheIdentity) -> NSString {
        switch identity {
        case let .versioned(fileID, contentRevision, utf16Length):
            "v|\(fileID.uuidString)|\(contentRevision)|\(utf16Length)" as NSString
        case let .hashed(filePath, utf16Length, hash):
            "h|\(filePath)|\(utf16Length)|\(hash)" as NSString
        }
    }

    private static func searchDocument(
        for content: String,
        filePath: String,
        contextLines: Int,
        cacheIdentity: SearchLineIndexCacheIdentity
    ) -> SearchDocumentBuildResult {
        let key = lineIndexCacheKey(identity: cacheIdentity)
        let lookupState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.lineIndexLookup,
            EditFlowPerf.Dimensions(fileBytes: content.utf8.count, scanKind: cacheIdentity.scanKind)
        )
        if let cached = lineIndexCache.object(forKey: key) {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.lineIndexLookup,
                lookupState,
                EditFlowPerf.Dimensions(
                    fileBytes: content.utf8.count,
                    lineCount: cached.lineCount,
                    scanKind: cacheIdentity.scanKind,
                    cacheHit: true
                )
            )
            return SearchDocumentBuildResult(
                document: SearchDocument(filePath: filePath, text: content, lineIndex: cached.lineIndex, contextLines: contextLines)
            )
        }
        EditFlowPerf.end(
            EditFlowPerf.Stage.Search.lineIndexLookup,
            lookupState,
            EditFlowPerf.Dimensions(fileBytes: content.utf8.count, scanKind: cacheIdentity.scanKind, cacheHit: false)
        )

        let buildState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.lineIndexBuild,
            EditFlowPerf.Dimensions(fileBytes: content.utf8.count, scanKind: cacheIdentity.scanKind)
        )
        let lineIndex = SearchLineIndex(content: content)
        EditFlowPerf.end(
            EditFlowPerf.Stage.Search.lineIndexBuild,
            buildState,
            EditFlowPerf.Dimensions(
                fileBytes: content.utf8.count,
                lineCount: lineIndex.lineRanges.count,
                scanKind: cacheIdentity.scanKind
            )
        )
        lineIndexCache.setObject(SearchLineIndexBox(lineIndex: lineIndex), forKey: key, cost: cacheIdentity.utf16Length)
        return SearchDocumentBuildResult(
            document: SearchDocument(filePath: filePath, text: content, lineIndex: lineIndex, contextLines: contextLines)
        )
    }

    private static func materializeMatches(
        from batch: SearchFileScanBatch,
        remaining: Int
    ) -> [SearchMatch] {
        guard remaining > 0, let document = batch.document else { return [] }
        let matchLimit = min(remaining, batch.summary.hits.count)
        return EditFlowPerf.measure(
            EditFlowPerf.Stage.Search.materializeMatches,
            EditFlowPerf.Dimensions(
                lineCount: document.lineRanges.count,
                matchCount: matchLimit,
                contextLines: document.contextLines
            )
        ) {
            Array(batch.summary.hits.prefix(remaining)).map { document.materialize($0) }
        }
    }

    // MARK: - Public entry points ----------------------------------------------

    /// Enhanced search with full options support and auto-correction reporting
    func search(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel]
    ) async throws -> [SearchMatch] {
        var materializingOptions = options
        materializingOptions.countOnly = false
        let result = try await searchWithErrors(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            options: materializingOptions,
            in: files.map(SearchFileDescriptor.init(file:))
        )
        return result.matches
    }

    func search(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore
    ) async throws -> [SearchMatch] {
        var materializingOptions = options
        materializingOptions.countOnly = false
        let result = try await searchWithErrors(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            options: materializingOptions,
            in: Self.descriptors(
                for: files,
                rootsByID: rootsByID,
                store: store
            )
        )
        return result.matches
    }

    /// Internal search function that returns both matches and per-file errors
    private func searchWithErrors(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [SearchFileDescriptor]
    ) async throws -> SearchContentResult {
        // Filter files by extensions and exclude patterns first
        let filteredFiles = filterFiles(files, options: options)
        func hasMatches(_ result: SearchContentResult) -> Bool {
            result.totalCount > 0
        }

        var primary = try await searchContentWithErrors(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            caseInsensitive: options.caseInsensitive,
            wholeWord: options.wholeWord,
            fuzzySpaceMatching: options.fuzzySpaceMatching,
            contextLines: options.contextLines,
            countOnly: options.countOnly,
            maxResults: options.maxResults,
            contentFreshnessPolicy: options.contentFreshnessPolicy,
            in: filteredFiles
        )

        // Auto-fallback: if user over-escaped literals (e.g., "frame\\(") and got no results,
        // try again with de-escaped literal. Only when not in regex mode and allowed.
        if !isRegex,
           !hasMatches(primary),
           options.allowLiteralUnescapeFallback,
           let repaired = Self.repairedLiteralPattern(pattern)
        {
            if repaired != pattern {
                primary = try await searchContentWithErrors(
                    pattern: repaired,
                    isRegex: false,
                    wasAutoCorrected: &wasAutoCorrected,
                    caseInsensitive: options.caseInsensitive,
                    wholeWord: options.wholeWord,
                    fuzzySpaceMatching: options.fuzzySpaceMatching,
                    contextLines: options.contextLines,
                    countOnly: options.countOnly,
                    maxResults: options.maxResults,
                    contentFreshnessPolicy: options.contentFreshnessPolicy,
                    in: filteredFiles
                )
                if hasMatches(primary) {
                    wasAutoCorrected = true
                }
            }
        }

        // NEW: Regex over-escape auto-fix for MCP inputs – only when regex mode returns no matches
        if isRegex, !hasMatches(primary) {
            // 1) Compress accidental double-escapes before meta (e.g., "\\\\(" -> "\\(")
            if Self.looksOverEscapedRegex(pattern) {
                let compressed = Self.compressDoubleEscapesBeforeMeta(pattern)
                if compressed != pattern {
                    let corrected1 = try await searchContentWithErrors(
                        pattern: compressed,
                        isRegex: true,
                        wasAutoCorrected: &wasAutoCorrected,
                        caseInsensitive: options.caseInsensitive,
                        wholeWord: options.wholeWord,
                        fuzzySpaceMatching: options.fuzzySpaceMatching,
                        contextLines: options.contextLines,
                        countOnly: options.countOnly,
                        maxResults: options.maxResults,
                        contentFreshnessPolicy: options.contentFreshnessPolicy,
                        in: filteredFiles
                    )
                    if hasMatches(corrected1) {
                        wasAutoCorrected = true
                        return corrected1
                    }
                }
            }

            // 2) Try a normalized pattern (repairs unmatched parens and gracefully handles empty alternatives)
            do {
                let normalized = try RegexToolkit.normalise(pattern)
                let norm = normalized.text
                if norm != pattern {
                    let corrected2 = try await searchContentWithErrors(
                        pattern: norm,
                        isRegex: true,
                        wasAutoCorrected: &wasAutoCorrected,
                        caseInsensitive: options.caseInsensitive,
                        wholeWord: options.wholeWord,
                        fuzzySpaceMatching: options.fuzzySpaceMatching,
                        contextLines: options.contextLines,
                        countOnly: options.countOnly,
                        maxResults: options.maxResults,
                        contentFreshnessPolicy: options.contentFreshnessPolicy,
                        in: filteredFiles
                    )
                    if hasMatches(corrected2) {
                        wasAutoCorrected = true
                        return corrected2
                    }
                }
            } catch {
                // ignore and continue to literal quoting fallback
            }

            // 3) As a last resort, interpret intent literally with PCRE2-safe escaping
            let literalCandidate = Self.unescapeLiteralRegexEscapes(pattern)
            if literalCandidate != pattern {
                let quoted = RepoPromptPCRE2Adapter.escapedLiteral(literalCandidate)
                let corrected3 = try await searchContentWithErrors(
                    pattern: quoted,
                    isRegex: true,
                    wasAutoCorrected: &wasAutoCorrected,
                    caseInsensitive: options.caseInsensitive,
                    wholeWord: options.wholeWord,
                    fuzzySpaceMatching: options.fuzzySpaceMatching,
                    contextLines: options.contextLines,
                    countOnly: options.countOnly,
                    maxResults: options.maxResults,
                    contentFreshnessPolicy: options.contentFreshnessPolicy,
                    in: filteredFiles
                )
                if hasMatches(corrected3) {
                    wasAutoCorrected = true
                    return corrected3
                }
            }
        }

        return primary
    }

    /// Enhanced search with full options support (backward compatibility)
    func search(
        pattern: String,
        isRegex: Bool = false,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel]
    ) async throws -> [SearchMatch] {
        var autoCorrected: Bool? = nil
        return try await search(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &autoCorrected,
            options: options,
            in: files
        )
    }

    func search(
        pattern: String,
        isRegex: Bool = false,
        options: SearchOptions = SearchOptions(),
        in files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore
    ) async throws -> [SearchMatch] {
        var autoCorrected: Bool? = nil
        return try await search(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &autoCorrected,
            options: options,
            in: files,
            rootsByID: rootsByID,
            store: store
        )
    }

    /// Filter files based on include/exclude patterns
    private func filterFiles(_ files: [SearchFileDescriptor], options: SearchOptions) -> [SearchFileDescriptor] {
        files.filter { file in
            // Check include extensions
            if !options.includeExtensions.isEmpty {
                let fileExtension = "." + (file.fileExtension ?? "")
                if !options.includeExtensions.contains(fileExtension) {
                    return false
                }
            }

            // Check exclude patterns
            for excludePattern in options.excludePatterns {
                if matchesPattern(file.relativePath, pattern: excludePattern) {
                    return false
                }
            }

            return true
        }
    }

    /// Simple pattern matching for exclude patterns (supports basic wildcards)
    private func matchesPattern(_ path: String, pattern: String) -> Bool {
        // Use wildmatch for patterns with wildcards
        if pattern.contains("*") || pattern.contains("?") {
            // Use wildmatch with appropriate flags
            // NOTE: Only set WM_WILDSTAR (which implies PATHNAME) if pattern uses '**'.
            // Otherwise we avoid PATHNAME so that '*' may match across '/'.
            let flags: UInt32 = (pattern.contains("**") ? WM_WILDSTAR : 0) | WM_CASEFOLD
            return pattern.withCString { patternC in
                path.withCString { pathC in
                    repo_wildmatch(patternC, pathC, flags) == WM_MATCH
                }
            }
        }

        // Literal substring match (case insensitive)
        return path.lowercased().contains(pattern.lowercased())
    }

    private func searchContent(
        pattern: String,
        isRegex: Bool,
        wasAutoCorrected: inout Bool?,
        caseInsensitive: Bool,
        wholeWord: Bool,
        fuzzySpaceMatching: Bool,
        contextLines: Int,
        maxResults: Int,
        in files: [SearchFileDescriptor]
    ) async throws -> [SearchMatch] {
        let result = try await searchContentWithErrors(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            caseInsensitive: caseInsensitive,
            wholeWord: wholeWord,
            fuzzySpaceMatching: fuzzySpaceMatching,
            contextLines: contextLines,
            countOnly: false,
            maxResults: maxResults,
            in: files
        )
        return result.matches
    }

    private func searchContentWithErrors(
        pattern: String,
        isRegex: Bool,
        wasAutoCorrected: inout Bool?,
        caseInsensitive: Bool,
        wholeWord: Bool,
        fuzzySpaceMatching: Bool,
        contextLines: Int,
        countOnly: Bool,
        maxResults: Int,
        contentFreshnessPolicy: FileContentFreshnessPolicy = .cachedMetadata,
        in files: [SearchFileDescriptor]
    ) async throws -> SearchContentResult {
        // Treat empty/whitespace literal patterns as no-ops to avoid matching every line
        if !isRegex && pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SearchContentResult(matches: [], totalCount: 0, matchedFileCount: 0, perFileErrors: [])
        }

        // Pattern complexity validation
        try RegexToolkit.validateComplexity(pattern, isRegex: isRegex)

        // 0. Parent-task cancellation gate
        try Task.checkCancellation()

        // 1. Select and compile the appropriate regex engine using the PCRE2-first helper.
        let regexTraits: RegexScanTraits? = isRegex
            ? RegexScanTraits(
                anchored: RegexToolkit.isLineAnchored(pattern) || pattern.first == "^" || pattern.last == "$",
                expensiveUnanchored: RegexToolkit.isExpensiveUnanchored(pattern),
                highRisk: RegexToolkit.isHighRisk(pattern),
                linePrefilter: RepoPromptPCRE2Adapter.linePrefilterForAnchoredPattern(pattern, caseInsensitive: caseInsensitive)
            )
            : nil
        let engine: RegexEngine? = try {
            guard isRegex else { return nil }

            return try Self.compileEngine(
                pattern: pattern,
                caseInsensitive: caseInsensitive,
                wholeWord: wholeWord,
                wasAutoCorrected: &wasAutoCorrected
            )
        }()

        var literalPattern = pattern
        if !isRegex, fuzzySpaceMatching, pattern.contains(" ") {
            literalPattern = pattern
        }

        let plan = SearchScanPlan(
            engine: engine,
            literalPattern: literalPattern,
            caseInsensitive: caseInsensitive,
            wholeWord: wholeWord,
            fuzzySpaceMatching: fuzzySpaceMatching,
            contextLines: contextLines,
            countOnly: countOnly,
            maxCollectedMatches: countOnly ? nil : max(0, maxResults),
            regexTraits: regexTraits,
            contentFreshnessPolicy: contentFreshnessPolicy
        )
        let entries = files
            .sorted { $0.fullPath < $1.fullPath }
            .enumerated()
            .map { SearchFileInput(ordinal: $0.offset, file: $0.element) }
        let contentBatchSize = Self.contentScanBatchSize(
            fileCount: entries.count,
            workerCount: Self.maxConcurrentTasks
        )
        let batches = Self.makeContentBatches(entries, batchSize: contentBatchSize)
        let scanKind = Self.scanKind(for: plan)
        let contentScanState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.contentScanTotal,
            EditFlowPerf.Dimensions(
                taskCount: batches.count,
                workerCount: Self.maxConcurrentTasks,
                admittedFileCount: files.count,
                scanKind: scanKind,
                batchSize: contentBatchSize,
                isRegex: isRegex,
                countOnly: countOnly
            )
        )
        var contentScanOutcome = "completed"
        var scannedFileCount = 0

        var batchWindow = OrderedSearchBatchWindow(
            batchCount: batches.count,
            maxEnqueueLead: Self.maxConcurrentTasks
        )
        var pending: [Int: SearchContentBatchResult] = [:]
        var emittedMatches: [SearchMatch] = []
        var totalCount = 0
        var matchedFileCount = 0
        var perFileErrors: [(String, RegexPatternFailure)] = []
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentScanTotal,
                contentScanState,
                EditFlowPerf.Dimensions(
                    outcome: contentScanOutcome,
                    matchCount: totalCount,
                    taskCount: batches.count,
                    workerCount: Self.maxConcurrentTasks,
                    admittedFileCount: files.count,
                    scannedFileCount: scannedFileCount,
                    matchedFileCount: matchedFileCount,
                    scanKind: scanKind,
                    batchSize: contentBatchSize,
                    isRegex: isRegex,
                    countOnly: countOnly
                )
            )
        }

        func refillBatchWindow(into group: inout ThrowingTaskGroup<SearchContentBatchResult, Error>) {
            while let batchIndex = batchWindow.takeNextBatchToEnqueue() {
                let batch = batches[batchIndex]
                group.addTask { [entries] in
                    try await Self.scanContentBatch(batch, entries: entries, plan: plan)
                }
            }
        }

        do {
            try await withThrowingTaskGroup(of: SearchContentBatchResult.self) { group in
                refillBatchWindow(into: &group)

                scanLoop: while let batchResult = try await group.next() {
                    scannedFileCount += batchResult.fileResults.count
                    pending[batchResult.index] = batchResult

                    var drainAdvanced = false
                    while let ready = pending.removeValue(forKey: batchWindow.nextBatchToDrain) {
                        for fileResult in ready.fileResults {
                            perFileErrors.append(contentsOf: fileResult.errors)
                            totalCount += fileResult.summary.lineMatchCount
                            if fileResult.summary.matchedFile {
                                matchedFileCount += 1
                            }

                            if !countOnly, emittedMatches.count < maxResults {
                                emittedMatches.append(contentsOf: Self.materializeMatches(from: fileResult, remaining: maxResults - emittedMatches.count))
                            }

                            if !countOnly, emittedMatches.count >= maxResults {
                                contentScanOutcome = "capped"
                                group.cancelAll()
                                break scanLoop
                            }
                        }
                        batchWindow.advanceDrainFrontier()
                        drainAdvanced = true
                    }

                    if drainAdvanced {
                        refillBatchWindow(into: &group)
                    }
                }
            }
        } catch {
            contentScanOutcome = error is CancellationError ? "cancelled" : "failed"
            throw error
        }
        if Task.isCancelled {
            contentScanOutcome = "cancelled"
        }

        if countOnly {
            return SearchContentResult(
                matches: [],
                totalCount: totalCount,
                matchedFileCount: matchedFileCount,
                perFileErrors: perFileErrors
            )
        }

        return SearchContentResult(
            matches: emittedMatches,
            totalCount: emittedMatches.count,
            matchedFileCount: Set(emittedMatches.map(\.filePath)).count,
            perFileErrors: perFileErrors
        )
    }

    private static func makeContentBatches(
        _ entries: [SearchFileInput],
        batchSize: Int
    ) -> [SearchContentBatch] {
        guard !entries.isEmpty else { return [] }
        precondition(batchSize > 0)
        var batches: [SearchContentBatch] = []
        batches.reserveCapacity(((entries.count - 1) / batchSize) + 1)
        var batchIndex = 0
        var start = 0
        while start < entries.count {
            let end = min(start + batchSize, entries.count)
            batches.append(SearchContentBatch(index: batchIndex, range: start ..< end))
            batchIndex += 1
            start = end
        }
        return batches
    }

    private static func scanKind(for plan: SearchScanPlan) -> String {
        guard let engine = plan.engine else { return "literal" }
        switch engine {
        case .pcre2:
            return "regex-pcre2"
        case .asciiWholeWord:
            return "regex-ascii-whole-word"
        case .anchoredDeclaration:
            return "regex-anchored-declaration"
        case .asciiMarker:
            return "regex-ascii-marker"
        }
    }

    private static func scanContentBatch(
        _ batch: SearchContentBatch,
        entries: [SearchFileInput],
        plan: SearchScanPlan
    ) async throws -> SearchContentBatchResult {
        let batchSize = batch.range.count
        let perfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.contentBatch,
            EditFlowPerf.Dimensions(
                workerCount: Self.maxConcurrentTasks,
                scanKind: scanKind(for: plan),
                batchSize: batchSize,
                isRegex: plan.engine != nil,
                countOnly: plan.countOnly,
                caseInsensitive: plan.caseInsensitive,
                wholeWord: plan.wholeWord,
                contextLines: plan.contextLines
            )
        )
        var matchCount = 0
        var scannedFileCount = 0
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentBatch,
                perfState,
                EditFlowPerf.Dimensions(
                    matchCount: matchCount,
                    workerCount: Self.maxConcurrentTasks,
                    scannedFileCount: scannedFileCount,
                    scanKind: scanKind(for: plan),
                    batchSize: batchSize,
                    isRegex: plan.engine != nil,
                    countOnly: plan.countOnly,
                    caseInsensitive: plan.caseInsensitive,
                    wholeWord: plan.wholeWord,
                    contextLines: plan.contextLines
                )
            )
        }

        var fileResults: [SearchFileScanBatch] = []
        fileResults.reserveCapacity(batchSize)
        for index in batch.range {
            if Task.isCancelled { break }
            let result = try await scanFileWithErrorHandling(entries[index], plan: plan)
            scannedFileCount += 1
            matchCount += result.summary.lineMatchCount
            fileResults.append(result)
        }
        return SearchContentBatchResult(index: batch.index, fileResults: fileResults)
    }

    /// Helper wraps per-file work with error handling
    private static func scanFileWithErrorHandling(
        _ input: SearchFileInput,
        plan: SearchScanPlan
    ) async throws -> SearchFileScanBatch {
        let file = input.file
        do {
            guard !Task.isCancelled else {
                return SearchFileScanBatch(
                    ordinal: input.ordinal,
                    document: nil,
                    summary: SearchScanSummary(hits: [], lineMatchCount: 0),
                    errors: []
                )
            }
            let snapshot = try await EditFlowPerf.measure(
                EditFlowPerf.Stage.Search.fileContentFetch,
                EditFlowPerf.Dimensions(
                    scanKind: scanKind(for: plan),
                    isRegex: plan.engine != nil,
                    countOnly: plan.countOnly,
                    caseInsensitive: plan.caseInsensitive,
                    wholeWord: plan.wholeWord,
                    contextLines: plan.contextLines
                )
            ) {
                try await file.contentSnapshot(plan.contentFreshnessPolicy)
            }
            guard let text = snapshot.content else {
                return SearchFileScanBatch(
                    ordinal: input.ordinal,
                    document: nil,
                    summary: SearchScanSummary(hits: [], lineMatchCount: 0),
                    errors: []
                )
            }
            guard !Task.isCancelled else {
                return SearchFileScanBatch(
                    ordinal: input.ordinal,
                    document: nil,
                    summary: SearchScanSummary(hits: [], lineMatchCount: 0),
                    errors: []
                )
            }

            if plan.countOnly {
                let fastPathState = EditFlowPerf.begin(
                    EditFlowPerf.Stage.Search.countOnlyFastPath,
                    EditFlowPerf.Dimensions(
                        fileBytes: text.utf8.count,
                        scanKind: scanKind(for: plan),
                        isRegex: plan.engine != nil,
                        countOnly: true
                    )
                )
                if let summary = try Self.scanCountOnlyFastPath(plan: plan, text: text) {
                    EditFlowPerf.end(
                        EditFlowPerf.Stage.Search.countOnlyFastPath,
                        fastPathState,
                        EditFlowPerf.Dimensions(
                            status: "hit",
                            fileBytes: text.utf8.count,
                            matchCount: summary.lineMatchCount,
                            scanKind: scanKind(for: plan),
                            isRegex: plan.engine != nil,
                            countOnly: true
                        )
                    )
                    return SearchFileScanBatch(
                        ordinal: input.ordinal,
                        document: nil,
                        summary: summary,
                        errors: []
                    )
                }
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Search.countOnlyFastPath,
                    fastPathState,
                    EditFlowPerf.Dimensions(
                        status: "miss",
                        fileBytes: text.utf8.count,
                        scanKind: scanKind(for: plan),
                        isRegex: plan.engine != nil,
                        countOnly: true
                    )
                )
            }

            let cacheIdentity = Self.lineIndexCacheIdentity(for: file, content: text, contentRevision: snapshot.contentRevision)
            let documentBuild = Self.searchDocument(
                for: text,
                filePath: file.fullPath,
                contextLines: plan.contextLines,
                cacheIdentity: cacheIdentity
            )
            let document = documentBuild.document
            let summary = try Self.scan(
                engine: plan.engine,
                in: document,
                literalPattern: plan.literalPattern,
                caseInsensitive: plan.caseInsensitive,
                wholeWord: plan.wholeWord,
                fuzzySpaceMatching: plan.fuzzySpaceMatching,
                countOnly: plan.countOnly,
                maxCollectedMatches: plan.maxCollectedMatches,
                regexTraits: plan.regexTraits
            )

            return SearchFileScanBatch(
                ordinal: input.ordinal,
                document: (plan.countOnly || summary.hits.isEmpty) ? nil : document,
                summary: summary,
                errors: []
            )
        } catch let error as ContentReadSchedulerError {
            throw StoreBackedWorkspaceSearchAdmissionError.contentReadQueueFull(
                retryAfterMilliseconds: error.retryAfterMilliseconds
            )
        } catch let error as StoreBackedWorkspaceSearchAdmissionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RegexPatternFailure {
            return SearchFileScanBatch(
                ordinal: input.ordinal,
                document: nil,
                summary: SearchScanSummary(hits: [], lineMatchCount: 0),
                errors: [(file.relativePath, error)]
            )
        } catch let error as PCRE2Error {
            return SearchFileScanBatch(
                ordinal: input.ordinal,
                document: nil,
                summary: SearchScanSummary(hits: [], lineMatchCount: 0),
                errors: [(file.relativePath, RepoPromptPCRE2Adapter.searchPatternError(from: error, pattern: plan.literalPattern))]
            )
        } catch {
            return SearchFileScanBatch(
                ordinal: input.ordinal,
                document: nil,
                summary: SearchScanSummary(hits: [], lineMatchCount: 0),
                errors: []
            )
        }
    }

    private static func scanCountOnlyFastPath(
        plan: SearchScanPlan,
        text: String
    ) throws -> SearchScanSummary? {
        if let engine = plan.engine {
            return try scanRegexCountOnlyFastPath(engine: engine, text: text, regexTraits: plan.regexTraits)
        }
        return try scanLiteralCountOnlyFastPath(
            plan.literalPattern,
            in: text,
            caseInsensitive: plan.caseInsensitive,
            wholeWord: plan.wholeWord,
            fuzzySpaceMatching: plan.fuzzySpaceMatching
        )
    }

    private static func scanRegexCountOnlyFastPath(
        engine: RegexEngine,
        text: String,
        regexTraits: RegexScanTraits?
    ) throws -> SearchScanSummary? {
        switch engine {
        case let .asciiWholeWord(literal):
            guard let lineCount = literal.countMatchingLines(in: text) else { return nil }
            return SearchScanSummary(hits: [], lineMatchCount: lineCount)
        case let .anchoredDeclaration(plan, _):
            guard let result = plan.scanMatchingLines(
                in: text,
                collectMatches: false,
                cancellationCheckStride: 16,
                shouldCancel: { Task.isCancelled }
            ) else { return nil }
            return SearchScanSummary(hits: [], lineMatchCount: result.lineMatchCount)
        case let .asciiMarker(plan, _):
            guard let lineCount = plan.countMatchingLines(in: text) else { return nil }
            return SearchScanSummary(hits: [], lineMatchCount: lineCount)
        case let .pcre2(regex):
            let traits = regexTraits ?? RegexScanTraits(anchored: false, expensiveUnanchored: false, highRisk: false, linePrefilter: nil)
            guard traits.anchored || traits.expensiveUnanchored || text.utf8.count > Self.maxPCRE2FullScanBytes else {
                return nil
            }
            let result = try regex.withMatchSession(matchLimits: RepoPromptPCRE2MatchPolicy.fileSearchLine) { session in
                try session.scanMatchingLines(
                    in: text,
                    options: PCRE2LineScanOptions(
                        maxLineUTF8Length: traits.highRisk ? highRiskMaxLineLength : pcre2RegexMaxLineLength,
                        collectMatches: false,
                        cancellationCheckStride: 16,
                        prefilter: traits.linePrefilter
                    ),
                    shouldCancel: { Task.isCancelled }
                )
            }
            return SearchScanSummary(hits: [], lineMatchCount: result.lineMatchCount)
        }
    }

    private static func scanLiteralCountOnlyFastPath(
        _ needle: String,
        in text: String,
        caseInsensitive: Bool,
        wholeWord: Bool,
        fuzzySpaceMatching: Bool
    ) throws -> SearchScanSummary? {
        if needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SearchScanSummary(hits: [], lineMatchCount: 0)
        }

        if fuzzySpaceMatching, needle.contains(" ") {
            let fuzzyPattern = convertSpacesToFuzzyRegex(needle)
            let regex = try RegexCache.pcre2Regex(for: RepoPromptPCRE2CompileRequest(
                pattern: fuzzyPattern,
                caseInsensitive: caseInsensitive,
                multilineAnchors: false
            ))
            let result = try regex.withMatchSession(matchLimits: RepoPromptPCRE2MatchPolicy.fileSearchLine) { session in
                try session.scanMatchingLines(
                    in: text,
                    options: PCRE2LineScanOptions(collectMatches: false),
                    shouldCancel: { Task.isCancelled }
                )
            }
            return SearchScanSummary(hits: [], lineMatchCount: result.lineMatchCount)
        }

        if let wholeWordLiteral = RepoPromptPCRE2Adapter.asciiWholeWordLiteralPlan(
            pattern: needle,
            isRegex: false,
            wholeWord: wholeWord,
            caseInsensitive: caseInsensitive
        ) {
            guard let lineCount = wholeWordLiteral.countMatchingLines(in: text) else { return nil }
            return SearchScanSummary(hits: [], lineMatchCount: lineCount)
        }

        if wholeWord {
            let escaped = RepoPromptPCRE2Adapter.escapedLiteral(needle)
            let regex = try RegexCache.pcre2Regex(for: RepoPromptPCRE2CompileRequest(
                pattern: "\\b\(escaped)\\b",
                caseInsensitive: caseInsensitive,
                multilineAnchors: false
            ))
            let result = try regex.withMatchSession(matchLimits: RepoPromptPCRE2MatchPolicy.fileSearchLine) { session in
                try session.scanMatchingLines(
                    in: text,
                    options: PCRE2LineScanOptions(collectMatches: false),
                    shouldCancel: { Task.isCancelled }
                )
            }
            return SearchScanSummary(hits: [], lineMatchCount: result.lineMatchCount)
        }

        return SearchScanSummary(
            hits: [],
            lineMatchCount: countLiteralMatchingLines(needle, in: text, caseInsensitive: caseInsensitive)
        )
    }

    private static func countLiteralMatchingLines(
        _ needle: String,
        in text: String,
        caseInsensitive: Bool
    ) -> Int {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return 0 }
        let compareOptions: NSString.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        var lineStartUTF16 = 0
        var offsetUTF16 = 0
        var lineNumber = 0
        var matchCount = 0
        let scalars = text.unicodeScalars
        var index = scalars.startIndex

        func scanLine(endingAtUTF16 endUTF16: Int) {
            if nsText.range(
                of: needle,
                options: compareOptions,
                range: NSRange(location: lineStartUTF16, length: max(0, endUTF16 - lineStartUTF16))
            ).location != NSNotFound {
                matchCount += 1
            }
            lineNumber += 1
        }

        func consume(_ scalar: UnicodeScalar) {
            offsetUTF16 += scalar.utf16.count
        }

        while index < scalars.endIndex {
            if (lineNumber & 0xFF) == 0, Task.isCancelled { break }
            let scalar = scalars[index]
            if scalar.value == 13 || scalar.value == 10 { // CR or LF; mirrors SearchLineIndex line boundaries.
                scanLine(endingAtUTF16: offsetUTF16)
                consume(scalar)
                index = scalars.index(after: index)

                if scalar.value == 13, index < scalars.endIndex, scalars[index].value == 10 {
                    consume(scalars[index])
                    index = scalars.index(after: index)
                }

                lineStartUTF16 = offsetUTF16
            } else {
                consume(scalar)
                index = scalars.index(after: index)
            }
        }

        if lineStartUTF16 < length, !Task.isCancelled {
            scanLine(endingAtUTF16: length)
        }

        return matchCount
    }

    // MARK: - Unified scan function ------------------------------------------

    /// Unified scan function that handles both engine types and literal patterns
    ///
    /// PCRE2 is the primary engine. We still fall back to line-by-line scans for
    /// risky or very large inputs because PCRE2 calls are synchronous C calls.
    private static func scan(
        engine: RegexEngine?,
        in document: SearchDocument,
        literalPattern: String,
        caseInsensitive: Bool,
        wholeWord: Bool,
        fuzzySpaceMatching: Bool,
        countOnly: Bool,
        maxCollectedMatches: Int?,
        regexTraits: RegexScanTraits?
    ) throws -> SearchScanSummary {
        if let engine {
            let traits = regexTraits ?? RegexScanTraits(anchored: false, expensiveUnanchored: false, highRisk: false, linePrefilter: nil)
            switch engine {
            case let .pcre2(regex):
                if traits.anchored || traits.expensiveUnanchored || document.text.utf8.count > Self.maxPCRE2FullScanBytes {
                    return try scanPCRE2RegexLineByLine(
                        regex,
                        in: document,
                        countOnly: countOnly,
                        maxCollectedMatches: maxCollectedMatches,
                        highRisk: traits.highRisk,
                        linePrefilter: traits.linePrefilter
                    )
                }
                return try scanPCRE2Regex(regex, in: document, countOnly: countOnly, maxCollectedMatches: maxCollectedMatches)
            case let .asciiMarker(plan, fallbackRequest):
                if let result = plan.scanMatchingLines(
                    in: document.text,
                    collectMatches: !countOnly,
                    maxCollectedMatches: maxCollectedMatches,
                    shouldCancel: { Task.isCancelled }
                ) {
                    return SearchScanSummary(
                        hits: result.matchingLineNumbers.map(SearchHit.init(lineNumber:)),
                        lineMatchCount: result.lineMatchCount
                    )
                }
                let fallbackRegex = try RegexCache.pcre2Regex(for: fallbackRequest)
                return try scanPCRE2Regex(fallbackRegex, in: document, countOnly: countOnly, maxCollectedMatches: maxCollectedMatches)
            case let .anchoredDeclaration(plan, fallbackRegex):
                if let result = plan.scanMatchingLines(
                    in: document.text,
                    collectMatches: !countOnly,
                    maxCollectedMatches: maxCollectedMatches,
                    cancellationCheckStride: 16,
                    shouldCancel: { Task.isCancelled }
                ) {
                    return SearchScanSummary(
                        hits: result.matchingLineNumbers.map(SearchHit.init(lineNumber:)),
                        lineMatchCount: result.lineMatchCount
                    )
                }
                return try scanPCRE2RegexLineByLine(
                    fallbackRegex,
                    in: document,
                    countOnly: countOnly,
                    maxCollectedMatches: maxCollectedMatches,
                    highRisk: traits.highRisk,
                    linePrefilter: traits.linePrefilter
                )
            case let .asciiWholeWord(literal):
                if let result = literal.scanMatchingLines(
                    in: document.text,
                    collectMatches: !countOnly,
                    maxCollectedMatches: maxCollectedMatches,
                    shouldCancel: { Task.isCancelled }
                ) {
                    return SearchScanSummary(
                        hits: result.matchingLineNumbers.map(SearchHit.init(lineNumber:)),
                        lineMatchCount: result.lineMatchCount
                    )
                }
                let escaped = RepoPromptPCRE2Adapter.escapedLiteral(literal.needle)
                let fallback = try RegexCache.pcre2Regex(for: RepoPromptPCRE2CompileRequest(
                    pattern: "\\b\(escaped)\\b",
                    caseInsensitive: literal.caseInsensitive,
                    multilineAnchors: false
                ))
                return try scanPCRE2RegexLineByLine(fallback, in: document, countOnly: countOnly, maxCollectedMatches: maxCollectedMatches, highRisk: false, linePrefilter: nil)
            }
        }

        return try scanLiteral(
            literalPattern,
            in: document,
            caseInsensitive: caseInsensitive,
            wholeWord: wholeWord,
            fuzzySpaceMatching: fuzzySpaceMatching,
            countOnly: countOnly,
            maxCollectedMatches: maxCollectedMatches
        )
    }

    // MARK: - Literal fast path -----------------------------------------------

    private static func scanLiteral(
        _ needle: String,
        in document: SearchDocument,
        caseInsensitive: Bool,
        wholeWord: Bool = false,
        fuzzySpaceMatching: Bool = true,
        countOnly: Bool = false,
        maxCollectedMatches: Int? = nil
    ) throws -> SearchScanSummary {
        let perfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.literalScan,
            EditFlowPerf.Dimensions(
                fileBytes: document.text.utf8.count,
                lineCount: document.lineRanges.count,
                scanKind: fuzzySpaceMatching && needle.contains(" ") ? "literal-fuzzy" : "literal",
                countOnly: countOnly,
                caseInsensitive: caseInsensitive,
                wholeWord: wholeWord,
                contextLines: document.contextLines
            )
        )
        var perfMatchCount: Int?
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.literalScan,
                perfState,
                EditFlowPerf.Dimensions(
                    fileBytes: document.text.utf8.count,
                    lineCount: document.lineRanges.count,
                    matchCount: perfMatchCount,
                    scanKind: fuzzySpaceMatching && needle.contains(" ") ? "literal-fuzzy" : "literal",
                    countOnly: countOnly,
                    caseInsensitive: caseInsensitive,
                    wholeWord: wholeWord,
                    contextLines: document.contextLines
                )
            )
        }
        func finish(_ summary: SearchScanSummary) -> SearchScanSummary {
            perfMatchCount = summary.lineMatchCount
            return summary
        }
        func reachedCollectionLimit() -> Bool {
            !countOnly && (maxCollectedMatches.map { hits.count >= $0 } ?? false)
        }

        if needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return finish(SearchScanSummary(hits: [], lineMatchCount: 0))
        }

        let nsText = document.nsText
        let compareOptions: NSString.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        var hitCount = 0
        var hits: [SearchHit] = []
        if !countOnly {
            hits.reserveCapacity(8)
        }

        let fuzzyRegex: PCRE2Regex? = try {
            guard fuzzySpaceMatching, needle.contains(" ") else { return nil }
            let fuzzyPattern = convertSpacesToFuzzyRegex(needle)
            return try RegexCache.pcre2Regex(for: RepoPromptPCRE2CompileRequest(
                pattern: fuzzyPattern,
                caseInsensitive: caseInsensitive,
                multilineAnchors: false
            ))
        }()

        let wholeWordLiteral = fuzzyRegex == nil
            ? RepoPromptPCRE2Adapter.asciiWholeWordLiteralPlan(
                pattern: needle,
                isRegex: false,
                wholeWord: wholeWord,
                caseInsensitive: caseInsensitive
            )
            : nil

        if let wholeWordLiteral,
           let result = wholeWordLiteral.scanMatchingLines(
               in: document.text,
               collectMatches: !countOnly,
               maxCollectedMatches: maxCollectedMatches,
               shouldCancel: { Task.isCancelled }
           )
        {
            return finish(SearchScanSummary(
                hits: result.matchingLineNumbers.map(SearchHit.init(lineNumber:)),
                lineMatchCount: result.lineMatchCount
            ))
        }

        let wholeWordRegex: PCRE2Regex? = try {
            guard fuzzyRegex == nil, wholeWord else { return nil }
            let escaped = RepoPromptPCRE2Adapter.escapedLiteral(needle)
            let pattern = "\\b\(escaped)\\b"
            return try RegexCache.pcre2Regex(for: RepoPromptPCRE2CompileRequest(
                pattern: pattern,
                caseInsensitive: caseInsensitive,
                multilineAnchors: false
            ))
        }()

        if let regex = fuzzyRegex ?? wholeWordRegex {
            return try regex.withMatchSession(matchLimits: RepoPromptPCRE2MatchPolicy.fileSearchLine) { session in
                for lineNumber in document.lineRanges.indices {
                    if (lineNumber & 0xFF) == 0, Task.isCancelled {
                        return finish(SearchScanSummary(hits: hits, lineMatchCount: hitCount))
                    }

                    if try session.containsMatch(in: document.lineSlice(at: lineNumber)) {
                        hitCount += 1
                        if !countOnly, maxCollectedMatches.map({ hits.count < $0 }) ?? true {
                            hits.append(SearchHit(lineNumber: lineNumber))
                            if reachedCollectionLimit() {
                                return finish(SearchScanSummary(hits: hits, lineMatchCount: hitCount))
                            }
                        }
                    }
                }

                return finish(SearchScanSummary(hits: hits, lineMatchCount: hitCount))
            }
        }

        for (lineNumber, lineRange) in document.lineRanges.enumerated() {
            if (lineNumber & 0xFF) == 0, Task.isCancelled {
                return finish(SearchScanSummary(hits: hits, lineMatchCount: hitCount))
            }

            if nsText.range(of: needle, options: compareOptions, range: lineRange).location != NSNotFound {
                hitCount += 1
                if !countOnly, maxCollectedMatches.map({ hits.count < $0 }) ?? true {
                    hits.append(SearchHit(lineNumber: lineNumber))
                    if reachedCollectionLimit() { break }
                }
            }
        }

        return finish(SearchScanSummary(hits: hits, lineMatchCount: hitCount))
    }

    // MARK: - Regex path ------------------------------------------------------

    private static func scanPCRE2Regex(
        _ regex: PCRE2Regex,
        in document: SearchDocument,
        countOnly: Bool,
        maxCollectedMatches: Int? = nil
    ) throws -> SearchScanSummary {
        let perfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.regexFullBufferScan,
            EditFlowPerf.Dimensions(
                fileBytes: document.text.utf8.count,
                lineCount: document.lineRanges.count,
                scanKind: "regex-full-buffer",
                countOnly: countOnly,
                contextLines: document.contextLines
            )
        )
        var perfMatchCount: Int?
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.regexFullBufferScan,
                perfState,
                EditFlowPerf.Dimensions(
                    fileBytes: document.text.utf8.count,
                    lineCount: document.lineRanges.count,
                    matchCount: perfMatchCount,
                    scanKind: "regex-full-buffer",
                    countOnly: countOnly,
                    contextLines: document.contextLines
                )
            )
        }
        func finish(_ summary: SearchScanSummary) -> SearchScanSummary {
            perfMatchCount = summary.lineMatchCount
            return summary
        }
        func reachedCollectionLimit() -> Bool {
            !countOnly && (maxCollectedMatches.map { hits.count >= $0 } ?? false)
        }

        if Task.isCancelled {
            return finish(SearchScanSummary(hits: [], lineMatchCount: 0))
        }

        var hitCount = 0
        var hits: [SearchHit] = []
        if !countOnly {
            hits.reserveCapacity(8)
        }
        var lastLineNumber: Int?
        var matchIndex = 0

        try regex.enumerateMatches(in: document.text, matchLimits: RepoPromptPCRE2MatchPolicy.fileSearchFullBuffer) { match in
            defer { matchIndex += 1 }
            if match.byteRange.isEmpty { return true }
            if (matchIndex & 0x0F) == 0, Task.isCancelled { return false }

            let lineNumber = document.lineNumber(forUTF8Offset: match.byteRange.lowerBound)
            guard lineNumber >= 0 else { return true }
            if lastLineNumber == lineNumber { return true }

            lastLineNumber = lineNumber
            hitCount += 1
            if !countOnly, maxCollectedMatches.map({ hits.count < $0 }) ?? true {
                hits.append(SearchHit(lineNumber: lineNumber))
                if reachedCollectionLimit() { return false }
            }
            return true
        }

        return finish(SearchScanSummary(hits: hits, lineMatchCount: hitCount))
    }

    private static func scanPCRE2RegexLineByLine(
        _ regex: PCRE2Regex,
        in document: SearchDocument,
        countOnly: Bool,
        maxCollectedMatches: Int? = nil,
        highRisk: Bool = false,
        linePrefilter: PCRE2LinePrefilter? = nil
    ) throws -> SearchScanSummary {
        let perfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.regexLineByLineScan,
            EditFlowPerf.Dimensions(
                fileBytes: document.text.utf8.count,
                lineCount: document.lineRanges.count,
                scanKind: highRisk ? "regex-line-high-risk" : "regex-line",
                countOnly: countOnly,
                contextLines: document.contextLines
            )
        )
        var perfMatchCount: Int?
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.regexLineByLineScan,
                perfState,
                EditFlowPerf.Dimensions(
                    fileBytes: document.text.utf8.count,
                    lineCount: document.lineRanges.count,
                    matchCount: perfMatchCount,
                    scanKind: highRisk ? "regex-line-high-risk" : "regex-line",
                    countOnly: countOnly,
                    contextLines: document.contextLines
                )
            )
        }
        return try regex.withMatchSession(matchLimits: RepoPromptPCRE2MatchPolicy.fileSearchLine) { session in
            let result = try session.scanMatchingLines(
                in: document.text,
                options: PCRE2LineScanOptions(
                    maxLineUTF8Length: highRisk ? highRiskMaxLineLength : pcre2RegexMaxLineLength,
                    collectMatches: !countOnly,
                    maxCollectedMatches: maxCollectedMatches,
                    cancellationCheckStride: 16,
                    prefilter: linePrefilter
                ),
                shouldCancel: { Task.isCancelled }
            )
            perfMatchCount = result.lineMatchCount
            return SearchScanSummary(
                hits: result.matchingLineNumbers.map(SearchHit.init(lineNumber:)),
                lineMatchCount: result.lineMatchCount
            )
        }
    }

    // MARK: - NEW: Path-only search  ----------------------------------------

    /// Finds file paths that match the supplied `pattern`.
    /// Supports shell wild-cards (`*`, `?`) **or full regular-expressions** when
    /// `isRegex == true`.
    /// Results are returned as *absolute* file paths, up to `limit` items.
    ///
    /// Matching is performed only against repo-relative paths (e.g. `"Assets/Foo.cs"`)
    /// and optional alias-prefixed forms (`"RootAlias/Assets/Foo.cs"`).
    /// Absolute OS paths (`"/Users/..."`) are intentionally *not* matched here;
    /// absolute path resolution is handled via `WorkspaceFilesViewModel`/`PathMatchWorker`.
    ///
    /// **Return values are canonical absolute paths** (`standardizedFullPath`) for
    /// downstream identity, deduplication, and display formatting via `mcpDisplayPath`.
    ///
    /// The work is fanned-out in parallel – similar to the grep implementation.
    func searchPaths(
        pattern: String,
        limit: Int = 100,
        in files: [FileViewModel],
        caseInsensitive: Bool = true,
        isRegex: Bool = false, // ← NEW
        aliasByRootPath: [String: String]? = nil
    ) async throws -> [String] {
        try await searchPaths(
            pattern: pattern,
            limit: limit,
            in: files.map(SearchFileDescriptor.init(file:)),
            caseInsensitive: caseInsensitive,
            isRegex: isRegex,
            aliasByRootPath: aliasByRootPath
        )
    }

    func searchPaths(
        pattern: String,
        limit: Int = 100,
        in files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore,
        caseInsensitive: Bool = true,
        isRegex: Bool = false,
        aliasByRootPath: [String: String]? = nil
    ) async throws -> [String] {
        try await searchPaths(
            pattern: pattern,
            limit: limit,
            in: Self.descriptors(
                for: files,
                rootsByID: rootsByID,
                store: store
            ),
            caseInsensitive: caseInsensitive,
            isRegex: isRegex,
            aliasByRootPath: aliasByRootPath
        )
    }

    private func searchPaths(
        pattern: String,
        limit: Int = 100,
        in files: [SearchFileDescriptor],
        caseInsensitive: Bool = true,
        isRegex: Bool = false,
        aliasByRootPath: [String: String]? = nil
    ) async throws -> [String] {
        // 0. Early exit / sanitise
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !files.isEmpty, limit > 0 else { return [] }

        // 1. Decide whether to prefer glob semantics even when isRegex==true
        let hasWildcards = trimmed.contains("*") || trimmed.contains("?")
        let strongRegex = Self.containsRegexSyntax(trimmed)
        var useRegex = isRegex
        if isRegex && hasWildcards && !strongRegex {
            // Looks like a pure glob (e.g., "*.swift") → prefer glob
            useRegex = false
        }

        let pathSuffixPattern = useRegex ? RepoPromptPCRE2Adapter.pathSuffixPattern(forRegex: trimmed) : nil

        // 2. Prepare the regex only if we decided to actually use regex.
        let regex: PCRE2Regex? = {
            guard useRegex, pathSuffixPattern == nil else { return nil }
            return try? Self.compilePathRegex(
                pattern: trimmed,
                caseInsensitive: caseInsensitive
            )
        }()

        // If regex compilation failed, preserve legacy fallback to glob/literal path matching.
        if isRegex, useRegex, regex == nil, pathSuffixPattern == nil {
            // Prefer glob when there are wildcards; otherwise literal substring.
            useRegex = false
        }

        let plan = SearchPathScanPlan(
            trimmedPattern: trimmed,
            regex: regex,
            pathSuffixPattern: pathSuffixPattern,
            caseInsensitive: caseInsensitive,
            isRegex: useRegex,
            aliasByRootPath: aliasByRootPath
        )
        let entries = files
            .sorted { $0.fullPath < $1.fullPath }
            .enumerated()
            .map { SearchPathInput(ordinal: $0.offset, file: $0.element) }
        let batches = Self.makePathBatches(entries)
        var batchWindow = OrderedSearchBatchWindow(
            batchCount: batches.count,
            maxEnqueueLead: Self.maxConcurrentTasks
        )
        var pending: [Int: SearchPathBatchResult] = [:]
        var hits: [String] = []
        hits.reserveCapacity(min(limit, 16))

        func refillBatchWindow(into group: inout ThrowingTaskGroup<SearchPathBatchResult, Error>) {
            while let batchIndex = batchWindow.takeNextBatchToEnqueue() {
                let batch = batches[batchIndex]
                group.addTask { [entries] in
                    try await Self.scanPathBatch(batch, entries: entries, plan: plan)
                }
            }
        }

        try await withThrowingTaskGroup(of: SearchPathBatchResult.self) { group in
            refillBatchWindow(into: &group)

            scanLoop: while let batchResult = try await group.next() {
                pending[batchResult.index] = batchResult

                var drainAdvanced = false
                while let ready = pending.removeValue(forKey: batchWindow.nextBatchToDrain) {
                    for hit in ready.hits.sorted(by: { $0.ordinal < $1.ordinal }) {
                        hits.append(hit.path)
                        if hits.count >= limit {
                            group.cancelAll()
                            break scanLoop
                        }
                    }
                    batchWindow.advanceDrainFrontier()
                    drainAdvanced = true
                }

                if drainAdvanced {
                    refillBatchWindow(into: &group)
                }
            }
        }

        return hits
    }

    private static func makePathBatches(_ entries: [SearchPathInput]) -> [SearchPathBatch] {
        guard !entries.isEmpty else { return [] }
        var batches: [SearchPathBatch] = []
        batches.reserveCapacity((entries.count + pathScanBatchSize - 1) / pathScanBatchSize)
        var batchIndex = 0
        var start = 0
        while start < entries.count {
            let end = min(start + pathScanBatchSize, entries.count)
            batches.append(SearchPathBatch(index: batchIndex, range: start ..< end))
            batchIndex += 1
            start = end
        }
        return batches
    }

    private static func pathScanKind(for plan: SearchPathScanPlan) -> String {
        if plan.isRegex {
            return plan.pathSuffixPattern == nil ? "path-regex" : "path-regex-suffix"
        }
        return (plan.trimmedPattern.contains("*") || plan.trimmedPattern.contains("?")) ? "path-glob" : "path-literal"
    }

    private static func scanPathBatch(
        _ batch: SearchPathBatch,
        entries: [SearchPathInput],
        plan: SearchPathScanPlan
    ) async throws -> SearchPathBatchResult {
        let batchSize = batch.range.count
        var hits: [(ordinal: Int, path: String)] = []
        hits.reserveCapacity(min(batchSize, 8))
        let perfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.pathBatch,
            EditFlowPerf.Dimensions(
                scanKind: pathScanKind(for: plan),
                batchSize: batchSize,
                isRegex: plan.isRegex,
                caseInsensitive: plan.caseInsensitive
            )
        )
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.pathBatch,
                perfState,
                EditFlowPerf.Dimensions(
                    matchCount: hits.count,
                    scanKind: pathScanKind(for: plan),
                    batchSize: batchSize,
                    isRegex: plan.isRegex,
                    caseInsensitive: plan.caseInsensitive
                )
            )
        }

        if plan.isRegex, let pcre2Regex = plan.regex {
            do {
                try pcre2Regex.withMatchSession(matchLimits: RepoPromptPCRE2MatchPolicy.pathSearchShortSubject) { session in
                    for index in batch.range {
                        try Task.checkCancellation()
                        let entry = entries[index]
                        let candidatePaths = Self.candidatePaths(for: entry.file, aliasByRootPath: plan.aliasByRootPath)
                        let didHit = try candidatePaths.contains { hay in
                            try session.containsMatch(in: hay)
                        }
                        if didHit {
                            hits.append((entry.ordinal, entry.file.standardizedFullPath))
                        }
                    }
                }
                return SearchPathBatchResult(index: batch.index, hits: hits)
            } catch let error as PCRE2Error {
                throw RepoPromptPCRE2Adapter.searchPatternError(from: error, pattern: plan.trimmedPattern)
            } catch let error as RegexPatternFailure {
                throw error
            }
        }

        for index in batch.range {
            try Task.checkCancellation()
            let entry = entries[index]
            if try scanPath(entry.file, plan: plan) {
                hits.append((entry.ordinal, entry.file.standardizedFullPath))
            }
        }
        return SearchPathBatchResult(index: batch.index, hits: hits)
    }

    private static func scanPath(_ file: SearchFileDescriptor, plan: SearchPathScanPlan) throws -> Bool {
        let candidatePaths = Self.candidatePaths(for: file, aliasByRootPath: plan.aliasByRootPath)

        do {
            if plan.isRegex, let pathSuffixPattern = plan.pathSuffixPattern {
                return candidatePaths.contains { pathSuffixPattern.matches($0, caseInsensitive: plan.caseInsensitive) }
            }

            // If it's a regex pattern, use the path-specific compiled regex.
            if plan.isRegex, let regex = plan.regex {
                return try regex.withMatchSession(matchLimits: RepoPromptPCRE2MatchPolicy.pathSearchShortSubject) { session in
                    try candidatePaths.contains { hay in
                        try session.containsMatch(in: hay)
                    }
                }
            }

            // For non-regex patterns, check if it has wildcards
            let hasWildcards = plan.trimmedPattern.contains("*") || plan.trimmedPattern.contains("?")

            if hasWildcards {
                // Try the user's pattern first, then friendly fallbacks
                for cand in Self.pathGlobCandidates(for: plan.trimmedPattern) {
                    // Enable WILDSTAR only if candidate contains "**" (needs globstar)
                    let useWildstar = cand.contains("**")
                    let flags: UInt32 = (useWildstar ? WM_WILDSTAR : 0)
                        | (plan.caseInsensitive ? WM_CASEFOLD : 0)
                    let matched = cand.withCString { patternC in
                        candidatePaths.contains { path in
                            path.withCString { pathC in
                                repo_wildmatch(patternC, pathC, flags) == WM_MATCH
                            }
                        }
                    }
                    if matched { return true }
                }
                return false
            } else {
                // Literal string matching
                return candidatePaths.contains { path in
                    Self.containsSubstring(path, needle: plan.trimmedPattern, caseInsensitive: plan.caseInsensitive)
                }
            }
        } catch let error as PCRE2Error {
            throw RepoPromptPCRE2Adapter.searchPatternError(from: error, pattern: plan.trimmedPattern)
        } catch let error as RegexPatternFailure {
            throw error
        }
    }

    /// Returns candidate paths to match against for path search.
    ///
    /// Only includes repo-relative paths and optional alias-prefixed forms.
    /// Absolute OS paths are intentionally excluded to prevent queries from
    /// matching hidden path components (like the workspace root folder name)
    /// that users don't see in search results.
    private static func candidatePaths(for file: SearchFileDescriptor, aliasByRootPath: [String: String]?) -> [String] {
        var seen = Set<String>()
        var candidates: [String] = []

        func appendCandidate(_ path: String) {
            guard !path.isEmpty else { return }
            if seen.insert(path).inserted {
                candidates.append(path)
            }
        }

        // 1) Standardized repo-relative path (what path search exposes)
        let relativePath = StandardizedPath.relative(file.standardizedRelativePath)
        appendCandidate(relativePath)

        // 2) Optional alias-prefixed path for multi-root workspaces
        if let aliasByRootPath {
            let rootKey = file.standardizedRootFolderPath
            if let alias = aliasByRootPath[rootKey] {
                let aliasPrefixed = relativePath.isEmpty ? alias : "\(alias)/\(relativePath)"
                appendCandidate(aliasPrefixed)
            }
        }

        // NOTE: We deliberately DO NOT include file.standardizedFullPath here.
        // Including the full absolute path caused queries like "Bomb" to match
        // every file when the workspace root was named "BombSquad", because the
        // absolute path "/Users/.../BombSquad/..." matched even though users
        // only see repo-relative paths in results. Any tooling that needs
        // absolute-path matching should use WorkspaceFilesViewModel + PathMatchWorker.

        return candidates
    }

    // MARK: – NEW unified search entry point ––––––––––––––––––––––––––––

    /// Unified search combining path and content search with full SearchOptions support and auto-correction reporting
    func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel],
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        try await searchUnified(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            options: options,
            in: files.map(SearchFileDescriptor.init(file:)),
            aliasByRootPath: aliasByRootPath
        )
    }

    func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore,
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        try await searchUnified(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            options: options,
            in: Self.descriptors(
                for: files,
                rootsByID: rootsByID,
                store: store
            ),
            aliasByRootPath: aliasByRootPath
        )
    }

    private func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [SearchFileDescriptor],
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        try Task.checkCancellation()

        // No auto-detection - only use regex when explicitly requested
        let effectiveIsRegex = isRegex

        // Filter files by extensions and exclude patterns first
        let filteredFiles = filterFiles(files, options: options)

        // Decide effective strategy when `.auto`
        let effectiveMode: SearchMode = {
            if options.mode != .auto { return options.mode }
            return Self.inferMode(pattern)
        }()
        let perfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.actorSearchUnified,
            EditFlowPerf.Dimensions(
                searchMode: effectiveMode.rawValue,
                fileCount: filteredFiles.count,
                maxResults: options.maxResults,
                isRegex: effectiveIsRegex,
                countOnly: options.countOnly,
                caseInsensitive: options.caseInsensitive,
                wholeWord: options.wholeWord,
                contextLines: options.contextLines
            )
        )
        var perfStatus = "ok"
        var perfMatchCount: Int?
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.actorSearchUnified,
                perfState,
                EditFlowPerf.Dimensions(
                    status: perfStatus,
                    matchCount: perfMatchCount,
                    searchMode: effectiveMode.rawValue,
                    fileCount: filteredFiles.count,
                    maxResults: options.maxResults,
                    isRegex: effectiveIsRegex,
                    countOnly: options.countOnly,
                    caseInsensitive: options.caseInsensitive,
                    wholeWord: options.wholeWord,
                    contextLines: options.contextLines
                )
            )
        }

        var pathHits: [String] = []
        var contentHits: [SearchMatch] = []
        var totalCount: Int? = nil
        var contentFileCount: Int? = nil
        let searchedFileCount = filteredFiles.count
        var pathError: RegexPatternFailure? = nil
        var contentError: RegexPatternFailure? = nil
        var perFileErrors: [(String, RegexPatternFailure)] = []

        // 1) Path search when requested
        if effectiveMode == .path || effectiveMode == .both {
            do {
                pathHits = try await searchPaths(
                    pattern: pattern,
                    limit: options.maxResults,
                    in: filteredFiles,
                    caseInsensitive: options.caseInsensitive,
                    isRegex: effectiveIsRegex,
                    aliasByRootPath: aliasByRootPath
                )
            } catch let e as RegexPatternFailure {
                pathError = e
            }
        }

        // 2) Content search when requested
        if effectiveMode == .content || effectiveMode == .both {
            do {
                if options.countOnly {
                    let result = try await searchWithErrors(
                        pattern: pattern,
                        isRegex: effectiveIsRegex,
                        wasAutoCorrected: &wasAutoCorrected,
                        options: SearchOptions(
                            caseInsensitive: options.caseInsensitive,
                            wholeWord: options.wholeWord,
                            includeExtensions: [], // Already filtered
                            excludePatterns: [], // Already filtered
                            maxResults: Int.max,
                            countOnly: true,
                            fuzzySpaceMatching: options.fuzzySpaceMatching,
                            contentFreshnessPolicy: options.contentFreshnessPolicy
                        ),
                        in: filteredFiles
                    )
                    totalCount = result.totalCount
                    contentFileCount = result.matchedFileCount
                    perFileErrors.append(contentsOf: result.perFileErrors)
                } else {
                    let result = try await searchWithErrors(
                        pattern: pattern,
                        isRegex: effectiveIsRegex,
                        wasAutoCorrected: &wasAutoCorrected,
                        options: SearchOptions(
                            caseInsensitive: options.caseInsensitive,
                            wholeWord: options.wholeWord,
                            includeExtensions: [], // Already filtered
                            excludePatterns: [], // Already filtered
                            contextLines: options.contextLines,
                            maxResults: options.maxResults,
                            fuzzySpaceMatching: options.fuzzySpaceMatching,
                            contentFreshnessPolicy: options.contentFreshnessPolicy
                        ),
                        in: filteredFiles
                    )
                    contentHits = result.matches
                    contentFileCount = Set(contentHits.map(\.filePath)).count
                    perFileErrors.append(contentsOf: result.perFileErrors)
                }
            } catch let e as RegexPatternFailure {
                contentError = e
            }
        }

        // Only re-throw when both phases fail (if both were requested)
        if effectiveMode == .both, pathError != nil, contentError != nil {
            // Both phases failed, re-throw the content error as it's usually more specific
            perfStatus = "error"
            throw contentError!
        } else if effectiveMode == .path, pathError != nil {
            // Only path search was requested and it failed
            perfStatus = "error"
            throw pathError!
        } else if effectiveMode == .content, contentError != nil {
            // Only content search was requested and it failed
            perfStatus = "error"
            throw contentError!
        }
        perfMatchCount = totalCount ?? (pathHits.count + contentHits.count)

        let resultConstructionState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.resultConstruction,
            EditFlowPerf.Dimensions(
                matchCount: perfMatchCount,
                admittedFileCount: searchedFileCount,
                matchedFileCount: contentFileCount,
                contentMatchCount: totalCount ?? contentHits.count,
                pathMatchCount: pathHits.count,
                errorCount: perFileErrors.count,
                searchMode: effectiveMode.rawValue,
                countOnly: options.countOnly
            )
        )
        let results = SearchResults(
            paths: pathHits,
            matches: contentHits,
            contentFileCount: contentFileCount,
            totalCount: totalCount,
            searchedFileCount: searchedFileCount,
            pathError: pathError,
            contentError: contentError,
            perFileErrors: perFileErrors
        )
        EditFlowPerf.end(
            EditFlowPerf.Stage.Search.resultConstruction,
            resultConstructionState,
            EditFlowPerf.Dimensions(
                outcome: "completed",
                matchCount: perfMatchCount,
                admittedFileCount: searchedFileCount,
                matchedFileCount: contentFileCount,
                contentMatchCount: totalCount ?? contentHits.count,
                pathMatchCount: pathHits.count,
                errorCount: perFileErrors.count,
                searchMode: effectiveMode.rawValue,
                countOnly: options.countOnly
            )
        )
        return results
    }

    /// Unified search combining path and content search with full SearchOptions support (backward compatibility)
    func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel],
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        // Entry point for MCP tool integration

        var autoCorrected: Bool? = nil
        return try await searchUnified(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &autoCorrected,
            options: options,
            in: files,
            aliasByRootPath: aliasByRootPath
        )
    }

    func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        options: SearchOptions = SearchOptions(),
        in files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore,
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        var autoCorrected: Bool? = nil
        return try await searchUnified(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &autoCorrected,
            options: options,
            in: files,
            rootsByID: rootsByID,
            store: store,
            aliasByRootPath: aliasByRootPath
        )
    }

    // MARK: – Helper to choose automatic mode ––––––––––––––––––––––––

    static func inferredAutoMode(_ raw: String) -> SearchMode {
        // Quick heuristics (order matters) - designed for intuitive user experience

        // REGEX PATTERNS should search content, not paths
        if containsRegexSyntax(raw) {
            return .content
        }

        // Strong path indicators should override other signals
        if raw.hasPrefix("*") || raw.hasPrefix(".") {
            return .path
        }

        // Check for wildcards anywhere in the pattern
        if raw.contains("*") || raw.contains("?") {
            return .path
        }

        // Forward slashes are strong path indicators unless it's clearly content (like a sentence)
        if raw.contains("/") {
            // If it has spaces but is short and path-like, still treat as path
            if raw.contains(" "), raw.count > 20 {
                return .content // Long patterns with spaces are likely content
            }
            return .path
        }

        // Backslashes are ambiguous: they may indicate Windows paths, or escaped literal metacharacters.
        if raw.contains("\\") {
            if backslashesOnlyEscapeRegexMeta(raw) {
                return .content
            }
            if raw.contains(" "), raw.count > 20 {
                return .content
            }
            return .path
        }

        // Content indicators
        if raw.contains("\n") { return .content }
        if raw.contains(" "), raw.count > 10 { return .content }

        // Short patterns should search both to be thorough
        if raw.count <= 3 { return .both }

        // Identifier-like tokens (e.g., "Player", "Bomb", "MyClass.swift") should search both
        // paths and content - this is the most intuitive UX for code search
        if isIdentifierLike(raw) { return .both }

        // Medium patterns with spaces are likely content searches
        if raw.contains(" ") { return .content }

        // Everything else defaults to content (most common use case)
        return .content
    }

    private static func inferMode(_ raw: String) -> SearchMode {
        inferredAutoMode(raw)
    }

    private static func backslashesOnlyEscapeRegexMeta(_ raw: String) -> Bool {
        let chars = Array(raw)
        var index = 0
        var sawEscapedMeta = false
        while index < chars.count {
            guard chars[index] == "\\" else {
                index += 1
                continue
            }
            if index + 2 < chars.count,
               chars[index + 1] == "\\",
               regexMeta.contains(chars[index + 2])
            {
                sawEscapedMeta = true
                index += 3
                continue
            }
            if index + 1 < chars.count,
               regexMeta.contains(chars[index + 1])
            {
                sawEscapedMeta = true
                index += 2
                continue
            }
            return false
        }
        return sawEscapedMeta
    }

    /// Checks if a pattern looks like an identifier or filename (no spaces, no regex chars).
    /// Used to determine if auto mode should search both paths and content.
    private static func isIdentifierLike(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }

        // Must be a single token (no spaces or path separators)
        if s.contains(" ") || s.contains("/") || s.contains("\\") { return false }

        // No obvious regex metacharacters
        let forbidden: Set<Character> = ["*", "+", "?", "[", "]", "{", "}", "(", ")", "|", "^", "$"]
        if s.contains(where: forbidden.contains) { return false }

        // Restrict to common identifier/filename characters: letters, digits, dot, underscore, hyphen
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        if s.unicodeScalars.contains(where: { !allowed.contains($0) }) { return false }

        return true
    }

    // MARK: - Helper to detect regex patterns  ------------------------------

    /// Detects if a pattern contains regex syntax that should trigger regex mode
    static func containsRegexSyntax(_ pattern: String) -> Bool {
        if RegexToolkit.usesPCREOnlyFeatures(pattern) {
            return true
        }

        // Check for clear regex patterns that are unlikely to be literal searches

        // Check for parentheses (capture groups) - but only if they look like regex
        // e.g., "(foo|bar)" or "func()" - we need to be smart about this
        if pattern.contains("(") && pattern.contains(")") {
            // Check if it's likely a regex group (has | inside or special chars)
            if let openParen = pattern.firstIndex(of: "("),
               let closeParen = pattern.firstIndex(of: ")"),
               openParen < closeParen
            {
                let insideParens = String(pattern[pattern.index(after: openParen) ..< closeParen])
                // If there's a pipe inside parens, it's likely regex
                if insideParens.contains("|") {
                    return true
                }
                // If the pattern starts with common regex anchors/modifiers before the paren
                let beforeParen = String(pattern[..<openParen])
                if beforeParen.hasSuffix("?:") || beforeParen.hasSuffix("?=") ||
                    beforeParen.hasSuffix("?!") || beforeParen.hasSuffix("?<=") ||
                    beforeParen.hasSuffix("?<!")
                {
                    return true
                }
            }
        }

        // Pipe operator with non-empty alternatives on both sides (e.g., "foo|bar")
        // This avoids false positives for lone pipes or pipes at edges
        if pattern.contains("|") {
            let components = pattern.split(separator: "|", omittingEmptySubsequences: false)
            // Only treat as regex if there are at least 2 non-empty components
            let nonEmptyCount = components.count(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            if nonEmptyCount >= 2 {
                return true
            }
        }

        // Common regex patterns that are very unlikely to be literal searches
        let strongRegexPatterns = [
            "\\b", // Word boundary
            "\\w", // Word character
            "\\d", // Digit
            "\\s", // Whitespace
            "\\n", // Newline
            "\\t", // Tab
            "^$", // Empty line
            ".*", // Any character sequence
            ".+" // At least one character
        ]

        for regexPattern in strongRegexPatterns {
            if pattern.contains(regexPattern) {
                return true
            }
        }

        // Check for character classes [...]
        if let openBracket = pattern.firstIndex(of: "["),
           let closeBracket = pattern.firstIndex(of: "]"),
           openBracket < closeBracket
        {
            return true
        }

        // Check for quantifiers {n,m}
        if let openBrace = pattern.firstIndex(of: "{"),
           let closeBrace = pattern.firstIndex(of: "}"),
           openBrace < closeBrace
        {
            let between = pattern[pattern.index(after: openBrace) ..< closeBrace]
            // Check if it looks like a quantifier (digits and comma)
            if between.allSatisfy({ $0.isNumber || $0 == "," }) {
                return true
            }
        }

        // Check for anchors at start/end
        if pattern.hasPrefix("^") || pattern.hasSuffix("$") {
            return true
        }

        return false
    }

    // MARK: - Literal substring helper --------------------------------------

    private static func containsSubstring(_ haystack: String, needle: String, caseInsensitive: Bool) -> Bool {
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        return haystack.range(of: needle, options: options) != nil
    }

    // MARK: - Helper for fuzzy space matching  ------------------------------

    /// Converts spaces in a literal pattern to flexible PCRE2 whitespace regex patterns.
    /// Each literal space becomes `\s+`, preserving the existing fuzzy-space behavior.
    private static func convertSpacesToFuzzyRegex(_ pattern: String) -> String {
        pattern
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { RepoPromptPCRE2Adapter.escapedLiteral(String($0)) }
            .joined(separator: "\\s+")
    }
}
