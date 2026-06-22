import Dispatch
import Foundation
import RepoPromptCore

struct HeadlessSearchResult {
    var summary: String
    var structured: [String: Any]
}

struct HeadlessSearchLimits {
    var maxCatalogEntries: Int = 20000
    var maxContentFiles: Int = 2048
    var maxContentBytes: Int = 64 * 1024 * 1024
    var maxElapsedNanoseconds: UInt64 = 3_000_000_000
    var maxMatcherWorkBytes: Int = 32 * 1024 * 1024
    var maxRegexSubjectBytes: Int = 64 * 1024
    var regexMatchLimits = PCRE2MatchLimits(
        matchLimit: 250_000,
        depthLimit: 10000,
        heapLimitKiB: 8 * 1024
    )
}

final class HeadlessSearchService {
    private let catalog: HeadlessFileCatalog
    private let secureFileAccess: HeadlessSecureFileAccess
    private let limits: HeadlessSearchLimits
    private let monotonicNow: () -> UInt64
    private let maxReadableBytes = 2 * 1024 * 1024

    init(
        catalog: HeadlessFileCatalog = HeadlessFileCatalog(),
        secureFileAccess: HeadlessSecureFileAccess = HeadlessSecureFileAccess(),
        maxCatalogEntries: Int = 20000
    ) {
        var limits = HeadlessSearchLimits()
        limits.maxCatalogEntries = max(0, maxCatalogEntries)
        self.catalog = catalog
        self.secureFileAccess = secureFileAccess
        self.limits = limits
        monotonicNow = { DispatchTime.now().uptimeNanoseconds }
    }

    init(
        catalog: HeadlessFileCatalog = HeadlessFileCatalog(),
        secureFileAccess: HeadlessSecureFileAccess = HeadlessSecureFileAccess(),
        limits: HeadlessSearchLimits,
        monotonicNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.catalog = catalog
        self.secureFileAccess = secureFileAccess
        self.limits = HeadlessSearchLimits(
            maxCatalogEntries: max(0, limits.maxCatalogEntries),
            maxContentFiles: max(0, limits.maxContentFiles),
            maxContentBytes: max(0, limits.maxContentBytes),
            maxElapsedNanoseconds: limits.maxElapsedNanoseconds,
            maxMatcherWorkBytes: max(0, limits.maxMatcherWorkBytes),
            maxRegexSubjectBytes: max(0, limits.maxRegexSubjectBytes),
            regexMatchLimits: limits.regexMatchLimits
        )
        self.monotonicNow = monotonicNow
    }

    func search(roots: [HeadlessAllowedRoot], resolver: HeadlessPathResolver, arguments: [String: Any]) throws -> HeadlessSearchResult {
        let pattern = try HeadlessToolArguments.requiredString(arguments, key: "pattern")
        let mode = HeadlessToolArguments.string(arguments, key: "mode") ?? "auto"
        let countOnly = HeadlessToolArguments.bool(arguments, key: "count_only") ?? false
        let maxResults = max(1, min(HeadlessToolArguments.int(arguments, key: "max_results") ?? 50, 1000))
        let contextLines = max(0, min(HeadlessToolArguments.int(arguments, key: "context_lines") ?? 0, 5))
        let wholeWord = HeadlessToolArguments.bool(arguments, key: "whole_word") ?? false
        let regexFlag = HeadlessToolArguments.bool(arguments, key: "regex")
        let useRegex = regexFlag ?? Self.looksLikeRegex(pattern)
        let effectiveMode = mode == "auto" ? "both" : mode
        guard ["path", "content", "both"].contains(effectiveMode) else {
            throw HeadlessCommandError("Unsupported file_search mode '\(mode)'. Expected auto, path, content, or both.", exitCode: 2)
        }

        let filter = arguments["filter"] as? [String: Any] ?? [:]
        let extensions = Set((HeadlessToolArguments.stringArray(filter, key: "extensions") ?? []).map { ext in
            ext.hasPrefix(".") ? ext.lowercased() : ".\(ext.lowercased())"
        })
        let exclude = HeadlessToolArguments.stringArray(filter, key: "exclude") ?? []
        let filterPaths = (HeadlessToolArguments.stringArray(filter, key: "paths") ?? []) + (HeadlessToolArguments.string(arguments, key: "path").map { [$0] } ?? [])
        let matcher = try Matcher(pattern: pattern, regex: useRegex, wholeWord: wholeWord, limits: limits.regexMatchLimits)
        let budget = HeadlessSearchBudgetTracker(limits: limits, monotonicNow: monotonicNow)

        var searchEntries: [HeadlessCatalogEntry] = []
        var catalogScanCount = 0
        var catalogWasTruncated = false
        var catalogSkippedEntries = 0
        let catalogCheckpoint = { try budget.checkpoint() }
        if filterPaths.isEmpty {
            let scanResult = try catalog.scan(
                roots: roots,
                maxEntries: limits.maxCatalogEntries,
                shouldContinue: catalogCheckpoint
            )
            searchEntries = scanResult.entries
            catalogScanCount = 1
            catalogWasTruncated = scanResult.wasTruncated
            catalogSkippedEntries = scanResult.skippedEntryCount
        } else {
            var seenEntries: Set<String> = []
            for filterPath in filterPaths {
                guard try budget.checkpoint(), searchEntries.count < limits.maxCatalogEntries else {
                    catalogWasTruncated = true
                    break
                }
                let resolved = try resolver.resolve(filterPath)
                let scanResult = try catalog.scan(
                    roots: [resolved.root],
                    under: resolved,
                    maxEntries: limits.maxCatalogEntries,
                    shouldContinue: catalogCheckpoint
                )
                catalogScanCount += 1
                catalogWasTruncated = catalogWasTruncated || scanResult.wasTruncated
                catalogSkippedEntries += scanResult.skippedEntryCount
                for entry in scanResult.entries {
                    guard try budget.checkpoint() else {
                        catalogWasTruncated = true
                        break
                    }
                    let key = "\(entry.root.id.uuidString):\(entry.relativePath)"
                    guard seenEntries.insert(key).inserted else { continue }
                    guard searchEntries.count < limits.maxCatalogEntries else {
                        catalogWasTruncated = true
                        break
                    }
                    searchEntries.append(entry)
                }
                if budget.isExhausted {
                    catalogWasTruncated = true
                    break
                }
            }
        }

        var pathMatches: [[String: Any]] = []
        var contentMatches: [[String: Any]] = []
        var totalPathMatches = 0
        var totalContentMatches = 0
        var returnedMatches = 0
        var catalogEntriesProcessed = 0
        var contentFilesScanned = 0
        var contentFilesSkipped = 0
        var contentBytesScanned = 0

        entryLoop: for entry in searchEntries where !entry.relativePath.isEmpty {
            guard try budget.checkpoint() else { break }
            catalogEntriesProcessed += 1
            if shouldSkip(entry: entry, extensions: extensions, exclude: exclude) {
                continue
            }
            if effectiveMode == "path" || effectiveMode == "both" {
                let displayMatched = try matcher.matches(entry.displayPath, budget: budget)
                guard !budget.isExhausted else { break }
                let relativeMatched = displayMatched ? false : try matcher.matches(entry.relativePath, budget: budget)
                guard !budget.isExhausted else { break }
                if displayMatched || relativeMatched {
                    totalPathMatches += 1
                    if !countOnly, returnedMatches < maxResults {
                        pathMatches.append(["path": entry.displayPath, "relative_path": entry.relativePath, "root": entry.root.name])
                        returnedMatches += 1
                    }
                }
            }
            guard !entry.isDirectory, effectiveMode == "content" || effectiveMode == "both" else {
                continue
            }
            guard let byteCount = entry.byteCount, byteCount <= maxReadableBytes else {
                contentFilesSkipped += 1
                continue
            }
            let contentByteCount = Int(byteCount)
            guard try budget.reserveContentFile(byteCount: contentByteCount) else { break }
            guard let snapshot = try? readTextFile(entry, maximumBytes: contentByteCount) else {
                contentFilesSkipped += 1
                continue
            }
            guard try budget.checkpoint() else { break }
            contentFilesScanned += 1
            contentBytesScanned += snapshot.byteCount
            let lines = snapshot.text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                guard try budget.checkpoint() else { break entryLoop }
                guard try matcher.matches(line, budget: budget) else {
                    if budget.isExhausted { break entryLoop }
                    continue
                }
                totalContentMatches += 1
                if !countOnly, returnedMatches < maxResults {
                    let start = max(0, index - contextLines)
                    let end = min(lines.count - 1, index + contextLines)
                    let context = (start ... end).map { lineIndex in
                        ["line": lineIndex + 1, "text": lines[lineIndex]] as [String: Any]
                    }
                    contentMatches.append([
                        "path": entry.displayPath,
                        "relative_path": entry.relativePath,
                        "root": entry.root.name,
                        "line": index + 1,
                        "text": line,
                        "context": context
                    ])
                    returnedMatches += 1
                }
            }
        }

        let totalMatches = totalPathMatches + totalContentMatches
        let omitted = max(0, totalMatches - maxResults)
        let includesPathSearch = effectiveMode == "path" || effectiveMode == "both"
        let includesContentSearch = effectiveMode == "content" || effectiveMode == "both"
        let catalogComplete = !catalogWasTruncated && catalogSkippedEntries == 0
        let pathTotalsComplete = !includesPathSearch || (catalogComplete && !budget.isExhausted)
        let contentTotalsComplete = !includesContentSearch || (catalogComplete && contentFilesSkipped == 0 && !budget.isExhausted)
        let totalsComplete = pathTotalsComplete && contentTotalsComplete
        let totalDisplay = totalsComplete ? "\(totalMatches)" : "\(totalMatches) (lower bound)"
        var lines: [String] = [
            "## Search Results ✅",
            "- **Pattern**: `\(pattern)`",
            "- **Mode**: `\(mode)`",
            "- **Total matches**: \(totalDisplay)",
            "- **Path matches**: \(totalPathMatches)",
            "- **Content matches**: \(totalContentMatches)",
            "- **Returned matches**: \(returnedMatches)",
            "- **Omitted by max_results**: \(omitted)",
            "- **Catalog entries scanned**: \(searchEntries.count)",
            "- **Catalog entries processed**: \(catalogEntriesProcessed)",
            "- **Catalog entry limit**: \(limits.maxCatalogEntries) across \(catalogScanCount) scan(s)",
            "- **Content files read**: \(contentFilesScanned) / \(limits.maxContentFiles)",
            "- **Content bytes read**: \(contentBytesScanned) / \(limits.maxContentBytes)",
            "- **Matcher work bytes**: \(budget.matcherWorkBytes) / \(limits.maxMatcherWorkBytes)",
            "- **Elapsed budget**: \(budget.elapsedMilliseconds) ms / \(limits.maxElapsedNanoseconds / 1_000_000) ms"
        ]
        if countOnly {
            lines.append("- **Count only**: true")
        } else {
            if !pathMatches.isEmpty {
                lines.append("\n### Path Matches")
                for match in pathMatches {
                    lines.append("- `\(match["path"] as? String ?? "")`")
                }
            }
            if !contentMatches.isEmpty {
                lines.append("\n### Content Matches")
                for match in contentMatches {
                    let path = match["path"] as? String ?? ""
                    let line = match["line"] as? Int ?? 0
                    let text = match["text"] as? String ?? ""
                    lines.append("- `\(path):\(line)` \(text)")
                }
            }
            if omitted > 0 {
                lines.append("\n_Omitted \(omitted) match(es) after max_results=\(maxResults)._")
            }
        }
        if catalogWasTruncated {
            lines.append("\n⚠️ Catalog entry or search budget limit reached; eligible entries remain unscanned, so totals are lower bounds.")
        }
        if catalogSkippedEntries > 0 {
            lines.append("\n⚠️ Skipped \(catalogSkippedEntries) catalog entry or traversal error(s); totals are lower bounds.")
        }
        if includesContentSearch, contentFilesSkipped > 0 {
            lines.append("\n⚠️ Skipped \(contentFilesSkipped) unreadable, non-UTF-8, binary, or oversized content file(s); content totals are lower bounds.")
        }
        if let reason = budget.exhaustedReason {
            lines.append("\n⚠️ Search stopped at the bounded \(reason.summary); totals are lower bounds. Narrow the path/filter or pattern and retry.")
        }

        let budgetExhaustionReason: Any = budget.exhaustedReason?.rawValue as Any? ?? NSNull()
        return HeadlessSearchResult(summary: lines.joined(separator: "\n"), structured: [
            "pattern": pattern,
            "mode": mode,
            "regex": useRegex,
            "whole_word": wholeWord,
            "total_matches": totalMatches,
            "total_path_matches": totalPathMatches,
            "total_content_matches": totalContentMatches,
            "returned_matches": returnedMatches,
            "count_only": countOnly,
            "path_matches": pathMatches,
            "content_matches": contentMatches,
            "omitted": omitted,
            "catalog_entries_scanned": searchEntries.count,
            "catalog_entries_considered": searchEntries.count,
            "catalog_entries_processed": catalogEntriesProcessed,
            "catalog_entry_limit": limits.maxCatalogEntries,
            "catalog_scan_count": catalogScanCount,
            "catalog_truncated": catalogWasTruncated,
            "catalog_skipped_entries": catalogSkippedEntries,
            "content_files_scanned": contentFilesScanned,
            "content_files_attempted": budget.contentFilesAttempted,
            "content_file_limit": limits.maxContentFiles,
            "content_files_skipped": contentFilesSkipped,
            "content_bytes_scanned": contentBytesScanned,
            "content_bytes_considered": budget.contentBytesConsidered,
            "content_byte_limit": limits.maxContentBytes,
            "matcher_work_bytes": budget.matcherWorkBytes,
            "matcher_work_byte_limit": limits.maxMatcherWorkBytes,
            "regex_subject_byte_limit": limits.maxRegexSubjectBytes,
            "elapsed_milliseconds": budget.elapsedMilliseconds,
            "elapsed_time_limit_milliseconds": limits.maxElapsedNanoseconds / 1_000_000,
            "budget_exhausted": budget.isExhausted,
            "budget_exhaustion_reason": budgetExhaustionReason,
            "path_totals_complete": pathTotalsComplete,
            "content_totals_complete": contentTotalsComplete,
            "totals_complete": totalsComplete,
            "totals_are_lower_bounds": !totalsComplete,
            "total_matches_is_lower_bound": !totalsComplete,
            "omitted_is_lower_bound": !totalsComplete
        ])
    }

    private func shouldSkip(entry: HeadlessCatalogEntry, extensions: Set<String>, exclude: [String]) -> Bool {
        if !extensions.isEmpty, !entry.isDirectory {
            let ext = ".\(entry.url.pathExtension.lowercased())"
            if !extensions.contains(ext) {
                return true
            }
        }
        return exclude.contains { token in
            entry.relativePath.localizedCaseInsensitiveContains(token) || entry.displayPath.localizedCaseInsensitiveContains(token)
        }
    }

    private func readTextFile(_ entry: HeadlessCatalogEntry, maximumBytes: Int) throws -> (text: String, byteCount: Int) {
        let data = try secureFileAccess.readRegularFile(
            root: entry.root,
            relativePath: entry.relativePath,
            maximumBytes: min(maxReadableBytes, maximumBytes)
        ).data
        guard !data.contains(0) else {
            throw HeadlessCommandError("Binary file skipped: \(entry.displayPath)", exitCode: 2)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HeadlessCommandError("File is not valid UTF-8: \(entry.displayPath)", exitCode: 2)
        }
        return (text, data.count)
    }

    private static func looksLikeRegex(_ pattern: String) -> Bool {
        pattern.range(of: #"[.\[\]()*+?{}|^$]"#, options: .regularExpression) != nil
    }

    private struct Matcher {
        let pattern: String
        let regex: PCRE2Regex?
        let matchLimits: PCRE2MatchLimits

        init(pattern: String, regex: Bool, wholeWord: Bool, limits: PCRE2MatchLimits) throws {
            self.pattern = pattern
            matchLimits = limits
            guard regex || wholeWord else {
                self.regex = nil
                return
            }
            let source = regex ? pattern : PCRE2Literal.escapedPattern(for: pattern)
            let wrapped = wholeWord ? "\\b(?:\(source))\\b" : source
            do {
                try RegexToolkit.validateComplexity(wrapped, isRegex: true)
                self.regex = try PCRE2Regex(wrapped)
            } catch {
                throw HeadlessCommandError("Invalid or unsafe regular expression: \(error.localizedDescription)", exitCode: 2)
            }
        }

        func matches(_ text: String, budget: HeadlessSearchBudgetTracker) throws -> Bool {
            let subjectBytes = text.utf8.count
            guard try budget.reserveMatcherWork(subjectBytes: subjectBytes, isRegex: regex != nil) else {
                return false
            }
            guard let regex else {
                return text.localizedCaseInsensitiveContains(pattern)
            }
            do {
                let matched = try regex.firstMatch(in: text, matchLimits: matchLimits) != nil
                guard try budget.checkpoint() else { return false }
                return matched
            } catch let error as PCRE2Error {
                switch error {
                case .matchLimitExceeded:
                    budget.exhaust(.regexMatchLimit)
                    return false
                default:
                    throw HeadlessCommandError("Regular expression matching failed: \(error.localizedDescription)", exitCode: 2)
                }
            }
        }
    }
}

private final class HeadlessSearchBudgetTracker {
    enum ExhaustionReason: String {
        case timeLimit = "time_limit"
        case contentFileLimit = "content_file_limit"
        case contentByteLimit = "content_byte_limit"
        case matcherWorkLimit = "matcher_work_limit"
        case regexSubjectLimit = "regex_subject_limit"
        case regexMatchLimit = "regex_match_limit"

        var summary: String {
            switch self {
            case .timeLimit: "elapsed-time budget"
            case .contentFileLimit: "content-file budget"
            case .contentByteLimit: "content-byte budget"
            case .matcherWorkLimit: "matcher-work budget"
            case .regexSubjectLimit: "per-subject regex budget"
            case .regexMatchLimit: "per-match regex engine budget"
            }
        }
    }

    let limits: HeadlessSearchLimits
    let monotonicNow: () -> UInt64
    let startedAt: UInt64
    private(set) var lastObservedAt: UInt64
    private(set) var contentFilesAttempted = 0
    private(set) var contentBytesConsidered = 0
    private(set) var matcherWorkBytes = 0
    private(set) var exhaustedReason: ExhaustionReason?

    init(limits: HeadlessSearchLimits, monotonicNow: @escaping () -> UInt64) {
        self.limits = limits
        self.monotonicNow = monotonicNow
        let now = monotonicNow()
        startedAt = now
        lastObservedAt = now
    }

    var isExhausted: Bool {
        exhaustedReason != nil
    }

    var elapsedMilliseconds: UInt64 {
        guard lastObservedAt >= startedAt else { return 0 }
        return (lastObservedAt - startedAt) / 1_000_000
    }

    func checkpoint() throws -> Bool {
        try Task.checkCancellation()
        guard exhaustedReason == nil else { return false }
        let now = monotonicNow()
        lastObservedAt = max(lastObservedAt, now)
        if now >= startedAt, now - startedAt >= limits.maxElapsedNanoseconds {
            exhaust(.timeLimit)
            return false
        }
        try Task.checkCancellation()
        return true
    }

    func reserveContentFile(byteCount: Int) throws -> Bool {
        guard try checkpoint() else { return false }
        guard contentFilesAttempted < limits.maxContentFiles else {
            exhaust(.contentFileLimit)
            return false
        }
        guard byteCount <= limits.maxContentBytes - min(contentBytesConsidered, limits.maxContentBytes) else {
            exhaust(.contentByteLimit)
            return false
        }
        contentFilesAttempted += 1
        contentBytesConsidered += byteCount
        return true
    }

    func reserveMatcherWork(subjectBytes: Int, isRegex: Bool) throws -> Bool {
        guard try checkpoint() else { return false }
        if isRegex, subjectBytes > limits.maxRegexSubjectBytes {
            exhaust(.regexSubjectLimit)
            return false
        }
        guard subjectBytes <= limits.maxMatcherWorkBytes - min(matcherWorkBytes, limits.maxMatcherWorkBytes) else {
            exhaust(.matcherWorkLimit)
            return false
        }
        matcherWorkBytes += subjectBytes
        return true
    }

    func exhaust(_ reason: ExhaustionReason) {
        if exhaustedReason == nil {
            exhaustedReason = reason
        }
    }
}
