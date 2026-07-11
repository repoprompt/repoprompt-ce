import Foundation

enum BenchmarkDiffApplicationError: Error {
    case unexpectedFile(path: String)
    case tooManyEdits(limit: Int, actual: Int)
    case missingBaseline(path: String)
    case noChangesGenerated(path: String)
    case editApplicationFailed(path: String, reason: String)
    case searchBlockNotFound(path: String)
}

enum BenchmarkDiffApplier {
    private static func relativePath(from canonicalPath: String) -> String {
        let normalized = BenchmarkMockFileSystem.normalize(canonicalPath)
        let prefix = "benchmark/"
        if normalized.hasPrefix(prefix) {
            return String(normalized.dropFirst(prefix.count))
        }
        if normalized == "benchmark" {
            return ""
        }
        return normalized
    }

    /// Returns the minimum number of lines required in a search block for the given case type.
    ///
    /// **Purpose**: These minimums prevent models from using overly-simple search blocks that could
    /// match decoy code intentionally placed in benchmark tasks. The model must provide sufficient
    /// context to uniquely identify the correct location.
    ///
    /// **Correlation with Task Generators**: These values should align with the decoy generation
    /// strategy for each task type. If a task generator creates single-line decoys, the minimum
    /// must be >1 to force disambiguation.
    ///
    /// **No upper limit**: More specific search blocks are encouraged and not penalized, as they
    /// reduce the risk of matching unintended locations (including shadow decoys).
    ///
    /// Note: In addition to line count, we require at least 2 non-empty lines to prevent
    /// search blocks consisting only of blank lines.
    private static func minSearchLines(for caseType: BenchmarkCaseType) -> Int {
        switch caseType {
        case .patchBlockTs, .patchBlockGo, .patchBlockSwift:
            3 // Blocks may have similar signatures; need surrounding context
        case .swapArgsInRegionTs, .swapArgsInRegionGo, .swapArgsInRegionSwift:
            3 // Multiple similar regions may exist; need distinct context
        case .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift:
            3 // Patches should match sufficient context to avoid wrong location
        case .insertGuardTs, .insertGuardGo, .insertGuardSwift:
            2 // Anchors provide unique UIDs, reducing ambiguity risk
        case .renameExportImportsTs, .renameExportImportsGo, .renameExportImportsSwift:
            2 // Symbol names are typically unique within scope
        default:
            2 // Conservative minimum for general disambiguation
        }
    }

    private static func forbidSearchBlockReuse(for caseType: BenchmarkCaseType) -> Bool {
        switch caseType {
        case .patchBlockTs, .patchBlockGo, .patchBlockSwift,
             .swapArgsInRegionTs, .swapArgsInRegionGo, .swapArgsInRegionSwift,
             .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift:
            true
        default:
            false
        }
    }

    static func apply(
        parsedFiles: [ParsedFile],
        task: BenchmarkTaskSpec,
        fileSystem: inout BenchmarkMockFileSystem,
        baseline: BenchmarkMockFileSystemSnapshot
    ) async -> (edited: [BenchmarkEditedFile], errors: [BenchmarkTaskError]) {
        let allowedPaths = Set(task.selectFiles.map { BenchmarkMockFileSystem.normalize($0) })
        var edited: [BenchmarkEditedFile] = []
        var errors: [BenchmarkTaskError] = []

        let totalChangeCount = parsedFiles.reduce(0) { $0 + $1.changes.count }
        if totalChangeCount > task.maxEdits {
            errors.append(
                BenchmarkTaskError(
                    code: "TOO_MANY_EDITS",
                    path: nil,
                    detail: "max=\(task.maxEdits)"
                )
            )
        }

        for parsedFile in parsedFiles {
            let normalizedPath = relativePath(from: parsedFile.fileName)
            guard allowedPaths.contains(normalizedPath) else {
                errors.append(BenchmarkTaskError(code: "UNEXPECTED_FILE_EDIT", path: normalizedPath, detail: nil))
                continue
            }

            do {
                let newContent: String
                switch parsedFile.action {
                case .create, .rewrite:
                    newContent = resolvedContentForCreate(parsedFile)
                case .delete:
                    fileSystem.removeFile(normalizedPath)
                    edited.append(BenchmarkEditedFile(path: normalizedPath, content: ""))
                    continue
                case .modify:
                    let baselineText = fileSystem.content(for: normalizedPath)
                        ?? baseline.content(for: normalizedPath)
                        ?? ""
                    newContent = try await applyModifyChange(
                        parsedFile: parsedFile,
                        originalText: baselineText,
                        caseType: task.type
                    )
                }

                let decodedContent = String.decodeIndentationPreservingAllLineEndings(newContent)
                fileSystem.setFile(normalizedPath, content: decodedContent)
                edited.append(BenchmarkEditedFile(path: normalizedPath, content: decodedContent))
            } catch let BenchmarkDiffApplicationError.noChangesGenerated(path) {
                errors.append(BenchmarkTaskError(code: "EDIT_APPLY_FAILED", path: path, detail: "noChangesGenerated"))
            } catch let BenchmarkDiffApplicationError.searchBlockNotFound(path) {
                errors.append(BenchmarkTaskError(code: "SEARCH_BLOCK_NOT_FOUND", path: path, detail: nil))
            } catch let BenchmarkDiffApplicationError.editApplicationFailed(path, reason) {
                errors.append(BenchmarkTaskError(code: "EDIT_APPLY_FAILED", path: path, detail: reason))
            } catch {
                errors.append(BenchmarkTaskError(code: "EDIT_APPLY_FAILED", path: normalizedPath, detail: error.localizedDescription))
            }
        }

        return (edited, errors)
    }

    private static func resolvedContentForCreate(_ parsedFile: ParsedFile) -> String {
        if !parsedFile.fileContent.isEmpty {
            return parsedFile.fileContent
        }
        let changeStrings = parsedFile.changes.compactMap { change -> String? in
            guard let lines = change.content else { return nil }
            return lines.joined(separator: "\n")
        }
        return changeStrings.joined(separator: "\n\n")
    }

    private static func applyModifyChange(
        parsedFile: ParsedFile,
        originalText: String,
        caseType: BenchmarkCaseType
    ) async throws -> String {
        let normalizedPath = relativePath(from: parsedFile.fileName)
        let (originalLines, _) = String.splitContentPreservingLineEndings(originalText)
        let (indentType, _) = String.detectIndentationTypeFromLines(originalLines.isEmpty ? [""] : originalLines)
        let encodedLines = originalLines.map { String.encodeIndentationWithConversion($0, desiredIndentationType: indentType) }
        let processedLineData = encodedLines.map { DiffGenerationUtility.processLine($0, precision: .normal) }
        let lineIndexMap = DiffGenerationUtility.buildLineIndexMapHigh(content: processedLineData)
        let forbidReuse = forbidSearchBlockReuse(for: caseType)
        var usedSearchKeys: Set<String> = []
        var cursorMap: [String: Int] = [:]
        var generatedChunks: [DiffChunk] = []

        for change in parsedFile.changes where change.isSelected {
            if Task.isCancelled {
                continue
            }
            guard let newContent = change.content, !newContent.isEmpty else { continue }
            guard let searchBlock = change.searchBlock, !searchBlock.isEmpty else {
                throw BenchmarkDiffApplicationError.editApplicationFailed(path: normalizedPath, reason: "missingSearchBlock")
            }
            // Removed minimum line checks - let the model provide as much context as needed
            // If insufficient context causes ambiguity, the edit will match the first occurrence
            // and verification will catch incorrect edits, testing the model's disambiguation ability
            let processedKey = searchBlock
                .map { DiffGenerationUtility.processLine($0, precision: .normal).removedTagsHigh }
                .joined(separator: "\n")
            if forbidReuse && usedSearchKeys.contains(processedKey) {
                throw BenchmarkDiffApplicationError.editApplicationFailed(path: normalizedPath, reason: "reusedSearchBlock")
            }
            if forbidReuse {
                usedSearchKeys.insert(processedKey)
            }
            let searchStartLine = cursorMap[processedKey] ?? 0
            if searchStartLine == 0 {
                let encodedSearch = searchBlock.map { String.encodeIndentationWithConversion($0, desiredIndentationType: indentType) }
                let selectorProcessed = encodedSearch.map { DiffGenerationUtility.processLine($0, precision: .high) }
                do {
                    _ = try DiffGenerationUtility.matchSelectorFastWithAmbiguityCheck(
                        selector: selectorProcessed,
                        content: processedLineData,
                        lineIndex: lineIndexMap
                    )
                } catch DiffGenerationError.ambiguousMatch {
                    throw BenchmarkDiffApplicationError.editApplicationFailed(path: normalizedPath, reason: "ambiguousSearch")
                } catch {
                    // Allow slower diff generation to attempt matching
                }
            }
            let effectiveLineIndexMap: [String: [Int]]? = (searchStartLine == 0) ? lineIndexMap : nil
            let diffChunks: [DiffChunk]
            do {
                diffChunks = try await DiffGenerationUtility.generateDiff(
                    fileContent: encodedLines,
                    lineIndexMap: effectiveLineIndexMap,
                    startSelector: nil,
                    endSelector: nil,
                    searchBlock: searchBlock,
                    newContent: newContent,
                    action: parsedFile.action,
                    diffPrecision: .normal,
                    searchStartLine: searchStartLine
                )
            } catch DiffGenerationError.noMatchFound {
                throw BenchmarkDiffApplicationError.searchBlockNotFound(path: normalizedPath)
            } catch {
                throw BenchmarkDiffApplicationError.editApplicationFailed(path: normalizedPath, reason: error.localizedDescription)
            }
            if let firstChunk = diffChunks.first {
                cursorMap[processedKey] = max(cursorMap[processedKey] ?? 0, firstChunk.startLine + searchBlock.count)
            }
            generatedChunks.append(contentsOf: diffChunks)
        }

        guard !generatedChunks.isEmpty else {
            throw BenchmarkDiffApplicationError.noChangesGenerated(path: normalizedPath)
        }

        do {
            return try DiffChunkTextApplier.apply(chunks: generatedChunks, to: originalText)
        } catch {
            throw BenchmarkDiffApplicationError.editApplicationFailed(path: parsedFile.fileName, reason: error.localizedDescription)
        }
    }
}
