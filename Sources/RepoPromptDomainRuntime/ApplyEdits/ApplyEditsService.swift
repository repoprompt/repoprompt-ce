import Foundation

package struct ApplyEditsService {
    package let engine: ApplyEditsEngine
    package let host: FileEditHost

    package init(engine: ApplyEditsEngine, host: FileEditHost) {
        self.engine = engine
        self.host = host
    }

    package func run(
        _ request: ApplyEditsRequest,
        options: ApplyEditsExecutionOptions = .default
    ) async throws -> ApplyEditsResult {
        let state = EditFlowPerf.begin(
            EditFlowPerf.Stage.ApplyEdits.serviceRun,
            EditFlowPerf.Dimensions(editCount: request.editCount, includesToolCardDiff: options.includeToolCardUnifiedDiff)
        )
        defer { EditFlowPerf.end(EditFlowPerf.Stage.ApplyEdits.serviceRun, state) }

        let previewResult = try await preview(request, options: options)
        let result = previewResult.result

        if result.editsApplied > 0 {
            try await EditFlowPerf.measure(
                EditFlowPerf.Stage.ApplyEdits.hostWrite,
                EditFlowPerf.Dimensions(fileBytes: result.updatedText.utf8.count, appliedCount: result.editsApplied)
            ) {
                try await host.writeText(
                    path: request.path,
                    content: result.updatedText,
                    overwrite: previewResult.exists
                )
            }
        }

        return result.withFileMetadata(created: !previewResult.exists, overwritten: false)
    }

    package func preview(
        _ request: ApplyEditsRequest,
        options: ApplyEditsExecutionOptions = .default
    ) async throws -> (exists: Bool, originalText: String?, result: ApplyEditsResult) {
        let state = EditFlowPerf.begin(
            EditFlowPerf.Stage.ApplyEdits.servicePreview,
            EditFlowPerf.Dimensions(editCount: request.editCount, includesToolCardDiff: options.includeToolCardUnifiedDiff)
        )
        defer { EditFlowPerf.end(EditFlowPerf.Stage.ApplyEdits.servicePreview, state) }

        let exists = await host.fileExists(path: request.path)

        if !exists {
            switch request.mode {
            case let .rewrite(newText, onMissing):
                guard onMissing == .create else {
                    throw ApplyEditsError.invalidParams(
                        "File '\(request.path)' does not exist. Use `on_missing=\"create\"` with `rewrite`, or create the file first via `file_actions` action=\"create\"."
                    )
                }
                let result = buildCreateResult(text: newText, path: request.path, verbose: request.verbose, options: options)
                return (exists: false, originalText: nil, result: result)
            default:
                throw ApplyEditsError.invalidParams(
                    "File '\(request.path)' does not exist. Use `on_missing=\"create\"` with `rewrite`, or create the file first via `file_actions` action=\"create\"."
                )
            }
        }

        let originalText = try await EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.hostRead) {
            try await host.readText(path: request.path)
        }
        EditFlowPerf.event(
            EditFlowPerf.Stage.ApplyEdits.hostRead,
            EditFlowPerf.Dimensions(fileBytes: originalText.utf8.count)
        )
        let result = try await engine.apply(request: request, to: originalText, options: options)
        return (exists: true, originalText: originalText, result: result)
    }

    private func buildCreateResult(
        text: String,
        path: String,
        verbose: Bool,
        options: ApplyEditsExecutionOptions
    ) -> ApplyEditsResult {
        let newLines = String.splitContentPreservingLineEndings(text).0
        let diffChunks = UnifiedDiffGenerator.diffChunks(oldLines: [], newLines: newLines)
        let stats: ApplyEditsStats? = diffChunks.isEmpty
            ? nil
            : {
                let raw = UnifiedDiffGenerator.stats(from: diffChunks)
                return ApplyEditsStats(linesChanged: raw.linesChanged, chunks: raw.chunks)
            }()

        let unifiedDiff: String?
        if verbose {
            let decodedChunks = diffChunks.map { $0.withDecodedIndentation() }
            unifiedDiff = UnifiedDiffGenerator.buildFromEditChunks(
                filePath: path,
                chunks: decodedChunks,
                startLineBase: .oneBased
            )
        } else {
            unifiedDiff = nil
        }

        let toolCardUnifiedDiff: String? = if options.includeToolCardUnifiedDiff {
            EditFlowPerf.measure(
                EditFlowPerf.Stage.ApplyEdits.toolCardDiff,
                EditFlowPerf.Dimensions(lineCount: newLines.count)
            ) {
                UnifiedDiffGenerator.build(
                    filePath: path,
                    chunks: UnifiedDiffGenerator.diffChunks(oldLines: [], newLines: newLines, context: 2),
                    context: 2
                )
            }
        } else {
            nil
        }

        return ApplyEditsResult(
            updatedText: text,
            diffChunks: diffChunks,
            unifiedDiff: unifiedDiff,
            toolCardUnifiedDiff: toolCardUnifiedDiff,
            stats: stats,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            editsRequested: 1,
            editsApplied: 1,
            status: .success,
            outcomes: nil
        )
    }
}
