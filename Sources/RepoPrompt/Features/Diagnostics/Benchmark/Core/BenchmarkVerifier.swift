import Foundation

enum BenchmarkVerifierReasons {
    static let outputPenalty = "Output Penalty"
    static let othersChanged = "Files outside the allowed list were modified."
    static let importerMismatch = "One or more importers still reference the old symbol name."
    static let tabFound = "Inserted snippet contained a tab; use spaces for indentation."
}

struct GradingPolicy {
    var passThreshold: Double = 0.8
    var lenient: Bool = true
    var softErrorPenalty: [String: Double] = [
        "TOO_MANY_EDITS": 0.15,
        "EDIT_APPLY_FAILED": 0.2,
        "TOO_FEW_EDITS": 0.15
    ]
    var hardErrors: Set<String> = [
        "UNEXPECTED_FILE_EDIT",
        "PARSE_OUTPUT_FAILED",
        "MODEL_EXECUTION_FAILED",
        "MODEL_OUTPUT_TOO_LARGE"
    ]
}

protocol BenchmarkVerifying {
    func verify(_ execution: BenchmarkTaskExecution) -> BenchmarkVerifyOutput
}

struct BenchmarkVerifier: BenchmarkVerifying {
    var policy: GradingPolicy

    init(policy: GradingPolicy = GradingPolicy()) {
        self.policy = policy
    }

    private func formatError(_ error: BenchmarkTaskError) -> String {
        // If there's a detail field, use it for more context
        if let detail = error.detail, !detail.isEmpty {
            return detail
        }
        // Otherwise, just return the code (will be formatted by humanReadableReason)
        return error.code
    }

    func verify(_ execution: BenchmarkTaskExecution) -> BenchmarkVerifyOutput {
        let errors = execution.result.errors
        let hard = errors.filter { policy.hardErrors.contains($0.code) }
        let soft = errors.filter { policy.softErrorPenalty[$0.code] != nil }
        let unknown = errors.filter { policy.softErrorPenalty[$0.code] == nil && !policy.hardErrors.contains($0.code) }
        if !hard.isEmpty {
            let codes = hard.map { formatError($0) }.joined(separator: ",")
            return BenchmarkVerifyOutput.failure(reason: codes)
        }
        if !unknown.isEmpty {
            let codes = unknown.map { formatError($0) }.joined(separator: ",")
            return BenchmarkVerifyOutput.failure(reason: codes)
        }
        if !soft.isEmpty, !policy.lenient {
            let codes = soft.map { formatError($0) }.joined(separator: ",")
            return BenchmarkVerifyOutput.failure(reason: codes)
        }

        let task = execution.task
        let baselineMap = execution.baseline.dictionary()
        let finalMap = buildFinalMap(baseline: baselineMap, edits: execution.result.edited)
        let base: BenchmarkVerifyOutput = switch task.type {
        case .removeXTs, .removeXGo, .removeXSwift:
            verifyRemoveX(task: task, baseline: baselineMap, final: finalMap)
        case .curlyFixTs, .curlyFixGo, .curlyFixSwift:
            verifyCurlyFix(task: task, baseline: baselineMap, final: finalMap)
        case .insertGuardTs, .insertGuardGo, .insertGuardSwift:
            verifyInsertGuard(task: task, baseline: baselineMap, final: finalMap)
        case .patchBlockTs, .patchBlockGo, .patchBlockSwift:
            verifyPatchBlock(task: task, baseline: baselineMap, final: finalMap)
        case .swapArgsInRegionTs, .swapArgsInRegionGo, .swapArgsInRegionSwift:
            verifySwapArgs(task: task, baseline: baselineMap, final: finalMap)
        case .indexOnlyAppsTs, .indexOnlyAppsGo, .indexOnlyAppsSwift:
            verifyIndexOnly(task: task, baseline: baselineMap, final: finalMap)
        case .renameExportImportsTs, .renameExportImportsGo, .renameExportImportsSwift:
            verifyRename(task: task, baseline: baselineMap, final: finalMap)
        case .moveFunctionTs, .moveFunctionGo, .moveFunctionSwift:
            verifyMoveFunction(task: task, baseline: baselineMap, final: finalMap)
        case .insertFunctionBottomTs, .insertFunctionBottomGo, .insertFunctionBottomSwift:
            verifyInsertFunctionBottom(task: task, baseline: baselineMap, final: finalMap)
        case .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift:
            verifyApplyUnifiedPatch(task: task, baseline: baselineMap, final: finalMap)
        }
        var scored = applyOutputPenalty(base, meta: execution.result.meta)

        // Apply TOO_FEW_EDITS soft penalty for curly_fix tasks
        if case .curlyFixTs = task.type, policy.lenient {
            scored = applyTooFewEditsPenalty(scored, task: task, execution: execution)
        } else if case .curlyFixGo = task.type, policy.lenient {
            scored = applyTooFewEditsPenalty(scored, task: task, execution: execution)
        } else if case .curlyFixSwift = task.type, policy.lenient {
            scored = applyTooFewEditsPenalty(scored, task: task, execution: execution)
        }

        if policy.lenient, !soft.isEmpty {
            let factor = soft.reduce(1.0) { partial, err in
                let penalty = policy.softErrorPenalty[err.code] ?? 0.0
                return partial * (1.0 - penalty)
            }
            let newScore = clampScore(scored.score * factor)
            var metrics = scored.metrics
            metrics["softErrors"] = .array(soft.map { .string($0.code) })
            metrics["softPenaltyFactor"] = .double(factor)
            let passAfter = scored.pass && newScore >= policy.passThreshold
            let reason = (!passAfter && scored.reason.isEmpty) ? soft.map { formatError($0) }.joined(separator: ",") : scored.reason
            scored = BenchmarkVerifyOutput(pass: passAfter, score: newScore, reason: reason, metrics: metrics)
        }
        return scored
    }

    private func clampScore(_ score: Double) -> Double {
        max(0.0, min(1.0, score))
    }

    private func buildFinalMap(baseline: [String: String], edits: [BenchmarkEditedFile]) -> [String: String] {
        var final = baseline
        for edit in edits {
            let normalized = BenchmarkMockFileSystem.normalize(edit.path)
            final[normalized] = edit.content
        }
        return final
    }

    private func applyOutputPenalty(_ result: BenchmarkVerifyOutput, meta: [String: BenchmarkJSONValue]?) -> BenchmarkVerifyOutput {
        guard let meta else { return result }
        let charCount = meta["rawCharCount"]?.intValue ?? 0
        let lineCount = meta["rawLineCount"]?.intValue ?? 0
        let charOver = max(0, charCount - 10000)
        let lineOver = max(0, lineCount - 200)
        if charOver == 0 && lineOver == 0 {
            return result
        }
        let charPenalty = 1.0 / (1.0 + Double(charOver) / 5000.0)
        let linePenalty = 1.0 / (1.0 + Double(lineOver) / 100.0)
        let penalty = min(charPenalty, linePenalty)
        let newScore = clampScore(result.score * penalty)
        var metrics = result.metrics
        metrics["penaltyApplied"] = .boolean(true)
        metrics["rawCharCount"] = .integer(charCount)
        metrics["rawLineCount"] = .integer(lineCount)
        metrics["finalScore"] = .double(newScore)
        let passAfter = result.pass && newScore >= policy.passThreshold
        let reason = (!passAfter && result.reason.isEmpty) ? "outputPenalty" : result.reason
        return BenchmarkVerifyOutput(pass: passAfter, score: newScore, reason: reason, metrics: metrics)
    }

    private func applyTooFewEditsPenalty(_ result: BenchmarkVerifyOutput, task: BenchmarkTaskSpec, execution: BenchmarkTaskExecution) -> BenchmarkVerifyOutput {
        // Read minEditsPerFile from task params
        let minEditsPerFile = task.params["minEditsPerFile"]?.intValue ?? 0
        guard minEditsPerFile > 0 else { return result }

        // Read editBlockCountTotal from execution meta
        let editBlockCountTotal = execution.result.meta?["editBlockCountTotal"]?.intValue ?? 0

        // Calculate minimum required edits based on file count
        let filesCount = task.params["files"]?.arrayValue?.count ?? max(1, task.selectFiles.count)
        let minEditsRequired = minEditsPerFile * filesCount

        // Check if penalty should apply
        guard editBlockCountTotal < minEditsRequired else {
            // No penalty, but add metrics for transparency
            var metrics = result.metrics
            metrics["minEditsRequired"] = .integer(minEditsRequired)
            metrics["editBlocksUsed"] = .integer(editBlockCountTotal)
            metrics["tooFewEditsPenaltyApplied"] = .boolean(false)
            return BenchmarkVerifyOutput(pass: result.pass, score: result.score, reason: result.reason, metrics: metrics)
        }

        // Apply the TOO_FEW_EDITS soft penalty
        let penaltyFactor = policy.softErrorPenalty["TOO_FEW_EDITS"] ?? 0.15
        let newScore = clampScore(result.score * (1.0 - penaltyFactor))
        var metrics = result.metrics
        metrics["minEditsRequired"] = .integer(minEditsRequired)
        metrics["editBlocksUsed"] = .integer(editBlockCountTotal)
        metrics["tooFewEditsPenaltyApplied"] = .boolean(true)
        metrics["tooFewEditsPenaltyFactor"] = .double(penaltyFactor)

        let passAfter = result.pass && newScore >= policy.passThreshold
        let reason = (!passAfter && result.reason.isEmpty) ? "TOO_FEW_EDITS" : result.reason

        return BenchmarkVerifyOutput(pass: passAfter, score: newScore, reason: reason, metrics: metrics)
    }

    // MARK: - remove_x_ts

    private func verifyRemoveX(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        guard let path = task.params["file"]?.stringValue,
              let baselineText = baseline[path],
              let finalText = final[path]
        else {
            return BenchmarkVerifyOutput.failure(reason: "missingTargetFile")
        }
        let target = task.params["target"]?.stringValue ?? "CALL_X("
        let baseCode = stripTSComments(baselineText)
        let finalCode = stripTSComments(finalText)
        let baselineCount = max(0, countOccurrences(of: target, in: baseCode))
        let finalCount = max(0, countOccurrences(of: target, in: finalCode))
        let removed = max(0, baselineCount - finalCount)
        let denominator = max(1, baselineCount)
        var score = Double(removed) / Double(denominator)
        let nearTokens: [String] = [
            "call_x(",
            "CALL_XY("
        ]
        let baselineNear = nearTokens.reduce(0) { $0 + countOccurrences(of: $1, in: baseCode) }
        let finalNear = nearTokens.reduce(0) { $0 + countOccurrences(of: $1, in: finalCode) }
        var reason = ""
        let nearMissChanged = finalNear < baselineNear
        if nearMissChanged {
            reason = "nearMissChanged"
            if policy.lenient {
                score = max(0.0, score - 0.25)
            } else {
                let metrics: [String: BenchmarkJSONValue] = [
                    "nearMissBaseline": .integer(baselineNear),
                    "nearMissFinal": .integer(finalNear)
                ]
                return BenchmarkVerifyOutput.failure(reason: reason, metrics: metrics)
            }
        } else if finalCount > 0 {
            reason = "refsRemain:\(finalCount)"
        }
        let metrics: [String: BenchmarkJSONValue] = [
            "baseline": .integer(baselineCount),
            "final": .integer(finalCount),
            "removed": .integer(removed),
            "nearMissBaseline": .integer(baselineNear),
            "nearMissFinal": .integer(finalNear)
        ]
        return makeScoredOutput(score: score, reason: reason, metrics: metrics)
    }

    // MARK: - curly_fix_go

    private func verifyCurlyFix(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        if let files = task.params["files"]?.arrayValue?.compactMap(\.stringValue), !files.isEmpty {
            var components: [(String, BenchmarkVerifyOutput)] = []
            for file in files {
                let subTask = BenchmarkTaskSpec(
                    id: "\(task.id)::\(file)",
                    type: task.type,
                    language: task.language,
                    difficulty: task.difficulty,
                    format: task.format,
                    selectFiles: [file],
                    newChat: task.newChat,
                    maxEdits: max(1, task.maxEdits / max(files.count, 1)),
                    instructions: task.instructions,
                    task: task.task,
                    acceptance: task.acceptance,
                    params: ["file": .string(file)]
                )
                components.append((file, verifyCurlyFix(task: subTask, baseline: baseline, final: final)))
            }
            return aggregate(components, label: "curlyFixBundle")
        }
        let path = task.params["file"]?.stringValue ?? "src/go/main.go"
        guard let finalText = final[path], let baselineText = baseline[path] else {
            return BenchmarkVerifyOutput.failure(reason: "missingTargetFile")
        }

        // Use language-aware brace balancing (ignores braces in comments/strings)
        let balanced = braceBalanced(finalText, language: task.language)

        // Find all for-loop blocks using the new helper
        let forRanges = allForBlockRanges(in: finalText, language: task.language)

        // Count print statements inside vs outside all loops
        let printRegex: NSRegularExpression? = switch task.language {
        case .go:
            try? NSRegularExpression(pattern: #"fmt\.Print(ln|f)\s*\([^)]*\)"#, options: [])
        case .ts:
            try? NSRegularExpression(pattern: #"console\.log\s*\([^)]*\)"#, options: [])
        case .swift:
            try? NSRegularExpression(pattern: #"print\s*\([^)]*\)"#, options: [])
        }
        var printsInside = 0
        var printsOutside = 0
        if let printRegex {
            let ns = finalText as NSString
            let full = NSRange(location: 0, length: ns.length)
            printRegex.enumerateMatches(in: finalText, options: [], range: full) { match, _, _ in
                guard let match, let range = Range(match.range, in: finalText) else { return }
                // Check if this print is inside any loop
                var inAnyLoop = false
                for loopRange in forRanges {
                    if range.lowerBound >= loopRange.lowerBound, range.upperBound <= loopRange.upperBound {
                        inAnyLoop = true
                        break
                    }
                }
                if inAnyLoop {
                    printsInside += 1
                } else {
                    printsOutside += 1
                }
            }
        }

        // Check for collateral changes using sanitized comparison (removes all "}")
        let sanitizedBaseline = sanitizeForCurlyComparison(baselineText)
        let sanitizedFinal = sanitizeForCurlyComparison(finalText)
        let unchangedOutside = sanitizedBaseline == sanitizedFinal

        // Scoring: 0.4 braces balanced + 0.4 prints correct + 0.2 no collateral
        var score = 0.0
        if balanced {
            score += 0.4
        }
        if printsOutside == 1, printsInside == 0 {
            score += 0.4
        }
        if unchangedOutside {
            score += 0.2
        }

        let reason: String = {
            if !balanced {
                return "braceUnbalanced"
            }
            if printsInside > 0 {
                return "printCallInsideLoop"
            }
            if printsOutside != 1 {
                return "printCallCountMismatch"
            }
            if !unchangedOutside {
                return "collateralChange"
            }
            return ""
        }()

        let metrics: [String: BenchmarkJSONValue] = [
            "balanced": .boolean(balanced),
            "printInside": .integer(printsInside),
            "printOutside": .integer(printsOutside),
            "unchangedOutside": .boolean(unchangedOutside),
            "forLoopCount": .integer(forRanges.count)
        ]
        return makeScoredOutput(score: score, reason: reason, metrics: metrics)
    }

    private func braceBalanced(_ text: String, language: BenchmarkLanguage) -> Bool {
        enum ScanState {
            case code
            case lineComment
            case blockComment
            case string(Character) // " or '
            case templateString // for TS backticks
        }

        var balance = 0
        var state = ScanState.code
        var escapeNext = false
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]

            // Handle escape sequences
            if escapeNext {
                escapeNext = false
                index = text.index(after: index)
                continue
            }

            switch state {
            case .code:
                // Check for comment starts
                if char == "/", text.index(after: index) < text.endIndex {
                    let nextChar = text[text.index(after: index)]
                    if nextChar == "/" {
                        state = .lineComment
                        index = text.index(after: index)
                        index = text.index(after: index)
                        continue
                    } else if nextChar == "*" {
                        state = .blockComment
                        index = text.index(after: index)
                        index = text.index(after: index)
                        continue
                    }
                }
                // Check for string starts
                if char == "\"" {
                    state = .string("\"")
                    index = text.index(after: index)
                    continue
                }
                if char == "'" {
                    state = .string("'")
                    index = text.index(after: index)
                    continue
                }
                // Check for template string (TypeScript)
                if language == .ts, char == "`" {
                    state = .templateString
                    index = text.index(after: index)
                    continue
                }
                // Count braces only in code state
                if char == "{" {
                    balance += 1
                } else if char == "}" {
                    balance -= 1
                    if balance < 0 {
                        return false
                    }
                }

            case .lineComment:
                if char == "\n" {
                    state = .code
                }

            case .blockComment:
                if char == "*", text.index(after: index) < text.endIndex {
                    let nextChar = text[text.index(after: index)]
                    if nextChar == "/" {
                        state = .code
                        index = text.index(after: index)
                    }
                }

            case let .string(delim):
                if char == "\\" {
                    escapeNext = true
                } else if char == delim {
                    state = .code
                }

            case .templateString:
                if char == "\\" {
                    escapeNext = true
                } else if char == "`" {
                    state = .code
                }
            }

            index = text.index(after: index)
        }

        return balance == 0
    }

    private func allForBlockRanges(in text: String, language: BenchmarkLanguage) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            // Look for "for" keyword
            let pattern = switch language {
            case .ts:
                "for ("
            case .go:
                "for "
            case .swift:
                "for "
            }

            guard let forRange = text.range(of: pattern, range: searchStart ..< text.endIndex) else {
                break
            }

            // Find the opening brace after "for"
            var cursor = forRange.upperBound
            while cursor < text.endIndex, text[cursor] != "{" {
                cursor = text.index(after: cursor)
            }

            if cursor < text.endIndex {
                // Try to find the matching block using language-aware matching
                if let blockRange = findMatchingBlock(in: text, from: cursor, language: language) {
                    ranges.append(blockRange)
                    searchStart = blockRange.upperBound
                } else {
                    searchStart = text.index(after: cursor)
                }
            } else {
                break
            }
        }

        return ranges
    }

    private func findMatchingBlock(in text: String, from start: String.Index, language: BenchmarkLanguage) -> Range<String.Index>? {
        enum ScanState {
            case code
            case lineComment
            case blockComment
            case string(Character)
            case templateString
        }

        var depth = 0
        var seenOpen = false
        var current = start
        var blockStart: String.Index?
        var state = ScanState.code
        var escapeNext = false

        while current < text.endIndex {
            let char = text[current]

            // Handle escape sequences
            if escapeNext {
                escapeNext = false
                current = text.index(after: current)
                continue
            }

            switch state {
            case .code:
                // Check for comment starts
                if char == "/", text.index(after: current) < text.endIndex {
                    let nextChar = text[text.index(after: current)]
                    if nextChar == "/" {
                        state = .lineComment
                        current = text.index(after: current)
                        current = text.index(after: current)
                        continue
                    } else if nextChar == "*" {
                        state = .blockComment
                        current = text.index(after: current)
                        current = text.index(after: current)
                        continue
                    }
                }
                // Check for string starts
                if char == "\"" {
                    state = .string("\"")
                    current = text.index(after: current)
                    continue
                }
                if char == "'" {
                    state = .string("'")
                    current = text.index(after: current)
                    continue
                }
                // Check for template string (TypeScript)
                if language == .ts, char == "`" {
                    state = .templateString
                    current = text.index(after: current)
                    continue
                }
                // Count braces only in code state
                if char == "{" {
                    depth += 1
                    if !seenOpen {
                        seenOpen = true
                        blockStart = current
                    }
                } else if char == "}" {
                    if !seenOpen {
                        return nil
                    }
                    depth -= 1
                    if depth == 0 {
                        guard let startIndex = blockStart else { return nil }
                        return startIndex ..< text.index(after: current)
                    }
                }

            case .lineComment:
                if char == "\n" {
                    state = .code
                }

            case .blockComment:
                if char == "*", text.index(after: current) < text.endIndex {
                    let nextChar = text[text.index(after: current)]
                    if nextChar == "/" {
                        state = .code
                        current = text.index(after: current)
                    }
                }

            case let .string(delim):
                if char == "\\" {
                    escapeNext = true
                } else if char == delim {
                    state = .code
                }

            case .templateString:
                if char == "\\" {
                    escapeNext = true
                } else if char == "`" {
                    state = .code
                }
            }

            current = text.index(after: current)
        }
        return nil
    }

    private func normalizeForMoveComparison(_ text: String) -> String {
        // Normalize line endings
        let result = text.replacingOccurrences(of: "\r\n", with: "\n")

        // Drop all blank lines entirely and trim whitespace per line.
        // This makes the comparison robust to blank-line differences that occur
        // when removing and reinserting a moved function (top/bottom and between functions),
        // while still detecting any non-empty line changes as collateral.
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }
            out.append(trimmed)
        }
        return out.joined(separator: "\n")
    }

    /// Finds the range of a function declaration in the given text.
    ///
    /// Uses regex patterns to robustly match functions with various modifiers:
    /// - TypeScript: export, async, decorators
    /// - Swift: public, private, internal, static, @objc, etc.
    /// - Go: standard func declarations
    ///
    /// Note: Currently supports regular function declarations. Arrow functions and class methods
    /// are not yet supported but could be added if needed for benchmark tasks.
    private func findFunctionRange(in text: String, name: String, language: BenchmarkLanguage) -> Range<String.Index>? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let regexPattern = switch language {
        case .ts:
            // Match: [export] [async] function name(
            // Handles modifiers, whitespace, and optional type parameters
            #"(?:^|\n)(?:(?:export|async)\s+)*function\s+"# + escapedName + #"\s*(?:<[^>]+>)?\s*\("#
        case .go:
            // Match: func name(
            // Go is simpler - no export keyword, but may have receiver types
            #"(?:^|\n)func\s+(?:\([^)]*\)\s+)?"# + escapedName + #"\s*\("#
        case .swift:
            // Match: [@decorator]* [public|private|internal|static|class|final|override]* func name(
            // Handles multiple attributes (@objc @available) and modifiers (final override public)
            #"(?:^|\n)(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|internal|open|fileprivate|static|class|final|override)\s+)*func\s+"# + escapedName + #"\s*(?:<[^>]+>)?\s*\("#
        }

        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
              let matchRange = Range(match.range, in: text)
        else {
            return nil
        }

        // Start includes all modifiers from beginning of line
        var start = matchRange.lowerBound

        // If the match included a leading newline (from (?:^|\n) pattern),
        // skip past it - that newline belongs to the previous function's trailing whitespace
        if start < text.endIndex, text[start].isNewline {
            start = text.index(after: start)
        }

        // Move to start of line to capture all leading modifiers/decorators
        while start > text.startIndex {
            let prev = text.index(before: start)
            let char = text[prev]
            if char.isNewline {
                break
            }
            start = prev
        }

        // Find the opening brace after the match
        var cursor = matchRange.upperBound
        while cursor < text.endIndex, text[cursor] != "{" {
            cursor = text.index(after: cursor)
        }

        guard cursor < text.endIndex, let block = findMatchingBlock(in: text, from: cursor, language: language) else {
            return nil
        }

        // Include trailing blank lines (up to 2 newlines total) so whitespace moves with the function
        var end = block.upperBound
        var newlineCount = 0
        while end < text.endIndex, text[end].isNewline, newlineCount < 2 {
            end = text.index(after: end)
            newlineCount += 1
        }

        return start ..< end
    }

    private func textByRemovingRange(_ text: String, range: Range<String.Index>) -> String {
        var mutable = text
        mutable.removeSubrange(range)
        return mutable
    }

    // MARK: - move_function_ts

    private func extendRangeToIncludeLeadingComments(in text: String, range: Range<String.Index>, language: BenchmarkLanguage) -> Range<String.Index> {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // Find the line index of range start
        var currentPos = text.startIndex
        var lineIdx = 0
        for (idx, line) in lines.enumerated() {
            let lineEndPos = text.index(currentPos, offsetBy: line.count + 1, limitedBy: text.endIndex) ?? text.endIndex
            if range.lowerBound >= currentPos, range.lowerBound < lineEndPos {
                lineIdx = idx
                break
            }
            currentPos = lineEndPos
        }
        // Look backwards for contiguous comment lines or blank lines
        var extendToLine = lineIdx
        for i in (0 ..< lineIdx).reversed() {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "//") || trimmed.starts(with: "/*") || trimmed.starts(with: "*") || trimmed.starts(with: "/**") || trimmed.starts(with: "///") || trimmed.isEmpty {
                extendToLine = i
            } else {
                break
            }
        }
        // Calculate new start position
        if extendToLine < lineIdx {
            var newStart = text.startIndex
            for i in 0 ..< extendToLine {
                newStart = text.index(newStart, offsetBy: lines[i].count + 1, limitedBy: text.endIndex) ?? text.endIndex
            }
            return newStart ..< range.upperBound
        }
        return range
    }

    private func verifyMoveFunction(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        guard
            let path = task.selectFiles.first,
            let baseText = baseline[path],
            let finalText = final[path]
        else {
            // This guard is preserved for anchoring; actual validation happens below.
            return .failure(reason: "missingParams")
        }

        // Multi-move path: params["moves"] contains an array of { from, after }
        if let moves = task.params["moves"]?.arrayValue, !moves.isEmpty {
            // Collect function names to remove for outside comparison
            let moveNames: [String] = moves.compactMap { entry in
                entry.objectValue?["from"]?.stringValue
            }

            func textByRemovingFunctions(_ text: String, names: [String], language: BenchmarkLanguage) -> String {
                var out = text
                for name in names {
                    if let r = findFunctionRange(in: out, name: name, language: language) {
                        let extended = extendRangeToIncludeLeadingComments(in: out, range: r, language: language)
                        out = textByRemovingRange(out, range: extended)
                    }
                }
                // Normalize excessive newlines to be robust to whitespace shifts
                return out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            }

            let sanitizedBase = textByRemovingFunctions(baseText, names: moveNames, language: task.language)
            let sanitizedFinal = textByRemovingFunctions(finalText, names: moveNames, language: task.language)
            let outsideUnchangedGlobal = normalizeForOutsideComparison(sanitizedBase) == normalizeForOutsideComparison(sanitizedFinal)

            var totalScore = 0.0
            var detailReasons: [String] = []
            var anyContentChanged = false

            for entry in moves {
                guard
                    let obj = entry.objectValue,
                    let from = obj["from"]?.stringValue,
                    let after = obj["after"]?.stringValue
                else {
                    // If malformed move entry, score 0 for this one
                    detailReasons.append("malformedMove")
                    continue
                }

                let baseFromRangeRaw = findFunctionRange(in: baseText, name: from, language: task.language)
                let finalFromRangeRaw = findFunctionRange(in: finalText, name: from, language: task.language)
                let finalAfterRange = findFunctionRange(in: finalText, name: after, language: task.language)

                let baseFromRange = baseFromRangeRaw.map { extendRangeToIncludeLeadingComments(in: baseText, range: $0, language: task.language) }
                let finalFromRange = finalFromRangeRaw.map { extendRangeToIncludeLeadingComments(in: finalText, range: $0, language: task.language) }

                let placedAfter: Bool = {
                    guard let fFromRaw = finalFromRangeRaw, let fAfter = finalAfterRange else { return false }
                    return fFromRaw.lowerBound >= fAfter.upperBound
                }()

                let sameFunctionContent: Bool = {
                    guard let bFrom = baseFromRange, let fFrom = finalFromRange else { return false }
                    return String(baseText[bFrom]) == String(finalText[fFrom])
                }()

                let outsideUnchanged = outsideUnchangedGlobal

                var score = 0.0
                if placedAfter {
                    score += 0.5
                }
                if outsideUnchanged {
                    score += 0.3
                }
                if sameFunctionContent {
                    score += 0.2
                }
                totalScore += score

                if !placedAfter {
                    detailReasons.append("\(from):notAfterTarget")
                }
                if !outsideUnchanged {
                    detailReasons.append("\(from):collateralChange")
                }
                if !sameFunctionContent {
                    detailReasons.append("\(from):functionChanged")
                    anyContentChanged = true
                }
            }

            // Enforce exact content retention for TS/Swift
            if task.language != .go, anyContentChanged {
                return .failure(reason: "functionChanged", metrics: [
                    "moveCount": .integer(moves.count)
                ])
            }

            let movesCount = max(1, moves.count)
            let avgScore = totalScore / Double(movesCount)
            let reason = detailReasons.joined(separator: ",")

            return makeScoredOutput(score: avgScore, reason: reason, metrics: [
                "moveCount": .integer(movesCount),
                "averageScore": .double(avgScore)
            ])
        }

        // Single-move path (backward compatible)
        guard
            let from = task.params["fromName"]?.stringValue,
            let after = task.params["afterName"]?.stringValue
        else {
            return .failure(reason: "missingParams")
        }

        let baseFromRange0 = findFunctionRange(in: baseText, name: from, language: task.language)
        let baseAfterRange = findFunctionRange(in: baseText, name: after, language: task.language)

        if baseFromRange0 == nil, baseAfterRange == nil {
            return .failure(reason: "functionNotFoundBaseline(missing:\(from),\(after))")
        } else if baseFromRange0 == nil {
            return .failure(reason: "functionNotFoundBaseline(missing:\(from))")
        } else if baseAfterRange == nil {
            return .failure(reason: "functionNotFoundBaseline(missing:\(after))")
        }

        guard let baseFromRangeRaw = baseFromRange0 else {
            return .failure(reason: "functionNotFoundBaseline(missing:\(from))")
        }

        // Extend ranges to include leading documentation/comments for robust equality check
        let baseFromRange = extendRangeToIncludeLeadingComments(in: baseText, range: baseFromRangeRaw, language: task.language)
        guard
            let finalFromRangeRaw = findFunctionRange(in: finalText, name: from, language: task.language),
            let finalAfterRange = findFunctionRange(in: finalText, name: after, language: task.language)
        else {
            return .failure(reason: "functionNotFoundFinal")
        }
        let finalFromRange = extendRangeToIncludeLeadingComments(in: finalText, range: finalFromRangeRaw, language: task.language)

        let baseFromBody = String(baseText[baseFromRange])
        let finalFromBody = String(finalText[finalFromRange])

        let baseWithoutFrom = textByRemovingRange(baseText, range: baseFromRange)
        let finalWithoutFrom = textByRemovingRange(finalText, range: finalFromRange)

        // Remove double-normalization; use move-specific normalization tolerant to blank-line runs
        let outsideUnchanged = normalizeForMoveComparison(baseWithoutFrom) == normalizeForMoveComparison(finalWithoutFrom)
        // Use raw header start for placement check (avoid bias from extended doc-range)
        let fromHeaderStart = finalFromRangeRaw.lowerBound
        let placedAfter = fromHeaderStart >= finalAfterRange.upperBound
        // Compare function content with move-specific normalization to tolerate whitespace-only variations
        let sameFunctionContent = normalizeForMoveComparison(baseFromBody) == normalizeForMoveComparison(finalFromBody)

        // Enforce exact content retention for TS/Swift
        if task.language != .go, !sameFunctionContent {
            return .failure(reason: "functionChanged", metrics: [
                "placedAfter": .boolean(placedAfter),
                "outsideUnchanged": .boolean(outsideUnchanged)
            ])
        }

        var score = 0.0
        if placedAfter {
            score += 0.5
        }
        if outsideUnchanged {
            score += 0.3
        }
        if sameFunctionContent {
            score += 0.2
        }

        let reason: String = {
            if !placedAfter {
                return "notAfterTarget"
            }
            if !outsideUnchanged {
                return "collateralChange"
            }
            if !sameFunctionContent {
                return "functionChanged"
            }
            return ""
        }()

        return makeScoredOutput(score: score, reason: reason, metrics: [
            "placedAfter": .boolean(placedAfter),
            "outsideUnchanged": .boolean(outsideUnchanged),
            "functionContentEqual": .boolean(sameFunctionContent)
        ])
    }

    // MARK: - insert_function_bottom_ts

    private func verifyInsertFunctionBottom(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        if let inserts = task.params["inserts"]?.arrayValue, !inserts.isEmpty {
            var components: [(String, BenchmarkVerifyOutput)] = []
            for entry in inserts {
                guard
                    let object = entry.objectValue,
                    let path = object["path"]?.stringValue,
                    let snippet = object["snippet"]?.stringValue
                else { continue }
                let footer = object["footer"]?.stringValue ?? task.params["footer"]?.stringValue ?? "// END-OF-FILE"
                let subTask = BenchmarkTaskSpec(
                    id: "\(task.id)::\(path)",
                    type: task.type,
                    language: task.language,
                    difficulty: task.difficulty,
                    format: task.format,
                    selectFiles: [path],
                    newChat: task.newChat,
                    maxEdits: max(1, task.maxEdits / max(inserts.count, 1)),
                    instructions: task.instructions,
                    task: task.task,
                    acceptance: task.acceptance,
                    params: [
                        "snippet": .string(snippet),
                        "footer": .string(footer)
                    ]
                )
                components.append((path, verifyInsertFunctionBottom(task: subTask, baseline: baseline, final: final)))
            }
            return aggregate(components, label: "insertFunctionBottomBundle")
        }
        guard
            let path = task.selectFiles.first,
            let baseText = baseline[path],
            let finalText = final[path],
            let snippet = task.params["snippet"]?.stringValue
        else {
            return .failure(reason: "missingParams")
        }
        let footer = task.params["footer"]?.stringValue ?? "// END-OF-FILE"
        guard let footerRange = finalText.range(of: footer) else {
            return .failure(reason: "footerMissing")
        }

        // Try exact snippet match first
        let exactRange = finalText.range(of: snippet)

        // If not exact, try normalized
        let normalizedSnippetFound: Bool
        if exactRange == nil {
            let nf = normalizeForSnippetSearch(finalText)
            let ns = normalizeForSnippetSearch(snippet)
            normalizedSnippetFound = nf.range(of: ns) != nil
            if !normalizedSnippetFound {
                return .failure(reason: "snippetMissing", metrics: [
                    "snippetExactFound": .boolean(false),
                    "snippetNormalizedFound": .boolean(false),
                    "footerString": .string(footer)
                ])
            }
        } else {
            normalizedSnippetFound = true
        }

        // Check placement above footer
        let placedAboveFooter: Bool
        if let r = exactRange {
            placedAboveFooter = r.upperBound <= footerRange.lowerBound
        } else {
            let finalBeforeFooter = String(finalText[..<footerRange.lowerBound])
            placedAboveFooter = normalizeForSnippetSearch(finalBeforeFooter)
                .range(of: normalizeForSnippetSearch(snippet)) != nil
        }

        // Check outside unchanged - use normalizeForOutsideComparison for robust whitespace handling
        let outsideUnchanged: Bool
        if exactRange != nil {
            let finalWithoutSnippet = finalText.replacingOccurrences(of: snippet, with: "")
            let normalizedFinal = normalizeForOutsideComparison(finalWithoutSnippet)
            let normalizedBase = normalizeForOutsideComparison(baseText)
            outsideUnchanged = normalizedFinal == normalizedBase
        } else {
            let nf = normalizeForSnippetSearch(finalText)
            let ns = normalizeForSnippetSearch(snippet)
            let sanitizedFinal = normalizeForOutsideComparison(nf.replacingOccurrences(of: ns, with: ""))
            let sanitizedBase = normalizeForOutsideComparison(normalizeForSnippetSearch(baseText))
            outsideUnchanged = sanitizedFinal == sanitizedBase
        }

        var score = 0.0
        if placedAboveFooter {
            score += 0.6
        }
        if outsideUnchanged {
            score += 0.4
        }

        let reason: String = {
            if !placedAboveFooter {
                return "wrongPlacement"
            }
            if !outsideUnchanged {
                return "collateralChange"
            }
            return ""
        }()

        return makeScoredOutput(score: score, reason: reason, metrics: [
            "placedAboveFooter": .boolean(placedAboveFooter),
            "outsideUnchanged": .boolean(outsideUnchanged),
            "snippetExactFound": .boolean(exactRange != nil),
            "snippetNormalizedFound": .boolean(true),
            "footerString": .string(footer)
        ])
    }

    // MARK: - apply_unified_patch_ts

    private func verifyApplyUnifiedPatch(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        let discovery = task.params["targetDiscovery"]?.boolValue == true

        if discovery {
            // Target discovery mode: find which candidate matches the patch
            guard let patch = task.params["patch"]?.stringValue else {
                return .failure(reason: "missingParams")
            }

            // Load candidates
            let candidatesParam = task.params["candidatePaths"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let candidates = candidatesParam.isEmpty ? task.selectFiles : candidatesParam

            var matched: String?
            var bestCoverage: (path: String, applied: Int, total: Int) = ("", 0, 0)

            // Try to find exact match among candidates
            for path in candidates {
                guard let baseText = baseline[path], let finalText = final[path] else { continue }
                if let expected = SimpleUnifiedPatchApplier.apply(patch: patch, to: baseText), expected == finalText {
                    matched = path
                    break
                }
                // Compute coverage for partial credit reporting
                let (applied, total) = UnifiedPatchGrader.coverage(baseline: baseText, final: finalText, patch: patch)
                if applied > bestCoverage.applied {
                    bestCoverage = (path, applied, total)
                }
            }

            guard let matchedPath = matched else {
                return BenchmarkVerifyOutput(
                    pass: false,
                    score: bestCoverage.total > 0 ? Double(bestCoverage.applied) / Double(bestCoverage.total) : 0.0,
                    reason: "diffMismatch",
                    metrics: [
                        "bestCandidatePath": .string(bestCoverage.path),
                        "hunksApplied": .integer(bestCoverage.applied),
                        "hunksTotal": .integer(bestCoverage.total)
                    ]
                )
            }

            // Enforce "only this file changed" among candidates
            var othersUnchanged = true
            for path in candidates where path != matchedPath {
                if let b = baseline[path], let f = final[path], b != f {
                    othersUnchanged = false
                    break
                }
            }
            if !othersUnchanged {
                return .failure(reason: "othersChanged", metrics: ["path": .string(matchedPath)])
            }

            // Indentation style check using matched final
            let finalText = final[matchedPath]!
            let usesTabIndentation = task.language.usesTabIndentation
            let hasTab = finalText.contains("\t")
            let hasFourSpaces = finalText.contains("    ")
            if usesTabIndentation {
                if hasFourSpaces {
                    return .failure(reason: "wrongIndentationStyle", metrics: [
                        "expectedIndent": .string("tabs"),
                        "hasTabs": .boolean(hasTab),
                        "hasFourSpaces": .boolean(hasFourSpaces)
                    ])
                }
            } else {
                if hasTab {
                    return .failure(reason: "tabFound", metrics: [
                        "expectedIndent": .string("spaces"),
                        "hasTabs": .boolean(hasTab),
                        "hasFourSpaces": .boolean(hasFourSpaces)
                    ])
                }
            }

            // Exact success
            return makeScoredOutput(score: 1.0, reason: "", metrics: [
                "appliedOK": .boolean(true),
                "matchedPath": .string(matchedPath),
                "candidates": .integer(candidates.count)
            ])
        }

        // Non-discovery mode (existing behavior)
        guard
            let path = task.selectFiles.first,
            let baseText = baseline[path],
            let finalText = final[path],
            let patch = task.params["patch"]?.stringValue
        else {
            return .failure(reason: "missingParams")
        }
        guard let expected = SimpleUnifiedPatchApplier.apply(patch: patch, to: baseText) else {
            return .failure(reason: "invalidPatch")
        }

        // Check indentation style matches language preference
        let usesTabIndentation = task.language.usesTabIndentation
        let hasTab = finalText.contains("\t")
        let hasFourSpaces = finalText.contains("    ")
        if usesTabIndentation {
            // Swift should use tabs - reject if we have spaces being used for indentation
            if hasFourSpaces {
                return .failure(reason: "wrongIndentationStyle", metrics: [
                    "expectedIndent": .string("tabs"),
                    "hasTabs": .boolean(hasTab),
                    "hasFourSpaces": .boolean(hasFourSpaces)
                ])
            }
        } else {
            // TS/Go should use spaces - reject if we have tabs
            if hasTab {
                return .failure(reason: "tabFound", metrics: [
                    "expectedIndent": .string("spaces"),
                    "hasTabs": .boolean(hasTab),
                    "hasFourSpaces": .boolean(hasFourSpaces)
                ])
            }
        }

        let match = expected == finalText
        if match {
            return makeScoredOutput(score: 1.0, reason: "", metrics: [
                "appliedOK": .boolean(true)
            ])
        }

        // Exact match failed - compute partial credit based on hunk coverage for analytics
        let (appliedHunks, totalHunks) = UnifiedPatchGrader.coverage(baseline: baseText, final: finalText, patch: patch)
        let normalizedScore = totalHunks > 0 ? Double(appliedHunks) / Double(totalHunks) : 0.0

        // Enforce exact application: pass=false on mismatch, preserve score for reporting
        return BenchmarkVerifyOutput(pass: false, score: normalizedScore, reason: "diffMismatch", metrics: [
            "appliedOK": .boolean(false),
            "hunksTotal": .integer(totalHunks),
            "hunksApplied": .integer(appliedHunks)
        ])
    }

    // MARK: - insert_guard_ts

    private func verifyInsertGuardMarkerless(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        guard
            let path = task.selectFiles.first,
            let finalText = final[path],
            let baselineText = baseline[path],
            let functionName = task.params["functionName"]?.stringValue,
            let snippet = task.params["snippet"]?.stringValue,
            let insertAfterPattern = task.params["insertAfterPattern"]?.stringValue
        else {
            return BenchmarkVerifyOutput.failure(reason: "missingParams")
        }

        // Locate function in baseline and final
        guard let baselineRange = findFunctionRange(in: baselineText, name: functionName, language: task.language),
              let finalRange = findFunctionRange(in: finalText, name: functionName, language: task.language)
        else {
            return BenchmarkVerifyOutput.failure(reason: "functionNotFoundFinal")
        }

        let finalBody = String(finalText[finalRange])

        // Check that snippet appears in final function body
        let snippetFound = containsGuardSnippet(in: finalBody, language: task.language, expected: snippet)

        // Check that snippet appears after the insertAfterPattern
        var afterPatternOk = false
        if let patternRange = finalBody.range(of: insertAfterPattern) {
            let afterPattern = String(finalBody[patternRange.upperBound...])
            afterPatternOk = containsGuardSnippet(in: afterPattern, language: task.language, expected: snippet)
        }

        // Check outside the function is unchanged
        let baselineOutside = textByRemovingRange(baselineText, range: baselineRange)
        let finalOutside = textByRemovingRange(finalText, range: finalRange)
        let unchangedOutside = normalizeForMoveComparison(baselineOutside) == normalizeForMoveComparison(finalOutside)

        // Check indentation style (leading whitespace on non-empty lines only)
        let usesTabIndentation = task.language.usesTabIndentation

        func hasLeadingIndentation(_ text: String, checkTabs: Bool) -> Bool {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    continue
                }
                // Get leading whitespace
                var leading = ""
                for ch in line {
                    if ch == " " || ch == "\t" {
                        leading.append(ch)
                    } else {
                        break
                    }
                }
                if checkTabs, leading.contains("\t") {
                    return true
                }
                if !checkTabs, leading.contains("    ") {
                    return true
                }
            }
            return false
        }

        let hasTabIndent = hasLeadingIndentation(snippet, checkTabs: true) || hasLeadingIndentation(finalBody, checkTabs: true)
        let hasFourSpaceIndent = hasLeadingIndentation(snippet, checkTabs: false) || hasLeadingIndentation(finalBody, checkTabs: false)

        if usesTabIndentation {
            if hasFourSpaceIndent, !hasTabIndent {
                return BenchmarkVerifyOutput.failure(reason: "wrongIndentationStyle", metrics: [
                    "expectedIndent": .string("tabs"),
                    "hasTabs": .boolean(hasTabIndent),
                    "hasFourSpaces": .boolean(hasFourSpaceIndent)
                ])
            }
        } else {
            if hasTabIndent {
                return BenchmarkVerifyOutput.failure(reason: "tabFound", metrics: [
                    "expectedIndent": .string("spaces"),
                    "hasTabs": .boolean(hasTabIndent),
                    "hasFourSpaces": .boolean(hasFourSpaceIndent)
                ])
            }
        }

        var score = 0.0
        if snippetFound {
            score += 0.5
        }
        if afterPatternOk {
            score += 0.3
        }
        if unchangedOutside {
            score += 0.2
        }

        let reason = if !snippetFound {
            "snippetMissing"
        } else if !afterPatternOk {
            "snippetNotAfterPattern"
        } else if !unchangedOutside {
            "collateralDamage"
        } else {
            ""
        }

        let metrics: [String: BenchmarkJSONValue] = [
            "snippetFound": .boolean(snippetFound),
            "afterPatternOk": .boolean(afterPatternOk),
            "unchangedOutside": .boolean(unchangedOutside)
        ]

        return makeScoredOutput(score: score, reason: reason, metrics: metrics)
    }

    private func verifyInsertGuard(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        // Check for markerless mode
        if task.params["markerless"]?.boolValue == true {
            return verifyInsertGuardMarkerless(task: task, baseline: baseline, final: final)
        }

        if let guards = task.params["guards"]?.arrayValue, !guards.isEmpty {
            var components: [(String, BenchmarkVerifyOutput)] = []
            for entry in guards {
                guard
                    let object = entry.objectValue,
                    let path = object["path"]?.stringValue,
                    let uid = object["uid"]?.stringValue,
                    let snippet = object["snippet"]?.stringValue
                else { continue }
                let subTask = BenchmarkTaskSpec(
                    id: "\(task.id)::\(path)",
                    type: task.type,
                    language: task.language,
                    difficulty: task.difficulty,
                    format: task.format,
                    selectFiles: [path],
                    newChat: task.newChat,
                    maxEdits: max(1, task.maxEdits / max(guards.count, 1)),
                    instructions: task.instructions,
                    task: task.task,
                    acceptance: task.acceptance,
                    params: [
                        "uid": .string(uid),
                        "snippet": .string(snippet),
                        "markerless": .boolean(false)
                    ]
                )
                components.append((path, verifyInsertGuard(task: subTask, baseline: baseline, final: final)))
            }
            return aggregate(components, label: "insertGuardBundle")
        }
        guard let uid = task.params["uid"]?.stringValue,
              let snippet = task.params["snippet"]?.stringValue,
              let path = task.selectFiles.first,
              let finalText = final[path],
              let baselineText = baseline[path]
        else {
            return BenchmarkVerifyOutput.failure(reason: "missingParams")
        }
        let startToken = "// ANCHOR:start:\(uid)"
        let endToken = "// ANCHOR:end:\(uid)"
        guard let finalStart = finalText.range(of: startToken),
              let finalEnd = finalText.range(of: endToken, range: finalStart.upperBound ..< finalText.endIndex),
              let baselineStart = baselineText.range(of: startToken),
              let baselineEnd = baselineText.range(of: endToken, range: baselineStart.upperBound ..< baselineText.endIndex)
        else {
            return BenchmarkVerifyOutput.failure(reason: "anchorsMissing")
        }
        // Check indentation style matches language preference
        let usesTabIndentation = task.language.usesTabIndentation
        let finalSegmentRaw = String(finalText[finalStart.upperBound ..< finalEnd.lowerBound])
        let hasTab = snippet.contains("\t") || finalSegmentRaw.contains("\t")
        let hasFourSpaces = snippet.contains("    ") || finalSegmentRaw.contains("    ")
        if usesTabIndentation {
            // Swift should use tabs - reject if we have spaces being used for indentation
            // We check for multiple spaces that look like indentation
            if hasFourSpaces {
                return BenchmarkVerifyOutput.failure(reason: "wrongIndentationStyle", metrics: [
                    "expectedIndent": .string("tabs"),
                    "hasTabs": .boolean(hasTab),
                    "hasFourSpaces": .boolean(hasFourSpaces)
                ])
            }
        } else {
            // TS/Go should use spaces - reject if we have tabs
            if hasTab {
                return BenchmarkVerifyOutput.failure(reason: "tabFound", metrics: [
                    "expectedIndent": .string("spaces"),
                    "hasTabs": .boolean(hasTab),
                    "hasFourSpaces": .boolean(hasFourSpaces)
                ])
            }
        }
        let finalSegment = finalSegmentRaw
        let baselineSegment = String(baselineText[baselineStart.upperBound ..< baselineEnd.lowerBound])
        func replaceAnchorBody(_ text: String, uid: String, with body: String) -> String {
            let startToken = "// ANCHOR:start:\(uid)"
            let endToken = "// ANCHOR:end:\(uid)"
            guard let start = text.range(of: startToken),
                  let end = text.range(of: endToken, range: start.upperBound ..< text.endIndex)
            else {
                return text
            }
            var copy = text
            copy.replaceSubrange(start.upperBound ..< end.lowerBound, with: body)
            return copy
        }
        if replaceAnchorBody(finalText, uid: uid, with: baselineSegment) != baselineText {
            return BenchmarkVerifyOutput.failure(reason: "collateralDamage")
        }
        func leadingIndentation(of line: Substring) -> String {
            var indent = ""
            for character in line {
                if character == " " || character == "\t" {
                    indent.append(character)
                } else {
                    break
                }
            }
            return indent
        }
        func indentationSample(in segment: String) -> String? {
            let lines = segment.split(separator: "\n", omittingEmptySubsequences: false)
            guard let sample = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                return nil
            }
            return leadingIndentation(of: sample)
        }
        func indentSnippet(_ value: String, with indent: String) -> String {
            guard !indent.isEmpty else { return value }
            let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.map { indent + String($0) }.joined(separator: "\n")
        }
        var snippetCandidates: [String] = [snippet]
        let baselineIndent = indentationSample(in: baselineSegment)
        let finalIndent = indentationSample(in: finalSegment)
        let indentOptions = [baselineIndent, finalIndent].compactMap(\.self).filter { !$0.isEmpty }
        for indent in indentOptions {
            let candidate = indentSnippet(snippet, with: indent)
            if !snippetCandidates.contains(candidate) {
                snippetCandidates.append(candidate)
            }
        }
        let matchedSnippet = snippetCandidates.first(where: { finalSegment.contains($0) })
        // Updated snippetFound logic to be tolerant of formatting variations
        let snippetFound = containsGuardSnippet(in: finalSegment, language: task.language, expected: snippet)
        let withoutSnippet: String = if let used = matchedSnippet {
            finalSegment.replacingOccurrences(of: used, with: "")
        } else {
            finalSegment
        }
        let unchangedOutside = withoutSnippet.trimmingCharacters(in: .whitespacesAndNewlines) == baselineSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        let anyGuard = finalSegment.contains("if (") && finalSegment.contains("return ")
        var score = 0.0
        if snippetFound {
            score += 0.7
        }
        if unchangedOutside {
            score += 0.3
        }
        if !snippetFound, anyGuard, policy.lenient {
            score = max(score, 0.3)
        }
        let reason: String = if snippetFound {
            unchangedOutside ? "" : "collateralChangeInsideAnchors"
        } else {
            "snippetMismatch"
        }
        let metrics: [String: BenchmarkJSONValue] = [
            "snippetFound": .boolean(snippetFound),
            "unchangedOutside": .boolean(unchangedOutside)
        ]
        return makeScoredOutput(score: score, reason: reason, metrics: metrics)
    }

    // MARK: - patch_block_ts

    private func verifyPatchBlockMarkerless(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        guard
            let path = task.selectFiles.first,
            let finalText = final[path],
            let baselineText = baseline[path],
            let functionName = task.params["functionName"]?.stringValue,
            let snippet = task.params["snippet"]?.stringValue
        else {
            return BenchmarkVerifyOutput.failure(reason: "missingParams")
        }

        // Locate function in baseline and final
        guard let baselineRange = findFunctionRange(in: baselineText, name: functionName, language: task.language),
              let finalRange = findFunctionRange(in: finalText, name: functionName, language: task.language)
        else {
            return BenchmarkVerifyOutput.failure(reason: "functionNotFoundFinal")
        }

        let finalBody = String(finalText[finalRange])

        // Check indentation style (leading whitespace on non-empty lines only)
        let usesTabIndentation = task.language.usesTabIndentation

        func hasLeadingIndentation(_ text: String, checkTabs: Bool) -> Bool {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    continue
                }
                // Get leading whitespace
                var leading = ""
                for ch in line {
                    if ch == " " || ch == "\t" {
                        leading.append(ch)
                    } else {
                        break
                    }
                }
                if checkTabs, leading.contains("\t") {
                    return true
                }
                if !checkTabs, leading.contains("    ") {
                    return true
                }
            }
            return false
        }

        let hasTabIndent = hasLeadingIndentation(snippet, checkTabs: true) || hasLeadingIndentation(finalBody, checkTabs: true)
        let hasFourSpaceIndent = hasLeadingIndentation(snippet, checkTabs: false) || hasLeadingIndentation(finalBody, checkTabs: false)

        if usesTabIndentation {
            if hasFourSpaceIndent, !hasTabIndent {
                return BenchmarkVerifyOutput.failure(reason: "wrongIndentationStyle", metrics: [
                    "expectedIndent": .string("tabs"),
                    "hasTabs": .boolean(hasTabIndent),
                    "hasFourSpaces": .boolean(hasFourSpaceIndent)
                ])
            }
        } else {
            if hasTabIndent {
                return BenchmarkVerifyOutput.failure(reason: "tabFound", metrics: [
                    "expectedIndent": .string("spaces"),
                    "hasTabs": .boolean(hasTabIndent),
                    "hasFourSpaces": .boolean(hasFourSpaceIndent)
                ])
            }
        }

        // Check if function body equals snippet (after normalization)
        let finalBodyNormalized = finalBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippetNormalized = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyMatches = finalBodyNormalized == snippetNormalized

        // Check outside the function is unchanged
        let baselineOutside = textByRemovingRange(baselineText, range: baselineRange)
        let finalOutside = textByRemovingRange(finalText, range: finalRange)
        let unchangedOutside = normalizeForOutsideComparison(baselineOutside) == normalizeForOutsideComparison(finalOutside)

        if bodyMatches, unchangedOutside {
            return BenchmarkVerifyOutput.success()
        }

        // Compute partial score for reporting
        let signatureOK = finalBody.contains("\(functionName)(") && snippet.contains("\(functionName)(")
        let similarity = jaccard(tokens(finalBodyNormalized), tokens(snippetNormalized))
        var score = 0.0
        if signatureOK {
            score += 0.4
        }
        if unchangedOutside {
            score += 0.2
        }
        score += 0.4 * similarity
        let clamped = clampScore(score)

        let reason = if !bodyMatches {
            "blockMismatch"
        } else if !unchangedOutside {
            "collateralDamage"
        } else {
            ""
        }

        let metrics: [String: BenchmarkJSONValue] = [
            "signatureOk": .boolean(signatureOK),
            "tokenSimilarity": .double(similarity),
            "unchangedOutside": .boolean(unchangedOutside)
        ]

        return makeScoredOutput(score: clamped, reason: reason, metrics: metrics)
    }

    private func verifyPatchBlock(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        // Check for markerless mode
        if task.params["markerless"]?.boolValue == true {
            return verifyPatchBlockMarkerless(task: task, baseline: baseline, final: final)
        }

        if let blocks = task.params["blocks"]?.arrayValue, !blocks.isEmpty {
            var components: [(String, BenchmarkVerifyOutput)] = []
            for entry in blocks {
                guard
                    let object = entry.objectValue,
                    let path = object["path"]?.stringValue,
                    let uid = object["uid"]?.stringValue,
                    let snippet = object["snippet"]?.stringValue
                else { continue }
                let subTask = BenchmarkTaskSpec(
                    id: "\(task.id)::\(path)",
                    type: task.type,
                    language: task.language,
                    difficulty: task.difficulty,
                    format: task.format,
                    selectFiles: [path],
                    newChat: task.newChat,
                    maxEdits: max(2, task.maxEdits / max(blocks.count, 1)),
                    instructions: task.instructions,
                    task: task.task,
                    acceptance: task.acceptance,
                    params: [
                        "uid": .string(uid),
                        "snippet": .string(snippet)
                    ]
                )
                components.append((path, verifyPatchBlock(task: subTask, baseline: baseline, final: final)))
            }
            return aggregate(components, label: "patchBlockBundle")
        }
        guard let uid = task.params["uid"]?.stringValue,
              let snippet = task.params["snippet"]?.stringValue,
              let path = task.selectFiles.first,
              let finalText = final[path],
              let baselineText = baseline[path]
        else {
            return BenchmarkVerifyOutput.failure(reason: "missingParams")
        }
        let startToken = "/* BLOCK START:\(uid) */"
        let endToken = "/* BLOCK END:\(uid) */"
        guard let start = finalText.range(of: startToken),
              let end = finalText.range(of: endToken, range: start.upperBound ..< finalText.endIndex)
        else {
            return BenchmarkVerifyOutput.failure(reason: "blockAnchorsMissing")
        }

        // Extract block content WITHOUT trimming to preserve indentation
        let blockRaw = String(finalText[start.upperBound ..< end.lowerBound])

        // Check indentation style matches language preference
        let usesTabIndentation = task.language.usesTabIndentation
        let hasTab = blockRaw.contains("\t")
        let hasFourSpaces = blockRaw.contains("    ")
        if usesTabIndentation {
            // Swift should use tabs - reject if we have spaces being used for indentation
            // Check for multiple spaces that look like indentation
            if hasFourSpaces {
                return BenchmarkVerifyOutput.failure(reason: "wrongIndentationStyle", metrics: [
                    "expectedIndent": .string("tabs"),
                    "hasTabs": .boolean(hasTab),
                    "hasFourSpaces": .boolean(hasFourSpaces)
                ])
            }
        } else {
            // TS/Go should use spaces - reject if we have tabs
            if hasTab {
                return BenchmarkVerifyOutput.failure(reason: "tabFound", metrics: [
                    "expectedIndent": .string("spaces"),
                    "hasTabs": .boolean(hasTab),
                    "hasFourSpaces": .boolean(hasFourSpaces)
                ])
            }
        }

        // Normalize: trim outer whitespace only (newlines at start/end of block)
        let block = blockRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = snippet.trimmingCharacters(in: .whitespacesAndNewlines)

        let sanitizedFinal = replaceBlock(finalText, uid: uid, with: "")
        let sanitizedBaseline = replaceBlock(baselineText, uid: uid, with: "")
        // Use normalization to avoid false negatives on whitespace-only differences outside the block
        if normalizeForOutsideComparison(sanitizedBaseline) != normalizeForOutsideComparison(sanitizedFinal) {
            return BenchmarkVerifyOutput.failure(reason: "collateralDamage")
        }
        if block == target {
            return BenchmarkVerifyOutput.success()
        }
        // Exactness required for patch_block - compute partial score for reporting only
        let signatureOK = block.contains("block2(") && target.contains("block2(")
        let similarity = jaccard(tokens(block), tokens(target))
        var score = 0.0
        if signatureOK {
            score += 0.4
        }
        score += 0.6 * similarity
        let clamped = clampScore(score)

        let metrics: [String: BenchmarkJSONValue] = [
            "signatureOk": .boolean(signatureOK),
            "tokenSimilarity": .double(similarity)
        ]
        // Enforce exact match: pass=false on mismatch, but preserve score for analytics
        return BenchmarkVerifyOutput(pass: false, score: clamped, reason: "blockMismatch", metrics: metrics)
    }

    private func replaceBlock(_ text: String, uid: String, with replacement: String) -> String {
        let startToken = "/* BLOCK START:\(uid) */"
        let endToken = "/* BLOCK END:\(uid) */"
        guard let start = text.range(of: startToken),
              let end = text.range(of: endToken, range: start.upperBound ..< text.endIndex)
        else { return text }
        var modified = text
        modified.replaceSubrange(start.upperBound ..< end.lowerBound, with: replacement)
        return modified
    }

    private func normalizeForOutsideComparison(_ text: String) -> String {
        var result = text
        // Normalize line endings
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        // Trim trailing spaces from each line
        result = result.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // Collapse 3+ consecutive newlines to 2
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    private func sanitizeForCurlyComparison(_ text: String) -> String {
        var result = text
        // Normalize line endings to \n
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        // Trim trailing whitespace from each line
        result = result.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // Collapse 3+ consecutive newlines to 2 to be robust
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        // Remove all closing braces
        result = result.replacingOccurrences(of: "}", with: "")
        return result
    }

    private func normalizeForSnippetSearch(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
        // Trim trailing spaces per line
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // Collapse 3+ newlines to 2
        while s.contains("\n\n\n") {
            s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        // Trim leading/trailing newlines
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokens(_ value: String) -> Set<String> {
        let pieces = value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(pieces.filter { !$0.isEmpty })
    }

    private func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        if lhs.isEmpty, rhs.isEmpty {
            return 1.0
        }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0.0 }
        return Double(intersection) / Double(union)
    }

    // MARK: - swap_args_in_region_ts

    private func verifySwapArgsMarkerless(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        guard
            let path = task.selectFiles.first,
            let finalText = final[path],
            let baselineText = baseline[path],
            let functionName = task.params["functionName"]?.stringValue
        else {
            return BenchmarkVerifyOutput.failure(reason: "missingParams")
        }

        let expectedSwaps = task.params["expectedSwaps"]?.intValue ?? 0

        // Locate function in baseline and final
        guard let baselineRange = findFunctionRange(in: baselineText, name: functionName, language: task.language),
              let finalRange = findFunctionRange(in: finalText, name: functionName, language: task.language)
        else {
            return BenchmarkVerifyOutput.failure(reason: "functionNotFoundFinal")
        }

        let baselineBody = String(baselineText[baselineRange])
        let finalBody = String(finalText[finalRange])

        // Extract use() pairs from the function bodies
        let baselinePairs = extractUsePairs(baselineBody)
        let finalPairs = extractUsePairs(finalBody)

        // For markerless mode, we check the largest contiguous region
        // For simplicity, we'll check all pairs within the function
        let total = max(expectedSwaps, baselinePairs.count)
        var correct = 0
        for (lhs, rhs) in baselinePairs {
            if finalPairs.contains(where: { $0.0 == rhs && $0.1 == lhs }) {
                correct += 1
            }
        }

        // Check outside the function is unchanged
        let baselineOutside = textByRemovingRange(baselineText, range: baselineRange)
        let finalOutside = textByRemovingRange(finalText, range: finalRange)
        let unchangedOutside = normalizeForOutsideComparison(baselineOutside) == normalizeForOutsideComparison(finalOutside)

        if !unchangedOutside {
            return BenchmarkVerifyOutput.failure(reason: "outsideChanged")
        }

        let score = total == 0 ? 1.0 : Double(correct) / Double(total)
        return makeScoredOutput(score: score, reason: "", metrics: [
            "swapsCorrect": .integer(correct),
            "swapsExpected": .integer(total),
            "unchangedOutside": .boolean(unchangedOutside)
        ])
    }

    private func verifySwapArgs(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        // Check for markerless mode
        if task.params["markerless"]?.boolValue == true {
            return verifySwapArgsMarkerless(task: task, baseline: baseline, final: final)
        }

        if let regions = task.params["regions"]?.arrayValue, !regions.isEmpty {
            var components: [(String, BenchmarkVerifyOutput)] = []
            for entry in regions {
                guard
                    let object = entry.objectValue,
                    let path = object["path"]?.stringValue,
                    let uid = object["uid"]?.stringValue
                else { continue }
                let expected = object["expectedSwaps"]?.intValue ?? 0
                let subTask = BenchmarkTaskSpec(
                    id: "\(task.id)::\(path)",
                    type: task.type,
                    language: task.language,
                    difficulty: task.difficulty,
                    format: task.format,
                    selectFiles: [path],
                    newChat: task.newChat,
                    maxEdits: max(1, expected),
                    instructions: task.instructions,
                    task: task.task,
                    acceptance: task.acceptance,
                    params: [
                        "uid": .string(uid),
                        "expectedSwaps": .integer(expected)
                    ]
                )
                components.append((path, verifySwapArgs(task: subTask, baseline: baseline, final: final)))
            }
            return aggregate(components, label: "swapArgsBundle")
        }
        guard let uid = task.params["uid"]?.stringValue,
              let expected = task.params["expectedSwaps"]?.intValue,
              let path = task.selectFiles.first,
              let baselineText = baseline[path],
              let finalText = final[path]
        else {
            return BenchmarkVerifyOutput.failure(reason: "missingParams")
        }
        let startToken = "/* START_SWAP:\(uid) */"
        let endToken = "/* END_SWAP:\(uid) */"
        guard let baseStart = baselineText.range(of: startToken),
              let baseEnd = baselineText.range(of: endToken, range: baseStart.upperBound ..< baselineText.endIndex),
              let finalStart = finalText.range(of: startToken),
              let finalEnd = finalText.range(of: endToken, range: finalStart.upperBound ..< finalText.endIndex)
        else {
            return BenchmarkVerifyOutput.failure(reason: "swapRegionMissing")
        }
        let baseRegion = String(baselineText[baseStart.upperBound ..< baseEnd.lowerBound])
        let finalRegion = String(finalText[finalStart.upperBound ..< finalEnd.lowerBound])
        let baselinePairs = extractUsePairs(baseRegion)
        let finalPairs = extractUsePairs(finalRegion)
        let total = max(expected, baselinePairs.count)
        var correct = 0
        for (lhs, rhs) in baselinePairs {
            if finalPairs.contains(where: { $0.0 == rhs && $0.1 == lhs }) {
                correct += 1
            }
        }
        let outsideBaseline = removeRegion(from: baselineText, start: baseStart, end: baseEnd)
        let outsideFinal = removeRegion(from: finalText, start: finalStart, end: finalEnd)
        if outsideBaseline != outsideFinal {
            return BenchmarkVerifyOutput.failure(reason: "outsideChanged")
        }
        let score = total == 0 ? 1.0 : Double(correct) / Double(total)
        return makeScoredOutput(score: score, reason: "", metrics: [
            "swapsCorrect": .integer(correct),
            "swapsExpected": .integer(total)
        ])
    }

    private func extractUsePairs(_ text: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        let pattern = "use\\(\\s*([^,]+)\\s*,\\s*([^\\)]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches where match.numberOfRanges >= 3 {
            let lhs = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            pairs.append((lhs, rhs))
        }
        return pairs
    }

    private func removeRegion(from text: String, start: Range<String.Index>, end: Range<String.Index>) -> String {
        var copy = text
        copy.removeSubrange(start.lowerBound ..< end.upperBound)
        return copy
    }

    // MARK: - index_only_apps_ts

    private func verifyIndexOnly(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        guard let target = task.params["target"]?.stringValue,
              let targetPath = task.selectFiles.first,
              let finalText = final[targetPath]
        else {
            return BenchmarkVerifyOutput.failure(reason: "missingTarget")
        }
        if let others = task.params["otherPaths"]?.arrayValue {
            for entry in others {
                guard let path = entry.stringValue,
                      let baselineText = baseline[path],
                      let finalText = final[path]
                else { continue }
                if baselineText != finalText {
                    return BenchmarkVerifyOutput.failure(reason: "othersChanged", metrics: ["path": .string(path)])
                }
            }
        }
        let signature: String
        let expectedReturn: String
        switch task.language {
        case .ts:
            signature = "export default function index()"
            expectedReturn = "return \"\(target)\";"
        case .go:
            signature = "func index() string"
            expectedReturn = "return \"\(target)\""
        case .swift:
            signature = "public func index() -> String"
            expectedReturn = "return \"\(target)\""
        }
        let bodyRange = functionBodyRange(finalText, signature: signature)
        let body = bodyRange.map { String(finalText[$0]) } ?? finalText
        let donePattern = #"//\s*DONE\s*:\s*"# + NSRegularExpression.escapedPattern(for: target)
        let doneInsideFunction: Bool = {
            guard let bodyRange else { return false }
            let regex = try? NSRegularExpression(pattern: donePattern, options: [.caseInsensitive])
            let range = NSRange(bodyRange, in: finalText)
            return regex?.firstMatch(in: finalText, options: [], range: range) != nil
        }()
        let hasAltMarker = body.contains(target) && body.contains("//")
        let returnExact = body.contains(expectedReturn)
        let returnContainsTarget = !returnExact && body.contains("return \"\(target)")
        var score = 0.0
        if doneInsideFunction {
            score += 0.6
        }
        if returnExact {
            score += 0.4
        } else if returnContainsTarget, policy.lenient {
            score += 0.15
        }
        if !doneInsideFunction, hasAltMarker, policy.lenient {
            score = max(score, 0.3)
        }
        let reason = if doneInsideFunction, returnExact {
            ""
        } else if !doneInsideFunction {
            "doneMarkerMissingOrOutsideFunction"
        } else {
            "returnChanged"
        }
        return makeScoredOutput(score: score, reason: reason, metrics: [
            "doneInsideFunction": .boolean(doneInsideFunction),
            "returnExact": .boolean(returnExact)
        ])
    }

    private func functionBodyRange(_ text: String, signature: String) -> Range<String.Index>? {
        guard let signatureRange = text.range(of: signature) else { return nil }
        var index = signatureRange.upperBound
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "{" else { return nil }
        var depth = 0
        var bodyStart: String.Index?
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                depth += 1
                if bodyStart == nil {
                    bodyStart = text.index(after: index)
                }
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    guard let start = bodyStart else { return nil }
                    return start ..< index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - rename_export_and_imports_ts

    private func verifyRename(task: BenchmarkTaskSpec, baseline: [String: String], final: [String: String]) -> BenchmarkVerifyOutput {
        guard let rename = task.params["rename"]?.objectValue,
              let fromName = rename["from"]?.stringValue,
              let toName = rename["to"]?.stringValue
        else {
            return BenchmarkVerifyOutput.failure(reason: "missingRenameParams")
        }
        guard let exporter = task.selectFiles.first,
              let exporterText = final[exporter],
              let exporterBaseline = baseline[exporter]
        else {
            return BenchmarkVerifyOutput.failure(reason: "missingExporter")
        }
        let nearTokens = task.params["nearMissTokens"]?.arrayValue?.compactMap(\.stringValue) ?? []
        func hasExportDecl(_ text: String, lang: BenchmarkLanguage, name: String) -> Bool {
            switch lang {
            case .ts:
                let expressions = [
                    "\\bexport\\s+function\\s+\(name)\\(",
                    "\\bexport\\s+const\\s+\(name)\\b",
                    "\\bexport\\s+class\\s+\(name)\\b"
                ]
                for raw in expressions {
                    let pattern = raw.replacingOccurrences(of: "(name)", with: NSRegularExpression.escapedPattern(for: name))
                    if text.range(of: pattern, options: [.regularExpression]) != nil {
                        return true
                    }
                }
                return false
            case .go:
                let pattern = "(?m)^\\s*func\\s+\(name)\\s*\\(".replacingOccurrences(of: "(name)", with: NSRegularExpression.escapedPattern(for: name))
                return text.range(of: pattern, options: [.regularExpression]) != nil
            case .swift:
                let expressions = [
                    "\\bpublic\\s+func\\s+\(name)\\s*\\(",
                    "\\bfunc\\s+\(name)\\s*\\("
                ]
                for raw in expressions {
                    let pattern = raw.replacingOccurrences(of: "(name)", with: NSRegularExpression.escapedPattern(for: name))
                    if text.range(of: pattern, options: [.regularExpression]) != nil {
                        return true
                    }
                }
                return false
            }
        }
        let exporterHasOldDecl = hasExportDecl(exporterText, lang: task.language, name: fromName)
        let exporterHasNewDecl = hasExportDecl(exporterText, lang: task.language, name: toName)
        if exporterHasOldDecl || !exporterHasNewDecl {
            return BenchmarkVerifyOutput.failure(reason: "exporterMismatch")
        }
        if let others = task.params["otherPaths"]?.arrayValue {
            for entry in others {
                guard let path = entry.stringValue,
                      let baselineText = baseline[path],
                      let finalText = final[path]
                else { continue }
                if baselineText != finalText {
                    return BenchmarkVerifyOutput.failure(reason: "othersChanged", metrics: ["path": .string(path)])
                }
            }
        }
        if let importPaths = task.params["importPaths"]?.arrayValue {
            for entry in importPaths {
                guard let path = entry.stringValue,
                      let content = final[path]
                else { continue }
                if content.contains(fromName), !content.contains(toName) {
                    return BenchmarkVerifyOutput.failure(reason: "importerMismatch", metrics: ["path": .string(path)])
                }
            }
        }
        if let reexports = task.params["reexportPaths"]?.arrayValue?.compactMap(\.stringValue), !reexports.isEmpty {
            let escapedOld = NSRegularExpression.escapedPattern(for: fromName)
            let escapedNew = NSRegularExpression.escapedPattern(for: toName)
            let exportOldPattern = "\\bexport\\s*\\{[^\\}]*\\b\(escapedOld)\\b"
            let exportNewPattern = "\\bexport\\s*\\{[^\\}]*\\b\(escapedNew)\\b"
            for path in reexports {
                guard let barrelFinal = final[path], let barrelBaseline = baseline[path] else { continue }
                let hasOld = barrelFinal.range(of: exportOldPattern, options: [.regularExpression]) != nil
                let hasNew = barrelFinal.range(of: exportNewPattern, options: [.regularExpression]) != nil
                if hasOld || !hasNew {
                    return BenchmarkVerifyOutput.failure(reason: "exporterMismatch", metrics: ["path": .string(path)])
                }
                if !nearTokens.isEmpty {
                    for token in nearTokens {
                        let baselineCount = countOccurrences(of: token, in: barrelBaseline)
                        let finalCount = countOccurrences(of: token, in: barrelFinal)
                        if baselineCount != finalCount {
                            return BenchmarkVerifyOutput.failure(reason: "nearMissChanged", metrics: [
                                "path": .string(path),
                                "token": .string(token)
                            ])
                        }
                    }
                }
            }
        }
        if !nearTokens.isEmpty {
            for token in nearTokens {
                let baselineCount = countOccurrences(of: token, in: exporterBaseline)
                let finalCount = countOccurrences(of: token, in: exporterText)
                if baselineCount != finalCount {
                    return BenchmarkVerifyOutput.failure(reason: "nearMissChanged", metrics: [
                        "token": .string(token),
                        "baseline": .integer(baselineCount),
                        "final": .integer(finalCount)
                    ])
                }
            }
        }
        return BenchmarkVerifyOutput.success()
    }

    private func stripTSComments(_ text: String) -> String {
        var result = text
        if let block = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/", options: []) {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = block.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        if let line = try? NSRegularExpression(pattern: "//.*", options: []) {
            let range = NSRange(location: 0, length: result.utf16.count)
            result = line.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result
    }

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private func makeScoredOutput(score: Double, reason: String, metrics: [String: BenchmarkJSONValue]) -> BenchmarkVerifyOutput {
        let clamped = clampScore(score)
        let pass = clamped >= policy.passThreshold
        return BenchmarkVerifyOutput(pass: pass, score: clamped, reason: reason, metrics: metrics)
    }

    private func aggregate(_ parts: [(String, BenchmarkVerifyOutput)], label: String) -> BenchmarkVerifyOutput {
        guard !parts.isEmpty else { return BenchmarkVerifyOutput.failure(reason: "\(label):empty") }
        let totalScore = parts.reduce(0.0) { $0 + $1.1.score }
        let average = totalScore / Double(parts.count)
        let clamped = clampScore(average)
        let allPass = parts.allSatisfy(\.1.pass)
        let failingReasons = parts.compactMap { $0.1.pass ? nil : "\($0.0):\($0.1.reason)" }
        let reason = failingReasons.joined(separator: ",")
        let metrics: [String: BenchmarkJSONValue] = [
            "components": .array(parts.map { component in
                .object([
                    "path": .string(component.0),
                    "score": .double(component.1.score),
                    "pass": .boolean(component.1.pass),
                    "reason": .string(component.1.reason)
                ])
            }),
            "averageScore": .double(average)
        ]
        let pass = allPass && clamped >= policy.passThreshold
        return BenchmarkVerifyOutput(pass: pass, score: clamped, reason: reason, metrics: metrics)
    }

    private func withFriendlyReason(_ output: BenchmarkVerifyOutput) -> BenchmarkVerifyOutput {
        let pretty = BenchmarkVerifier.humanReadableReason(output.reason)
        if pretty == output.reason {
            return output
        }
        return BenchmarkVerifyOutput(pass: output.pass, score: output.score, reason: pretty, metrics: output.metrics)
    }

    static func humanReadableReason(_ reason: String) -> String {
        if reason.isEmpty {
            return ""
        }
        let mapping: [String: String] = [
            "missingTargetFile": "Edited output did not include the required file.",
            "nearMissChanged": "Similar identifiers (such as call_x or CALL_XY) were changed—only remove CALL_X.",
            "missingParams": "Benchmark verifier was missing required parameters (configuration issue).",
            "functionNotFoundBaseline": "Baseline configuration is missing the referenced function (internal issue).",
            "functionNotFoundFinal": "The expected function was missing after your edits.",
            "footerMissing": "The `// END-OF-FILE` marker was removed or renamed.",
            "snippetMissing": "Required snippet was not found in the output.",
            "invalidPatch": "Unified diff could not be applied; please apply the provided patch exactly.",
            "anchorsMissing": "Anchor comments were missing—insert code between the provided anchors only.",
            "tabFound": "Inserted snippet contained a tab; use spaces for indentation.",
            "wrongIndentationStyle": "Inserted snippet uses the wrong indentation style for this language.",
            "blockAnchorsMissing": "Block markers were missing, so the snippet location could not be verified.",
            "collateralDamage": "Lines outside the targeted block changed unexpectedly.",
            "blockMismatch": "Block body does not match the required snippet.",
            "swapRegionMissing": "Swap region markers were missing after the edit.",
            "outsideChanged": "Code outside the swap region was modified.",
            "missingTarget": "Required target file was not present in the submission.",
            "othersChanged": "Files outside the allowed list were modified.",
            "missingRenameParams": "Rename parameters were missing (configuration issue).",
            "missingExporter": "Exporter file was missing in the output.",
            "exporterMismatch": "Exporter still references the old symbol name.",
            "importerMismatch": "One or more importers still reference the old symbol name.",
            "diffMismatch": "File contents did not match the expected diff result.",
            "braceUnbalanced": "Braces remain unbalanced after your changes.",
            "printCallInsideLoop": "Required print/log call still sits inside the loop.",
            "printCallCountMismatch": "Required print/log call was removed or duplicated.",
            "notAfterTarget": "The moved function was not placed after the requested target function.",
            "collateralChange": "Lines outside the moved function were modified.",
            "functionChanged": "The function body content changed unexpectedly.",
            "wrongPlacement": "Snippet was not inserted directly above the footer marker.",
            "insertGuardBundle:empty": "Verifier did not receive any guard files to inspect (configuration issue).",
            "patchBlockBundle:empty": "Verifier did not receive any block files to inspect (configuration issue).",
            "swapArgsBundle:empty": "Verifier did not receive any swap-region files to inspect (configuration issue).",
            "curlyFixBundle:empty": "Verifier did not receive any curly-fix files to inspect (configuration issue).",
            "insertFunctionBottomBundle:empty": "Verifier did not receive any bottom-insert files to inspect (configuration issue).",
            "TOO_MANY_EDITS": "Exceeded the allowed number of edits for this task.",
            "SEARCH_BLOCK_NOT_FOUND": "The search block could not be found in the file.",
            "EDIT_APPLY_FAILED": "Edit could not be applied to the file.",
            "UNEXPECTED_FILE_EDIT": "Modified a file that was not in the allowed list.",
            "PARSE_OUTPUT_FAILED": "Could not parse the model's output.",
            "MODEL_EXECUTION_FAILED": "Model execution failed.",
            "MODEL_OUTPUT_TOO_LARGE": "Model output exceeded the size limit.",
            "SEARCH_BLOCK_TOO_LARGE": "Search block exceeded maximum line limit - attempted to echo entire file."
        ]
        let parts = reason.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var friendly: [String] = []
        var messageToFiles: [String: [String]] = [:]

        for rawPart in parts {
            if let mapped = mapping[rawPart] {
                friendly.append(mapped)
                continue
            }
            if let colonIndex = rawPart.firstIndex(of: ":") {
                let prefix = String(rawPart[..<colonIndex])
                let suffix = String(rawPart[rawPart.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                if let fullMapped = mapping[rawPart] {
                    friendly.append(fullMapped)
                    continue
                }
                let message = mapping[suffix] ?? fallbackReasonMessage(for: suffix)

                // Check if prefix is a file path (contains / or .)
                if prefix.contains("/") {
                    // Extract just the filename from the path
                    let filename = prefix.split(separator: "/").last.map(String.init) ?? prefix
                    messageToFiles[message, default: []].append(filename)
                } else if prefix.contains("."), prefix.split(separator: ".").count > 1 {
                    // Likely a filename with extension but no path
                    messageToFiles[message, default: []].append(prefix)
                } else if let prefixMapped = mapping[prefix] {
                    friendly.append(prefixMapped)
                } else {
                    // It's a file key like "alpha", "bravo" - include it
                    messageToFiles[message, default: []].append(prefix)
                }
            } else {
                friendly.append(mapping[rawPart] ?? fallbackReasonMessage(for: rawPart))
            }
        }

        // Consolidate messages with file identifiers
        for (message, files) in messageToFiles.sorted(by: { $0.key < $1.key }) {
            if files.count == 1 {
                friendly.append("\(files[0]): \(message)")
            } else if files.count > 1 {
                let fileList = files.sorted().joined(separator: ", ")
                friendly.append("\(fileList): \(message)")
            } else {
                friendly.append(message)
            }
        }

        return friendly.joined(separator: "; ")
    }

    private static func fallbackReasonMessage(for code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        var result = ""
        for character in trimmed {
            if character == "_" || character == "-" {
                result.append(" ")
                continue
            }
            if character.isUppercase, let last = result.last, last != " " {
                result.append(" ")
            }
            result.append(character)
        }
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? trimmed : cleaned.capitalized
    }

    private func containsGuardSnippet(in segment: String, language: BenchmarkLanguage, expected: String) -> Bool {
        // Try exact match first (with indentation already handled by caller)
        if segment.contains(expected) {
            return true
        }

        // Normalize whitespace for comparison
        let normalizedSegment = segment
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ;", with: ";")
        let normalizedExpected = expected
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ;", with: ";")

        if normalizedSegment.contains(normalizedExpected) {
            return true
        }

        // Try regex-based structure matching as last resort
        let pattern = switch language {
        case .ts:
            #"if\s*\(\s*n\s*<\s*0\s*\)\s*\{\s*return\s+0\s*;?\s*\}"#
        case .go:
            #"if\s+n\s*<\s*0\s*\{\s*return\s+0\s*\}"#
        case .swift:
            #"if\s+n\s*<\s*0\s*\{\s*return\s+0\s*\}"#
        }

        return segment.range(of: pattern, options: .regularExpression) != nil
    }
}
