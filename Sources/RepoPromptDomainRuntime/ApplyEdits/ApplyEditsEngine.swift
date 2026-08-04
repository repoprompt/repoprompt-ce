import Foundation

package struct ApplyEditsEngine {
    package let diffEngine: DiffChunkGenerator
    package let patchApplier: DiffChunkApplier
    package let unifiedDiffRenderer: UnifiedDiffRendering

    package init(
        diffEngine: DiffChunkGenerator,
        patchApplier: DiffChunkApplier,
        unifiedDiffRenderer: UnifiedDiffRendering
    ) {
        self.diffEngine = diffEngine
        self.patchApplier = patchApplier
        self.unifiedDiffRenderer = unifiedDiffRenderer
    }

    package static var `default`: ApplyEditsEngine {
        ApplyEditsEngine(
            diffEngine: DefaultDiffChunkGenerator(),
            patchApplier: DefaultDiffChunkApplier(),
            unifiedDiffRenderer: DefaultUnifiedDiffRenderer()
        )
    }

    package func apply(
        request: ApplyEditsRequest,
        to originalText: String,
        options: ApplyEditsExecutionOptions = .default
    ) async throws -> ApplyEditsResult {
        let state = EditFlowPerf.begin(
            EditFlowPerf.Stage.ApplyEdits.engineApply,
            EditFlowPerf.Dimensions(
                fileBytes: originalText.utf8.count,
                editCount: request.editCount,
                includesToolCardDiff: options.includeToolCardUnifiedDiff
            )
        )
        defer { EditFlowPerf.end(EditFlowPerf.Stage.ApplyEdits.engineApply, state) }

        switch request.mode {
        case let .rewrite(newText, _):
            let single = try await applySingle(
                filePath: request.path,
                originalText: originalText,
                search: nil,
                replace: newText,
                replaceAll: false,
                treatAsRewrite: true
            )
            return buildResult(
                originalText: originalText,
                updatedText: single.updatedText,
                diffChunks: single.diffChunks,
                note: nil,
                editsRequested: 1,
                editsApplied: 1,
                status: .success,
                outcomes: nil,
                path: request.path,
                verbose: request.verbose,
                options: options
            )

        case let .single(search, replace, replaceAll):
            let single = try await applySingle(
                filePath: request.path,
                originalText: originalText,
                search: search,
                replace: replace,
                replaceAll: replaceAll,
                treatAsRewrite: false
            )
            return buildResult(
                originalText: originalText,
                updatedText: single.updatedText,
                diffChunks: single.diffChunks,
                note: nil,
                editsRequested: 1,
                editsApplied: 1,
                status: .success,
                outcomes: nil,
                path: request.path,
                verbose: request.verbose,
                options: options
            )

        case let .batch(edits):
            return try await applyBatch(
                edits: edits,
                originalText: originalText,
                path: request.path,
                verbose: request.verbose,
                options: options
            )
        }
    }

    private func applySingle(
        filePath: String,
        originalText: String,
        search: String?,
        replace: String,
        replaceAll: Bool,
        treatAsRewrite: Bool
    ) async throws -> (updatedText: String, diffChunks: [DiffChunk]) {
        var effectiveSearch = search
        var effectiveReplace = replace
        if let search, !treatAsRewrite {
            let fallback = ApplyEditsEscapeFallback()
            let resolved = fallback.resolveSingle(search: search, replace: replace, in: originalText)
            effectiveSearch = resolved.search
            effectiveReplace = resolved.replace
        }

        let diffChunks = try await EditFlowPerf.measure(
            EditFlowPerf.Stage.ApplyEdits.diffGeneration,
            EditFlowPerf.Dimensions(fileBytes: originalText.utf8.count)
        ) {
            try await diffEngine.makeDiffChunks(
                filePath: filePath,
                originalText: originalText,
                search: effectiveSearch,
                replace: effectiveReplace,
                replaceAll: replaceAll,
                treatAsRewrite: treatAsRewrite
            )
        }
        let updatedText = try EditFlowPerf.measure(
            EditFlowPerf.Stage.ApplyEdits.patchApply,
            EditFlowPerf.Dimensions(chunkCount: diffChunks.count)
        ) {
            try patchApplier.apply(
                chunks: diffChunks,
                to: originalText
            )
        }
        return (updatedText: updatedText, diffChunks: diffChunks)
    }

    private func applyBatch(
        edits: [ApplyEditsOperation],
        originalText: String,
        path: String,
        verbose: Bool,
        options: ApplyEditsExecutionOptions
    ) async throws -> ApplyEditsResult {
        guard !edits.isEmpty else {
            throw ApplyEditsError.invalidParams("edits array cannot be empty")
        }

        let fallback = ApplyEditsEscapeFallback()
        let resolved = fallback.resolveBatch(edits: edits, in: originalText)
        let effectiveEdits = resolved.edits

        if let literalResult = tryLiteralBatch(
            edits: effectiveEdits,
            originalText: originalText,
            path: path,
            verbose: verbose,
            options: options
        ) {
            return literalResult
        }

        return try await applyBatchDiff(
            edits: effectiveEdits,
            originalText: originalText,
            path: path,
            verbose: verbose,
            options: options
        )
    }

    private func applyBatchDiff(
        edits: [ApplyEditsOperation],
        originalText: String,
        path: String,
        verbose: Bool,
        options: ApplyEditsExecutionOptions
    ) async throws -> ApplyEditsResult {
        let preparation = prepareOriginal(for: originalText)
        let combinedSearch = edits.map(\.search).joined(separator: "\n")
        let combinedReplace = edits.map(\.replace).joined(separator: "\n")
        let tabPromotionEnabled = String.shouldPromoteLeadingEscapedTabs(
            path: path,
            searchRaw: combinedSearch.isEmpty ? nil : combinedSearch,
            replaceRaw: combinedReplace.isEmpty ? nil : combinedReplace
        )

        let editModels: [Edit] = edits.compactMap { edit in
            let searchLines = DiffEncodingUtils.encode(edit.search, usesSpaces: preparation.usesSpaces)
            let contentLines = DiffEncodingUtils.encode(edit.replace, usesSpaces: preparation.usesSpaces)
            let sanitizedSearch = String.promoteEscapedTabsInEncodedLines(searchLines, enabled: tabPromotionEnabled)
            let sanitizedContent = String.promoteEscapedTabsInEncodedLines(contentLines, enabled: tabPromotionEnabled)
            return Edit(search: sanitizedSearch, content: sanitizedContent, replaceAll: edit.replaceAll)
        }

        guard !editModels.isEmpty else {
            throw ApplyEditsError.invalidParams("no valid {search,content} pairs supplied")
        }

        var searchBlockFrequency: [String: Int] = [:]
        for edit in editModels {
            let key = edit.search.joined(separator: "\n")
            searchBlockFrequency[key, default: 0] += 1
        }
        let hasMultipleIdenticalBlocks = searchBlockFrequency.values.contains { $0 > 1 }
        let shouldCheckAmbiguity = !hasMultipleIdenticalBlocks

        let (chunks, outcomes, _) = try await EditFlowPerf.measure(
            EditFlowPerf.Stage.ApplyEdits.diffGeneration,
            EditFlowPerf.Dimensions(fileBytes: originalText.utf8.count, editCount: editModels.count)
        ) {
            try await DiffBatchGenerator.generate(
                originalLines: preparation.encoded,
                edits: editModels,
                precision: .high,
                mcpAmbiguityCheck: shouldCheckAmbiguity,
                tabPromotionEnabled: tabPromotionEnabled
            )
        }

        let applied = outcomes.count(where: { $0.status == "success" })
        if applied == 0 {
            return ApplyEditsResult(
                updatedText: originalText,
                diffChunks: [],
                unifiedDiff: nil,
                toolCardUnifiedDiff: nil,
                stats: nil,
                note: nil,
                fileCreated: false,
                fileOverwritten: false,
                editsRequested: editModels.count,
                editsApplied: 0,
                status: .failed,
                outcomes: outcomes
            )
        }

        let updatedText = try EditFlowPerf.measure(
            EditFlowPerf.Stage.ApplyEdits.patchApply,
            EditFlowPerf.Dimensions(chunkCount: chunks.count)
        ) {
            try patchApplier.apply(
                chunks: chunks,
                to: originalText
            )
        }

        let status: ApplyEditsStatus = applied == editModels.count ? .success : .partial
        return buildResult(
            originalText: originalText,
            updatedText: updatedText,
            diffChunks: chunks,
            note: nil,
            editsRequested: editModels.count,
            editsApplied: applied,
            status: status,
            outcomes: outcomes,
            path: path,
            verbose: verbose,
            options: options
        )
    }

    private func tryLiteralBatch(
        edits: [ApplyEditsOperation],
        originalText: String,
        path: String,
        verbose: Bool,
        options: ApplyEditsExecutionOptions
    ) -> ApplyEditsResult? {
        var newText = originalText
        var outcomes: [EditOutcome] = []
        var appliedCount = 0

        for (idx, edit) in edits.enumerated() {
            let matches = newText.ranges(of: edit.search)
            if edit.replaceAll {
                guard !matches.isEmpty else { return nil }
                newText = newText.replacingOccurrences(of: edit.search, with: edit.replace)
                outcomes.append(EditOutcome(index: idx, status: "success", error: nil))
                appliedCount += 1
            } else {
                guard matches.count == 1 else { return nil }
                newText.replaceSubrange(matches[0], with: edit.replace)
                outcomes.append(EditOutcome(index: idx, status: "success", error: nil))
                appliedCount += 1
            }
        }

        let preparation = prepareOriginal(for: originalText)
        let newLinesRaw = String.splitContentPreservingLineEndings(newText).0
        let desiredIndentationType = preparation.usesSpaces ? "s" : "t"
        let encodedNew = newLinesRaw.map {
            String.encodeIndentationWithConversion($0, desiredIndentationType: desiredIndentationType)
        }
        let chunks = EditFlowPerf.measure(
            EditFlowPerf.Stage.ApplyEdits.diffGeneration,
            EditFlowPerf.Dimensions(fileBytes: originalText.utf8.count, editCount: edits.count)
        ) {
            DiffGenerationUtility.generateRewriteDiff(
                fileContent: preparation.encoded,
                newContent: encodedNew
            )
        }

        return buildResult(
            originalText: originalText,
            updatedText: newText,
            diffChunks: chunks,
            note: "Applied via exact literal replacement",
            editsRequested: edits.count,
            editsApplied: appliedCount,
            status: .success,
            outcomes: verbose ? outcomes : nil,
            path: path,
            verbose: verbose,
            options: options
        )
    }

    private func buildResult(
        originalText: String,
        updatedText: String,
        diffChunks: [DiffChunk],
        note: String?,
        editsRequested: Int,
        editsApplied: Int,
        status: ApplyEditsStatus,
        outcomes: [EditOutcome]?,
        path: String,
        verbose: Bool,
        options: ApplyEditsExecutionOptions
    ) -> ApplyEditsResult {
        let filteredChunks = UnifiedDiffGenerator.removeWhitespaceOnlyChanges(from: diffChunks)
        let stats: ApplyEditsStats?
        if filteredChunks.isEmpty {
            stats = nil
        } else {
            let raw = UnifiedDiffGenerator.stats(from: filteredChunks)
            stats = ApplyEditsStats(linesChanged: raw.linesChanged, chunks: raw.chunks)
        }

        let unifiedDiff: String? = if verbose {
            unifiedDiffRenderer.render(filePath: path, chunks: filteredChunks)
        } else {
            nil
        }

        let toolCardUnifiedDiff: String? = if options.includeToolCardUnifiedDiff {
            EditFlowPerf.measure(
                EditFlowPerf.Stage.ApplyEdits.toolCardDiff,
                EditFlowPerf.Dimensions(
                    fileBytes: originalText.utf8.count,
                    chunkCount: filteredChunks.count
                )
            ) {
                buildToolCardUnifiedDiff(
                    path: path,
                    originalText: originalText,
                    updatedText: updatedText,
                    fallbackChunks: filteredChunks
                )
            }
        } else {
            nil
        }

        return ApplyEditsResult(
            updatedText: updatedText,
            diffChunks: filteredChunks,
            unifiedDiff: unifiedDiff,
            toolCardUnifiedDiff: toolCardUnifiedDiff,
            stats: stats,
            note: note,
            fileCreated: false,
            fileOverwritten: false,
            editsRequested: editsRequested,
            editsApplied: editsApplied,
            status: status,
            outcomes: outcomes
        )
    }

    private func buildToolCardUnifiedDiff(
        path: String,
        originalText: String,
        updatedText: String,
        fallbackChunks: [DiffChunk]
    ) -> String? {
        guard !fallbackChunks.isEmpty else { return nil }

        let contextLines = 2
        let oldLines = String.splitContentPreservingLineEndings(originalText).0
        let newLines = String.splitContentPreservingLineEndings(updatedText).0
        let contextualChunks = UnifiedDiffGenerator.removeWhitespaceOnlyChanges(
            from: UnifiedDiffGenerator.diffChunks(
                oldLines: oldLines,
                newLines: newLines,
                context: contextLines
            )
        )

        if !contextualChunks.isEmpty {
            return UnifiedDiffGenerator.build(
                filePath: path,
                chunks: contextualChunks,
                context: contextLines
            )
        }

        let decodedFallbackChunks = fallbackChunks.map { $0.withDecodedIndentation() }
        return UnifiedDiffGenerator.buildFromEditChunks(
            filePath: path,
            chunks: decodedFallbackChunks,
            startLineBase: .oneBased
        )
    }

    private func prepareOriginal(for originalText: String) -> (encoded: [String], usesSpaces: Bool) {
        let (lines, _) = String.splitContentPreservingLineEndings(originalText)
        let (indentType, _) = String.detectIndentationTypeFromLines(lines)
        let encoded = lines.map {
            String.encodeIndentationWithConversion($0, desiredIndentationType: indentType)
        }
        return (encoded, indentType == "s")
    }
}

package struct DefaultDiffChunkGenerator: DiffChunkGenerator {
    package init() {}

    package func makeDiffChunks(
        filePath: String,
        originalText: String,
        search: String?,
        replace: String,
        replaceAll: Bool,
        treatAsRewrite: Bool
    ) async throws -> [DiffChunk] {
        let preparation = prepareOriginal(for: originalText)
        let searchRaw = search ?? ""
        return try await buildDiffChunks(
            original: preparation.encoded,
            originalText: originalText,
            searchRaw: searchRaw,
            replRaw: replace,
            usesSpaces: preparation.usesSpaces,
            replaceAll: replaceAll,
            treatAsRewrite: treatAsRewrite,
            filePath: filePath
        )
    }

    private func prepareOriginal(for originalText: String) -> (encoded: [String], usesSpaces: Bool) {
        let (lines, _) = String.splitContentPreservingLineEndings(originalText)
        let (indentType, _) = String.detectIndentationTypeFromLines(lines)
        let encoded = lines.map {
            String.encodeIndentationWithConversion($0, desiredIndentationType: indentType)
        }
        return (encoded, indentType == "s")
    }

    private func buildDiffChunks(
        original: [String],
        originalText: String,
        searchRaw: String,
        replRaw: String,
        usesSpaces: Bool,
        replaceAll: Bool,
        treatAsRewrite: Bool,
        filePath: String
    ) async throws -> [DiffChunk] {
        if !treatAsRewrite, !searchRaw.isEmpty {
            let literalMatches = originalText.ranges(of: searchRaw)
            if !literalMatches.isEmpty {
                var newText = originalText

                if replaceAll {
                    newText = newText.replacingOccurrences(of: searchRaw, with: replRaw)
                } else {
                    if literalMatches.count > 1 {
                        let lineList = literalMatches
                            .map { lineAndColumn(of: $0.lowerBound, in: originalText).0 }
                            .sorted()
                            .map(String.init)
                            .joined(separator: ", ")
                        throw ApplyEditsError.invalidParams(
                            "Search text matches multiple locations (lines \(lineList)). Please make the search more specific or use replace_all=true."
                        )
                    }
                    newText.replaceSubrange(literalMatches[0], with: replRaw)
                }

                let newLinesRaw = String.splitContentPreservingLineEndings(newText).0
                let desiredIndentationType = usesSpaces ? "s" : "t"
                let encodedNew = newLinesRaw.map {
                    String.encodeIndentationWithConversion($0, desiredIndentationType: desiredIndentationType)
                }
                return DiffGenerationUtility.generateRewriteDiff(fileContent: original, newContent: encodedNew)
            }

            if replaceAll {
                throw ApplyEditsError.invalidParams(
                    "search text not found in file (no literal matches for replace_all)"
                )
            }
        }

        let encodedSearch = ApplyEditsDiffParserUtils.splitContentToLines(searchRaw, usesSpaces)
        let encodedNew = ApplyEditsDiffParserUtils.splitContentToLines(replRaw, usesSpaces)

        let tabPromotionEnabled = String.shouldPromoteLeadingEscapedTabs(
            path: filePath,
            searchRaw: searchRaw,
            replaceRaw: replRaw
        )
        let sanitizedSearch = String.promoteEscapedTabsInEncodedLines(encodedSearch, enabled: tabPromotionEnabled)
        let sanitizedNew = String.promoteEscapedTabsInEncodedLines(encodedNew, enabled: tabPromotionEnabled)

        let action: FileAction = (treatAsRewrite || sanitizedSearch.isEmpty) ? .rewrite : .modify

        do {
            return try await DiffGenerationUtility.generateDiff(
                fileContent: original,
                lineIndexMap: nil,
                startSelector: nil,
                endSelector: nil,
                searchBlock: sanitizedSearch.isEmpty ? nil : sanitizedSearch,
                newContent: sanitizedNew,
                action: action,
                diffPrecision: .high,
                searchStartLine: 0,
                mcpAmbiguityCheck: !replaceAll,
                replaceAll: replaceAll,
                tabPromotionEnabled: tabPromotionEnabled
            )
        } catch let err as DiffGenerationError {
            switch err {
            case .noMatchFound:
                let message = replaceAll
                    ? "search block not found in file (no matches for replace_all)"
                    : "search block not found in file"
                throw ApplyEditsError.invalidParams(message)
            case let .ambiguousMatch(message):
                let resolved = replaceAll
                    ? "unexpected ambiguity error with replace_all=true: \(message)"
                    : message
                throw ApplyEditsError.invalidParams(resolved)
            default:
                throw ApplyEditsError.internalError("diff generation failed: \(err.localizedDescription)")
            }
        } catch {
            throw ApplyEditsError.internalError("diff generation failed: \(error.localizedDescription)")
        }
    }

    private func lineAndColumn(of index: String.Index, in text: String) -> (Int, Int) {
        let targetOffset = text.distance(from: text.startIndex, to: index)
        let components = String.splitContentPreservingAllLineEndings(text)

        var cumulative = 0
        for (idx, pair) in components.enumerated() {
            let partLen = pair.line.count + pair.ending.count
            if targetOffset < cumulative + partLen {
                let column = targetOffset - cumulative + 1
                return (idx + 1, column)
            }
            cumulative += partLen
        }
        return (components.count, 1)
    }
}

package struct DefaultDiffChunkApplier: DiffChunkApplier {
    package init() {}

    package func apply(chunks: [DiffChunk], to originalText: String) throws -> String {
        guard !chunks.isEmpty else {
            throw ApplyEditsError.internalError("diff generation produced no changes.")
        }

        do {
            return try DiffChunkTextApplier.apply(chunks: chunks, to: originalText)
        } catch {
            throw ApplyEditsError.internalError("diff application failed: \(error.localizedDescription)")
        }
    }
}

package struct DefaultUnifiedDiffRenderer: UnifiedDiffRendering {
    package init() {}

    package func render(filePath: String, chunks: [DiffChunk]) -> String {
        let decodedChunks = chunks.map { $0.withDecodedIndentation() }
        return UnifiedDiffGenerator.buildFromEditChunks(
            filePath: filePath,
            chunks: decodedChunks,
            startLineBase: .zeroBased
        )
    }
}
