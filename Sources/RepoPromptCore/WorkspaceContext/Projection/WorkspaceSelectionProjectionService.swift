import Foundation

package enum WorkspaceSelectionProjectionService {
    private struct AlternateState {
        let mode: WorkspaceSelectionProjection.RenderMode
        let tokens: Int
        let codemapOrigin: WorkspaceSelectionProjection.CodemapOrigin?
    }

    package static func project(
        _ request: WorkspaceSelectionProjectionRequest
    ) -> WorkspaceSelectionProjection {
        var files: [WorkspaceSelectionProjection.File] = []
        var slices: [WorkspaceSelectionProjection.Slice] = []
        files.reserveCapacity(request.entries.count)
        slices.reserveCapacity(request.entries.count)

        var fullCount = 0
        var sliceCount = 0
        var codemapCount = 0
        var fullTokens = 0
        var sliceTokens = 0
        var codemapTokens = 0
        var alternateContentTokens = 0
        var alternateCodemapTokens = 0

        for entry in request.entries {
            let mode = renderMode(for: entry.mode)
            let origin = codemapOrigin(
                for: entry.mode,
                codeMapUsage: request.codeMapUsage,
                codemapAutoEnabled: request.codemapAutoEnabled
            )

            switch mode {
            case .full:
                fullCount += 1
                fullTokens += entry.tokens.displayTokens
            case .slice:
                sliceCount += 1
                sliceTokens += entry.tokens.displayTokens
                slices.append(WorkspaceSelectionProjection.Slice(
                    file: entry.file,
                    metadata: entry.metadata,
                    ranges: entry.ranges
                ))
            case .codemap:
                codemapCount += 1
                codemapTokens += entry.tokens.displayTokens
            case .hidden:
                break
            }

            let alternateState: AlternateState? = request.alternatePolicy.map {
                makeAlternateState(
                    for: entry,
                    baseMode: mode,
                    baseOrigin: origin,
                    codeMapUsage: $0.codeMapUsage
                )
            }
            if let alternateState {
                switch alternateState.mode {
                case .full, .slice:
                    alternateContentTokens += alternateState.tokens
                case .codemap:
                    alternateCodemapTokens += alternateState.tokens
                case .hidden:
                    break
                }
            }

            let alternate = alternateState.flatMap { state -> WorkspaceSelectionProjection.FileAlternate? in
                guard state.mode != mode || state.tokens != entry.tokens.displayTokens else { return nil }
                return WorkspaceSelectionProjection.FileAlternate(
                    mode: state.mode,
                    tokens: state.tokens,
                    codemapOrigin: state.codemapOrigin
                )
            }
            files.append(WorkspaceSelectionProjection.File(
                file: entry.file,
                metadata: entry.metadata,
                mode: mode,
                ranges: mode == .slice ? entry.ranges : nil,
                tokens: entry.tokens.displayTokens,
                codemapAvailable: entry.codemapAvailable,
                codemapOrigin: origin,
                alternate: alternate
            ))
        }

        let summary = WorkspaceSelectionProjection.Summary(
            fullCount: fullCount,
            sliceCount: sliceCount,
            codemapCount: codemapCount,
            fullTokens: fullTokens,
            sliceTokens: sliceTokens,
            codemapTokens: codemapTokens
        )
        let alternate = request.alternatePolicy.map { policy in
            let totalTokens = alternateContentTokens + alternateCodemapTokens
            let includedTotalTokens: Int = if policy.includeFiles {
                totalTokens
            } else if policy.codeMapUsage == .none {
                0
            } else {
                summary.codemapTokens
            }
            return WorkspaceSelectionProjection.Alternate(
                codeMapUsage: policy.codeMapUsage,
                includesFiles: policy.includeFiles,
                contentTokens: alternateContentTokens,
                codemapTokens: alternateCodemapTokens,
                totalTokens: totalTokens,
                includedTotalTokens: includedTotalTokens
            )
        }

        return WorkspaceSelectionProjection(
            files: files,
            slices: slices,
            summary: summary,
            invalidPaths: request.missingPaths + request.invalidPaths,
            codeMapUsage: request.codeMapUsage,
            codemapAutoEnabled: request.codemapAutoEnabled,
            alternate: alternate
        )
    }

    private static func renderMode(
        for mode: WorkspaceSelectionProjection.BaseMode
    ) -> WorkspaceSelectionProjection.RenderMode {
        switch mode {
        case .full:
            .full
        case .slice:
            .slice
        case .codemap:
            .codemap
        }
    }

    private static func codemapOrigin(
        for mode: WorkspaceSelectionProjection.BaseMode,
        codeMapUsage: CodeMapUsage,
        codemapAutoEnabled: Bool
    ) -> WorkspaceSelectionProjection.CodemapOrigin? {
        guard mode == .codemap else { return nil }
        switch codeMapUsage {
        case .selected:
            return .selectedMode
        case .complete:
            return .auto
        case .auto:
            return codemapAutoEnabled ? .auto : .manual
        case .none:
            return .manual
        }
    }

    private static func makeAlternateState(
        for entry: WorkspaceSelectionProjectionRequest.Entry,
        baseMode: WorkspaceSelectionProjection.RenderMode,
        baseOrigin: WorkspaceSelectionProjection.CodemapOrigin?,
        codeMapUsage: CodeMapUsage
    ) -> AlternateState {
        switch codeMapUsage {
        case .auto:
            return AlternateState(
                mode: baseMode,
                tokens: entry.tokens.displayTokens,
                codemapOrigin: baseOrigin
            )
        case .selected:
            if baseMode == .codemap {
                return AlternateState(mode: .hidden, tokens: 0, codemapOrigin: nil)
            }
            if entry.codemapAvailable {
                return AlternateState(
                    mode: .codemap,
                    tokens: entry.tokens.codemapTokens,
                    codemapOrigin: .selectedMode
                )
            }
            return AlternateState(
                mode: baseMode,
                tokens: entry.tokens.displayTokens,
                codemapOrigin: baseOrigin
            )
        case .complete:
            if baseMode != .codemap, entry.codemapAvailable {
                return AlternateState(
                    mode: .codemap,
                    tokens: entry.tokens.codemapTokens,
                    codemapOrigin: .completeMode
                )
            }
            return AlternateState(
                mode: baseMode,
                tokens: entry.tokens.displayTokens,
                codemapOrigin: baseOrigin
            )
        case .none:
            if baseMode == .codemap {
                return AlternateState(mode: .hidden, tokens: 0, codemapOrigin: nil)
            }
            return AlternateState(
                mode: baseMode,
                tokens: entry.tokens.displayTokens,
                codemapOrigin: baseOrigin
            )
        }
    }
}
