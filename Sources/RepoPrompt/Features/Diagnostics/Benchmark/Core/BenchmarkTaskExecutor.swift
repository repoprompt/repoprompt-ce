import Foundation
import SwiftAnthropic
import SwiftOpenAI

/// Note: PromptFactory and PromptConfig are used to create custom benchmark prompts
enum BenchmarkTaskExecutorError: Error {
    case missingModelService
    case outputBudgetExceeded
    case searchBlockTooLarge
}

final class BenchmarkTaskExecutor {
    typealias ModelOutputProvider = @Sendable (AIMessage, AIModel) async throws -> String

    private let aiQueriesService: AIQueriesService?
    private let model: AIModel
    private let outputProvider: ModelOutputProvider?
    private let maxOutputBytes: Int
    private let maxOutputLines: Int
    private let maxContextChars: Int
    private let maxDecoyPerFileChars: Int

    init(
        aiQueriesService: AIQueriesService?,
        model: AIModel,
        outputProvider: ModelOutputProvider? = nil,
        maxOutputBytes: Int = 120_000,
        maxOutputLines: Int = 800,
        maxContextChars: Int = 200_000,
        maxDecoyPerFileChars: Int = 40000
    ) {
        self.aiQueriesService = aiQueriesService
        self.model = model
        self.outputProvider = outputProvider
        self.maxOutputBytes = maxOutputBytes
        self.maxOutputLines = maxOutputLines
        self.maxContextChars = max(10000, maxContextChars)
        self.maxDecoyPerFileChars = max(2000, maxDecoyPerFileChars)
    }

    func cancelInFlight() {
        aiQueriesService?.cancelQuery()
    }

    func runTask(
        _ task: BenchmarkTaskSpec,
        fileSystem: inout BenchmarkMockFileSystem,
        baseline: BenchmarkMockFileSystemSnapshot
    ) async -> BenchmarkTaskExecResult {
        // Custom prompt config for benchmarks: disable create, delete, and rename capabilities
        let fileExt = SystemPromptService.fileExtension(for: task.language.displayName)
        let benchmarkConfig = PromptConfig(
            role: .codeAssistant,
            canCreate: false,
            canRewrite: false,
            canSearchReplace: true,
            canDelete: false,
            supportsRename: false,
            language: task.language.displayName,
            fileExtension: fileExt,
            codeBlockFence: SystemPromptService.chatCodeFence,
            includeIndentationEncoding: false,
            includeEscapingRules: true
        )
        let systemPrompt = PromptFactory.buildPrompt(with: benchmarkConfig)
        let packaging = composePackagedUserMessage(
            task: task,
            fileSystem: fileSystem,
            baseline: baseline
        )
        let userPrompt = packaging.prompt
        let aiMessage = AIMessage(
            systemPrompt: systemPrompt,
            userMessage: userPrompt,
            disableTemperatureOverrides: true
        )
        let promptMetaBase: [String: BenchmarkJSONValue] = [
            "systemPrompt": .string(systemPrompt),
            "userPrompt": .string(userPrompt),
            "virtualFiles": .array(packaging.virtualFiles.map { $0.metaValue() })
        ]
        func mergedMeta(_ extra: [String: BenchmarkJSONValue] = [:]) -> [String: BenchmarkJSONValue] {
            var combined = promptMetaBase
            for (key, value) in extra {
                combined[key] = value
            }
            return combined
        }

        let rawOutput: String
        do {
            rawOutput = try await fetchModelOutput(for: aiMessage)
        } catch is CancellationError {
            return BenchmarkTaskExecResult(errors: [], edited: [], meta: promptMetaBase)
        } catch BenchmarkTaskExecutorError.outputBudgetExceeded {
            let err = BenchmarkTaskError(code: "MODEL_OUTPUT_TOO_LARGE", path: nil, detail: "Output exceeded budget")
            return BenchmarkTaskExecResult(
                errors: [err],
                edited: [],
                meta: promptMetaBase
            )
        } catch BenchmarkTaskExecutorError.searchBlockTooLarge {
            let err = BenchmarkTaskError(code: "SEARCH_BLOCK_TOO_LARGE", path: nil, detail: "Search block exceeded maximum line limit - attempted to echo entire file")
            return BenchmarkTaskExecResult(
                errors: [err],
                edited: [],
                meta: mergedMeta(["rawOutput": .string(""), "overBudget": .boolean(true)])
            )
        } catch {
            let err = BenchmarkTaskError(code: "MODEL_EXECUTION_FAILED", path: nil, detail: error.localizedDescription)
            return BenchmarkTaskExecResult(
                errors: [err],
                edited: [],
                meta: mergedMeta(["rawOutput": .string("")])
            )
        }

        let parser = await BenchmarkDiffParserFactory.makeParser(baseline: baseline)
        let parsedFiles: [ParsedFile]
        do {
            parsedFiles = try await parser.parse(rawOutput)
        } catch {
            let err = BenchmarkTaskError(code: "PARSE_OUTPUT_FAILED", path: nil, detail: error.localizedDescription)
            return BenchmarkTaskExecResult(
                errors: [err],
                edited: [],
                meta: mergedMeta(["rawOutput": .string(rawOutput)])
            )
        }

        let hasMissingContent = parsedFiles.contains { file in
            guard file.action == .modify else { return false }
            return file.changes.contains { change in
                guard change.isSelected else { return false }
                let content = change.content ?? []
                if content.isEmpty {
                    return true
                }
                return content.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        }
        if hasMissingContent {
            let err = BenchmarkTaskError(
                code: "PARSE_OUTPUT_FAILED",
                path: nil,
                detail: "One or more <change> blocks are missing <content>"
            )
            let meta = mergedMeta([
                "rawOutput": .string(rawOutput),
                "parsedFileCount": .integer(parsedFiles.count)
            ])
            return BenchmarkTaskExecResult(errors: [err], edited: [], meta: meta)
        }

        // Track edit block counts for soft penalty evaluation
        let editBlockCountTotal = parsedFiles.reduce(0) { $0 + $1.changes.filter(\.isSelected).count }
        var editBlockCountByFile: [String: BenchmarkJSONValue] = [:]
        for parsedFile in parsedFiles {
            let count = parsedFile.changes.filter(\.isSelected).count
            // Normalize path for consistent keys
            let normalizedPath = parsedFile.fileName.replacingOccurrences(of: "\\", with: "/")
            editBlockCountByFile[normalizedPath] = .integer(count)
        }

        let (edited, diffErrors) = await BenchmarkDiffApplier.apply(
            parsedFiles: parsedFiles,
            task: task,
            fileSystem: &fileSystem,
            baseline: baseline
        )

        let lineCount = rawOutput.split(whereSeparator: \.isNewline).count
        let meta = mergedMeta([
            "rawOutput": .string(rawOutput),
            "parsedFileCount": .integer(parsedFiles.count),
            "rawCharCount": .integer(rawOutput.count),
            "rawLineCount": .integer(lineCount),
            "editBlockCountTotal": .integer(editBlockCountTotal),
            "editBlockCountByFile": .object(editBlockCountByFile)
        ])

        return BenchmarkTaskExecResult(errors: diffErrors, edited: edited, meta: meta)
    }

    private func fetchModelOutput(for message: AIMessage) async throws -> String {
        func performRequest() async throws -> String {
            if Task.isCancelled {
                aiQueriesService?.cancelQuery()
                throw CancellationError()
            }
            if let outputProvider {
                let output = try await outputProvider(message, model)
                let byteCount = output.utf8.count
                let lineCount = output.split(whereSeparator: \.isNewline).count
                if byteCount > maxOutputBytes || lineCount > maxOutputLines {
                    throw BenchmarkTaskExecutorError.outputBudgetExceeded
                }
                return output
            }
            guard let aiQueriesService else {
                throw BenchmarkTaskExecutorError.missingModelService
            }
            // Benchmarks use cancelQuery() to cancel all streams for this executor
            let (_, stream) = try await aiQueriesService.sendPrompt(message, model: model)
            var collected = ""
            do {
                for try await chunk in stream {
                    if Task.isCancelled {
                        aiQueriesService.cancelQuery()
                        throw CancellationError()
                    }
                    if !chunk.text.isEmpty {
                        collected += chunk.text
                        let byteCount = collected.utf8.count
                        let lineCount = collected.split(whereSeparator: \.isNewline).count
                        if byteCount > maxOutputBytes || lineCount > maxOutputLines {
                            aiQueriesService.cancelQuery()
                            throw BenchmarkTaskExecutorError.outputBudgetExceeded
                        }
                        // Check for oversized search blocks (models echoing entire files)
                        if detectOversizedSearchBlock(in: collected) {
                            aiQueriesService.cancelQuery()
                            throw BenchmarkTaskExecutorError.searchBlockTooLarge
                        }
                    }
                }
            } catch is CancellationError {
                aiQueriesService.cancelQuery()
                throw CancellationError()
            }
            return collected.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let maxAttempts = 3
        var attempt = 0
        var delay: TimeInterval = 1

        while attempt < maxAttempts {
            do {
                return try await performRequest()
            } catch {
                if error is CancellationError {
                    aiQueriesService?.cancelQuery()
                    throw error
                }
                attempt += 1
                guard attempt < maxAttempts, shouldRetryAPIError(error) else {
                    throw error
                }
                aiQueriesService?.cancelQuery()
                let cappedDelay = min(delay, 60)
                let nanoseconds = UInt64(cappedDelay * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                delay = min(delay * 2, 60)
            }
        }

        throw BenchmarkTaskExecutorError.missingModelService
    }

    /// Detect if any <search> block exceeds the maximum allowed lines (30 lines)
    /// This catches models trying to echo entire files in their search blocks
    private func detectOversizedSearchBlock(in text: String) -> Bool {
        // Pattern 1: <search> blocks with === fences
        let fencedPattern = #"<search>\s*={3,}\s*\n(.*?)\n\s*={3,}\s*</search>"#
        if let regex = try? NSRegularExpression(pattern: fencedPattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)

            for match in matches {
                if match.numberOfRanges > 1,
                   let contentRange = Range(match.range(at: 1), in: text)
                {
                    let content = String(text[contentRange])
                    let lineCount = content.components(separatedBy: .newlines).count
                    if lineCount > 30 {
                        return true
                    }
                }
            }
        }

        // Pattern 2: <search> blocks without fences (plain pattern)
        let plainPattern = #"<search>(.*?)</search>"#
        if let regex = try? NSRegularExpression(pattern: plainPattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)

            for match in matches {
                if match.numberOfRanges > 1,
                   let contentRange = Range(match.range(at: 1), in: text)
                {
                    let content = String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let lineCount = content.components(separatedBy: .newlines).count
                    if lineCount > 30 {
                        return true
                    }
                }
            }
        }

        return false
    }

    private func composePackagedUserMessage(
        task: BenchmarkTaskSpec,
        fileSystem: BenchmarkMockFileSystem,
        baseline: BenchmarkMockFileSystemSnapshot
    ) -> PromptPackagingSnapshot {
        // Scale context budget for harder difficulties (25% for hard, 50% for veryHard)
        let effectiveMaxContextChars: Int = switch task.difficulty {
        case .hard:
            Int(Double(self.maxContextChars) * 1.25)
        case .veryHard:
            Int(Double(self.maxContextChars) * 1.5)
        default:
            self.maxContextChars
        }
        let maxContextChars = effectiveMaxContextChars

        let maxDecoys = max(0, task.params["maxDecoys"]?.intValue ?? 3)
        let fullDecoyPaths = task.params["fullDecoys"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let normalizedFullDecoys = fullDecoyPaths.map { BenchmarkMockFileSystem.normalize($0) }
        let fullDecoySet = Set(normalizedFullDecoys)

        // Extract auto-planned decoys (prioritized over fullDecoys and computeContextPaths)
        let decoyPaths = task.params["decoyPaths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let normalizedDecoyPaths = decoyPaths.map { BenchmarkMockFileSystem.normalize($0) }

        // Extract guidance verbosity
        let hintVerbosity = task.params["hintVerbosity"]?.stringValue ?? "standard"
        let candidatePaths = computeContextPaths(task: task, baseline: baseline, maxDecoys: maxDecoys)
        let normalizedTargets = Set(task.selectFiles.map { BenchmarkMockFileSystem.normalize($0) })
        let normalizedCandidates = candidatePaths.map { BenchmarkMockFileSystem.normalize($0) }
        let primaryPaths = normalizedCandidates.filter { normalizedTargets.contains($0) }
        let decoyCandidates = normalizedCandidates.filter { !normalizedTargets.contains($0) }
        let otherDecoys = decoyCandidates.filter { !fullDecoySet.contains($0) }
        var totalChars = 0
        var blocks: [String] = []
        var seenFullDecoys: Set<String> = []
        var seenDecoyPaths: Set<String> = []
        var primaryList: [String] = []
        var includedAutoPlannedDecoys: [String] = []
        var includedFullDecoys: [String] = []
        var includedTrimmedDecoys: [String] = []
        var virtualFiles: [PromptVirtualFile] = []

        func deduplicated(_ items: [String]) -> [String] {
            var seen = Set<String>()
            return items.filter { seen.insert($0).inserted }
        }

        func bulletList(_ items: [String]) -> String {
            let values = deduplicated(items)
            switch values.count {
            case 0:
                return "- (none)"
            default:
                return values.map { "- \($0)" }.joined(separator: "\n")
            }
        }

        func blockFor(path: String, content: String, role: String, truncated: Bool) -> String {
            let normalized = BenchmarkMockFileSystem.normalize(path)
            let fence = codeFenceStart(forPath: normalized, defaultLanguage: task.language)
            let block = """
            File: \(normalized)
            \(fence)
            \(content)
            ```
            """
            let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
            let virtualFile = PromptVirtualFile(
                path: normalized,
                content: content,
                fence: fence,
                role: role,
                truncated: truncated,
                block: trimmedBlock
            )
            virtualFiles.append(virtualFile)
            return trimmedBlock
        }

        for path in primaryPaths {
            let content = fileSystem.content(for: path) ?? baseline.content(for: path) ?? ""
            let block = blockFor(path: path, content: content, role: "primary", truncated: false)
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
            totalChars += content.count
            primaryList.append(path)
        }

        // Prioritize auto-planned decoys (decoyPaths) - these are problem-specific with identical cores
        for path in normalizedDecoyPaths {
            guard !normalizedTargets.contains(path), seenDecoyPaths.insert(path).inserted else { continue }
            let remaining = maxContextChars - totalChars
            guard remaining > 0 else { break }
            let content = fileSystem.content(for: path) ?? baseline.content(for: path) ?? ""
            let block = blockFor(path: path, content: content, role: "decoy_planned", truncated: false)
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
            totalChars += content.count
            includedAutoPlannedDecoys.append(path)
        }

        for path in normalizedFullDecoys {
            guard !normalizedTargets.contains(path), seenFullDecoys.insert(path).inserted else { continue }
            let remaining = maxContextChars - totalChars
            guard remaining > 0 else { break }
            let content = fileSystem.content(for: path) ?? baseline.content(for: path) ?? ""
            let block = blockFor(path: path, content: content, role: "decoy_full", truncated: false)
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
            totalChars += content.count
            includedFullDecoys.append(path)
        }

        var addedDecoys = 0
        for path in otherDecoys {
            guard addedDecoys < maxDecoys else { break }
            guard !path.isEmpty else { continue }
            let raw = fileSystem.content(for: path) ?? baseline.content(for: path) ?? ""
            let remaining = maxContextChars - totalChars
            guard remaining > 0 else { break }
            let allowed = min(remaining, maxDecoyPerFileChars)
            guard allowed > 0 else { break }
            let truncated = raw.count > allowed
            let content: String = if truncated {
                String(raw.prefix(allowed))
            } else {
                raw
            }
            let block = blockFor(path: path, content: content, role: truncated ? "decoy_trimmed" : "decoy", truncated: truncated)
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
            totalChars += content.count
            addedDecoys += 1
            includedTrimmedDecoys.append(path)
        }

        let normalizedSelection = task.selectFiles.map { BenchmarkMockFileSystem.normalize($0) }
        if primaryList.isEmpty {
            primaryList = deduplicated(normalizedSelection)
        }
        let contextDecoys = deduplicated(includedAutoPlannedDecoys + includedFullDecoys + includedTrimmedDecoys)

        // Build Notes section based on guidance verbosity
        let notesSection = switch hintVerbosity {
        case "none":
            ""
        case "minimal":
            """

            Notes:
            - Only edit the primary edit targets listed above.
            """
        default: // "standard" or any other value
            """

            Notes:
            - Some context files are intentional decoys that closely resemble the real targets—double-check the exact path before editing.
            - Partial decoy files may be truncated. Editing them will cause verification to fail.
            """
        }

        let targetDiscovery = task.params["targetDiscovery"]?.boolValue == true
        let overviewSection = if targetDiscovery {
            """
            <task_overview>
            Candidate edit targets (exactly one should be edited):
            \(bulletList(primaryList))

            Context-only files included for reference:
            \(bulletList(contextDecoys))\(notesSection)
            </task_overview>

            """
        } else {
            """
            <task_overview>
            Primary edit targets (only modify these paths):
            \(bulletList(primaryList))

            Context-only files included for reference (do not edit unless promoted above):
            \(bulletList(contextDecoys))\(notesSection)
            </task_overview>

            """
        }
        let joinedBlocks = blocks.joined(separator: "\n\n")
        let fileSection = """
        <file_contents>
        \(joinedBlocks)
        </file_contents>

        """
        func parameterDetail(for task: BenchmarkTaskSpec) -> String? {
            /// Helper functions for indentation
            func leadingIndentation(of line: Substring) -> String {
                var indent = ""
                for char in line {
                    if char == " " || char == "\t" {
                        indent.append(char)
                    } else {
                        break
                    }
                }
                return indent
            }

            func indentSnippet(_ value: String, indent: String) -> String {
                guard !indent.isEmpty else { return value }
                let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
                return lines.map { indent + String($0) }.joined(separator: "\n")
            }

            func inferAnchorIndentation(in text: String, startToken: String, endToken: String, language: BenchmarkLanguage) -> String {
                guard
                    let startRange = text.range(of: startToken),
                    let endRange = text.range(of: endToken, range: startRange.upperBound ..< text.endIndex)
                else {
                    // Fallback to language default
                    return language == .swift ? "\t" : "    "
                }

                let interior = text[startRange.upperBound ..< endRange.lowerBound]
                let lines = interior.split(separator: "\n", omittingEmptySubsequences: false)
                if let sample = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    return leadingIndentation(of: sample)
                }

                // Try looking at the line after the end anchor
                let tail = text[startRange.upperBound ..< text.endIndex]
                if let newlineIndex = tail.firstIndex(of: "\n") {
                    let afterNewline = tail[tail.index(after: newlineIndex) ..< tail.endIndex]
                    if let nextLine = afterNewline.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first {
                        return leadingIndentation(of: nextLine)
                    }
                }

                // Fallback to language default
                return language == .swift ? "\t" : "    "
            }

            switch task.type {
            case .insertGuardTs, .insertGuardGo, .insertGuardSwift:
                // Check for markerless mode first
                if task.params["markerless"]?.boolValue == true,
                   let functionName = task.params["functionName"]?.stringValue,
                   let insertAfterPattern = task.params["insertAfterPattern"]?.stringValue,
                   let snippet = task.params["snippet"]?.stringValue
                {
                    let indentType = task.language == .swift ? "tabs" : "4 spaces"
                    return """
                    Locate the \(functionName)() function. Insert the provided snippet immediately after the first line containing '\(insertAfterPattern)'.

                    Snippet to insert:
                    ```\(task.language.codeFenceIdentifier)
                    \(snippet)
                    ```

                    Your <search> block must include:
                    - The function signature line (function \(functionName)(...) or func \(functionName)(...))
                    - The line declaring '\(insertAfterPattern)'
                    - Multiple unchanged lines after the insertion point for context
                    - Total: 5–8 lines (strongly recommended due to multiple near-match regions)

                    Note: This file contains many near-identical code fragments. Short search blocks will be ambiguous. Include both the function signature and multiple body lines to ensure uniqueness.

                    Use \(indentType) for indentation. Only modify the \(functionName)() function—other functions (like \(functionName)Positive, \(functionName)Bounded) must remain unchanged.
                    """
                }

                // Multi-file array format
                if let items = task.params["guards"]?.arrayValue, !items.isEmpty {
                    var sections: [String] = []
                    sections.append("Insert the provided guard block in each file immediately after its ANCHOR:start:<UID>, keeping anchors unchanged and using the file's indentation (TS/Go: 4 spaces, Swift: tabs).")

                    for item in items {
                        guard
                            let obj = item.objectValue,
                            let path = obj["path"]?.stringValue,
                            let uid = obj["uid"]?.stringValue,
                            let rawSnippet = obj["snippet"]?.stringValue
                        else { continue }

                        let startToken = "// ANCHOR:start:\(uid)"
                        let endToken = "// ANCHOR:end:\(uid)"
                        let sourceText = fileSystem.content(for: path) ?? baseline.content(for: path) ?? ""

                        let indent = inferAnchorIndentation(in: sourceText, startToken: startToken, endToken: endToken, language: task.language)
                        let indented = indentSnippet(rawSnippet, indent: indent)

                        sections.append("""
                        File: \(path)
                        UID: \(uid)

                        Anchors (verbatim):
                          START: \(startToken)
                          END  : \(endToken)

                        Insert this snippet between those anchors exactly as shown:
                        ```\(task.language.codeFenceIdentifier)
                        \(indented)
                        ```

                        Your <search> must include at least 3 lines. Example (start anchor + empty line + end anchor):
                          \(startToken)

                          \(endToken)
                        """)
                    }
                    return sections.joined(separator: "\n\n")
                }

                // Single-file fallback
                guard
                    let uid = task.params["uid"]?.stringValue,
                    let snippet = task.params["snippet"]?.stringValue
                else {
                    return nil
                }
                let startToken = "// ANCHOR:start:\(uid)"
                let endToken = "// ANCHOR:end:\(uid)"
                let path = task.selectFiles.first
                let sourceText: String? = {
                    guard let path else { return nil }
                    return fileSystem.content(for: path) ?? baseline.content(for: path)
                }()
                let inferredIndent: String = {
                    guard let sourceText else { return "" }
                    return inferAnchorIndentation(in: sourceText, startToken: startToken, endToken: endToken, language: task.language)
                }()
                let indentedSnippet = indentSnippet(snippet, indent: inferredIndent)
                return """
                Anchors (verbatim):
                  START: // ANCHOR:start:\(uid)
                  END  : // ANCHOR:end:\(uid)

                Insert this snippet between those anchors exactly as shown (no tabs; indentation already matches the file):
                ```\(task.language.codeFenceIdentifier)
                \(indentedSnippet)
                ```

                Your <search> must include at least 3 lines. Example (start anchor + empty line + end anchor):
                  // ANCHOR:start:\(uid)

                  // ANCHOR:end:\(uid)
                """
            case .indexOnlyAppsTs, .indexOnlyAppsGo, .indexOnlyAppsSwift:
                guard let target = task.params["target"]?.stringValue else { return nil }
                let signature: String
                let ret: String
                switch task.language {
                case .ts:
                    signature = "export default function index() { ... }"
                    ret = "return \"\(target)\";"
                case .go:
                    signature = "func index() { ... }"
                    ret = "return \"\(target)\""
                case .swift:
                    signature = "func index() { ... }"
                    ret = "return \"\(target)\""
                }
                return """
                Required marker (verbatim): `// DONE:\(target)`
                Placement: line immediately after `\(ret)` inside `\(signature)`.
                The return line must stay exactly `\(ret)`.
                """
            case .swapArgsInRegionTs, .swapArgsInRegionGo, .swapArgsInRegionSwift:
                if task.params["markerless"]?.boolValue == true {
                    guard let functionName = task.params["functionName"]?.stringValue
                    else {
                        return nil
                    }
                    let indentNote = task.language == .swift ? "tabs" : "4 spaces"
                    return """
                    Locate the function named '\(functionName)' in each file.
                    Swap all use(a, b) calls to use(b, a) within this function.
                    Your <search> block must include: at least one unchanged line before the first use() call, all use() calls, and at least one unchanged line after (3-8 lines total).
                    Use \(indentNote) for indentation.
                    Do NOT modify other functions or code outside '\(functionName)'.
                    """
                } else {
                    guard
                        let uid = task.params["uid"]?.stringValue,
                        let expected = task.params["expectedSwaps"]?.intValue
                    else {
                        return nil
                    }
                    return """
                    Only modify the region between these markers (UID=\(uid)):
                      /* START_SWAP:\(uid) */
                      /* END_SWAP:\(uid) */

                    Change calls inside to `use(b, a)` and perform exactly \(expected) swaps. Everything outside stays identical.

                    **Important**: If the region exceeds 8 lines, split it into multiple <change> blocks (e.g., 2 lines before + 5 target lines + 1 after = 8 total). Decoy regions with different UIDs must remain unchanged.
                    """
                }
            case .renameExportImportsTs, .renameExportImportsGo, .renameExportImportsSwift:
                guard
                    let rename = task.params["rename"]?.objectValue,
                    let from = rename["from"]?.stringValue,
                    let to = rename["to"]?.stringValue
                else {
                    return nil
                }
                let importerPaths = task.params["importPaths"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let allowed = ([task.selectFiles.first].compactMap(\.self) + importerPaths).filter { !$0.isEmpty }
                let allowedList = allowed.map { "- \($0)" }.joined(separator: "\n")
                return """
                Rename `\(from)` to `\(to)` in the exporter and only these importers:
                \(allowedList)
                Do not touch files outside this list.
                """
            case .moveFunctionTs, .moveFunctionGo, .moveFunctionSwift:
                guard
                    let from = task.params["fromName"]?.stringValue,
                    let after = task.params["afterName"]?.stringValue,
                    let path = task.selectFiles.first
                else {
                    return nil
                }
                return """
                File: \(path)

                Move the entire function `\(from)(...) { ... }` so it appears **after** the function `\(after)(...) { ... }`.
                - Do NOT duplicate; remove it from its original location.
                - Make no other edits.
                """
            case .insertFunctionBottomTs, .insertFunctionBottomGo, .insertFunctionBottomSwift:
                // Multi-file array format
                if let inserts = task.params["inserts"]?.arrayValue, !inserts.isEmpty {
                    var sections: [String] = []
                    sections.append("Insert each snippet immediately above the footer marker in the specified file(s). Keep all existing lines unchanged. Maintain exactly one blank line between the last existing function and the snippet, and one blank line before the footer.")

                    for entry in inserts {
                        guard
                            let obj = entry.objectValue,
                            let path = obj["path"]?.stringValue,
                            let snippet = obj["snippet"]?.stringValue
                        else { continue }

                        let footer = obj["footer"]?.stringValue ?? (task.params["footer"]?.stringValue ?? "// END-OF-FILE")

                        sections.append("""
                        File: \(path)
                        Footer marker (verbatim):
                          \(footer)

                        Snippet to insert:
                        ```\(task.language.codeFenceIdentifier)
                        \(snippet)
                        ```
                        """)
                    }
                    return sections.joined(separator: "\n\n")
                }

                // Single-file fallback
                guard
                    let snippet = task.params["snippet"]?.stringValue,
                    let footer = task.params["footer"]?.stringValue,
                    let path = task.selectFiles.first
                else {
                    return nil
                }
                return """
                Append the following snippet **immediately above** `\(footer)` in \(path):

                ```\(task.language.codeFenceIdentifier)
                \(snippet)
                ```

                Keep all existing lines identical.
                """
            case .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift:
                let targetDiscovery = task.params["targetDiscovery"]?.boolValue == true
                guard let patch = task.params["patch"]?.stringValue else {
                    return nil
                }

                if targetDiscovery {
                    return """
                    Apply this unified diff to exactly one file among the candidate edit targets below. Identify the correct file by matching the patch hunks to the file contents. Patch headers hide the file path on purpose.

                    ```diff
                    \(patch)
                    ```

                    Rules:
                    - Edit exactly one file from the candidates list; do not modify others.
                    - Emit a minimal set of <change> blocks to realize these hunks; avoid rewriting entire files.
                    - Search blocks must be precise enough to disambiguate near-identical regions across files.
                    """
                } else {
                    guard let path = task.selectFiles.first else {
                        return nil
                    }
                    return """
                    Apply this unified diff to `\(path)` **exactly** (no more, no less):

                    ```diff
                    \(patch)
                    ```

                    Emit a minimal set of <change> blocks to realize these hunks; do not rewrite the whole file.
                    """
                }
            case .curlyFixTs, .curlyFixGo, .curlyFixSwift:
                guard let path = task.params["file"]?.stringValue else { return nil }
                return """
                Target file: \(path)
                Resolve any structural imbalance so the code compiles and the log/print occurs exactly once after iteration completes.
                Make focused edits only; avoid rewriting or reformatting existing lines.
                """
            case .patchBlockTs, .patchBlockGo, .patchBlockSwift:
                if task.params["markerless"]?.boolValue == true {
                    guard let functionName = task.params["functionName"]?.stringValue,
                          let snippet = task.params["snippet"]?.stringValue
                    else {
                        return nil
                    }
                    let indentNote = task.language == .swift ? "tabs" : "4 spaces"
                    return """
                    Locate the function named '\(functionName)' in each file.
                    Replace its entire body with the provided snippet.
                    Your <search> block must include: the function signature line, at least one line from the existing body, and the closing brace (3-8 lines total).
                    Use \(indentNote) for indentation.
                    Do NOT modify other functions or code outside '\(functionName)'.
                    Emit unchanged outer lines verbatim in <content>.

                    Snippet:
                    ```\(task.language.codeFenceIdentifier)
                    \(snippet)
                    ```
                    """
                } else {
                    guard
                        let uid = task.params["uid"]?.stringValue,
                        let snippet = task.params["snippet"]?.stringValue
                    else {
                        return nil
                    }
                    return """
                    Only modify the body between these exact markers:
                    	/* BLOCK START:\(uid) */
                    	/* BLOCK END:\(uid) */

                    Replace the body with the snippet below (verbatim). Do **not** touch the marker lines themselves.

                    ```\(task.language.codeFenceIdentifier)
                    \(snippet)
                    ```
                    """
                }
            case .removeXTs, .removeXGo, .removeXSwift:
                return nil
            }
        }
        var instructionSections: [String] = [task.task]
        if !task.instructions.isEmpty {
            let bullet = task.instructions.map { "- \($0)" }.joined(separator: "\n")
            instructionSections.append("Instructions:\n\(bullet)")
        }
        if !task.acceptance.isEmpty {
            let bullet = task.acceptance.map { "- \($0)" }.joined(separator: "\n")
            instructionSections.append("Acceptance:\n\(bullet)")
        }
        if let detail = parameterDetail(for: task) {
            instructionSections.append(detail)
        }
        let instructionBody = instructionSections.joined(separator: "\n\n")
        let instructionsSection = """
        <user_instructions>
        \(instructionBody)
        </user_instructions>
        """
        let contract = """

        <strict_output_contract>
        - Output ONLY <file> blocks; no prose outside the XML.
        - For each <change>, include a <search> block that EXACTLY matches baseline lines (whitespace included).
        - Reusing an identical <search> advances past the prior match; if the file has only one such region, the second change fails. Combine related edits into one <change> or adjust the context.
        - Each <search> MUST include 3–8 lines (one unchanged line before, target line(s), one unchanged after). Exception: rename_export_and_imports_* may use 2 lines due to tiny barrel files. If a target region exceeds 8 lines, split into multiple <change> blocks with 3–8 lines each.
        - Do NOT emit files outside the provided selection.
        - Total output budget is small; avoid echoing full files. Oversized output fails the task.
        </strict_output_contract>
        """
        let prompt = overviewSection + fileSection + instructionsSection + contract
        return PromptPackagingSnapshot(prompt: prompt, virtualFiles: virtualFiles)
    }

    private func computeContextPaths(
        task: BenchmarkTaskSpec,
        baseline: BenchmarkMockFileSystemSnapshot,
        maxDecoys: Int = 3
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for path in task.selectFiles {
            let normalized = BenchmarkMockFileSystem.normalize(path)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                ordered.append(normalized)
            }
        }
        let extensionSuffix = switch task.language {
        case .ts:
            ".ts"
        case .go:
            ".go"
        case .swift:
            ".swift"
        }
        let targetRoots = Set(task.selectFiles.map { BenchmarkMockFileSystem.normalize($0).split(separator: "/").first.map(String.init) ?? "" })
        let decoyCandidates = baseline.allPaths
            .filter { !seen.contains($0) && $0.hasSuffix(extensionSuffix) }
            // Prefer decoys from different top-level roots to stress path retention
            .sorted { lhs, rhs in
                let lroot = lhs.split(separator: "/").first.map(String.init) ?? ""
                let rroot = rhs.split(separator: "/").first.map(String.init) ?? ""
                let lprio = targetRoots.contains(lroot) ? 1 : 0
                let rprio = targetRoots.contains(rroot) ? 1 : 0
                if lprio == rprio {
                    return lhs < rhs
                }
                return lprio < rprio
            }
        for path in decoyCandidates.prefix(maxDecoys) {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        return ordered
    }

    private func codeFenceStart(forPath path: String, defaultLanguage: BenchmarkLanguage) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension
        if ext.isEmpty {
            let identifier = defaultLanguage.codeFenceIdentifier
            return identifier.isEmpty ? "```" : "```\(identifier)"
        }
        return PromptPackagingService.codeFenceStart(for: path)
    }
}

private func shouldRetryAPIError(_ error: Error) -> Bool {
    if let providerError = error as? AIProviderError {
        if case .apiError = providerError {
            return true
        }
        return false
    }

    if let customError = error as? CustomOpenAIProviderError {
        switch customError {
        case .rateLimitExceeded, .serverError, .serviceUnavailable:
            return true
        case let .requestFailed(statusCode: status, _),
             let .invalidResponse(statusCode: status, _):
            return [408, 429, 500, 502, 503, 504].contains(status)
        default:
            return false
        }
    }

    if error is SwiftOpenAI.APIError || error is SwiftAnthropic.APIError {
        return true
    }

    if error is URLError {
        return true
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain
}

private struct PromptPackagingSnapshot {
    let prompt: String
    let virtualFiles: [PromptVirtualFile]
}

private struct PromptVirtualFile {
    let path: String
    let content: String
    let fence: String
    let role: String
    let truncated: Bool
    let block: String

    func blockText() -> String {
        block
    }

    func metaValue() -> BenchmarkJSONValue {
        .object([
            "path": .string(path),
            "content": .string(content),
            "fence": .string(fence),
            "role": .string(role),
            "truncated": .boolean(truncated),
            "block": .string(block)
        ])
    }
}
