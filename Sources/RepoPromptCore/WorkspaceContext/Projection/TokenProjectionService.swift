package enum TokenProjectionService {
    package struct WorkspaceNonFileComponents: Equatable {
        package let prompt: Int
        package let fileTree: Int
        package let meta: Int
        package let git: Int
        package let other: Int

        package init(
            prompt: Int,
            fileTree: Int,
            meta: Int,
            git: Int,
            other: Int = 0
        ) {
            self.prompt = prompt
            self.fileTree = fileTree
            self.meta = meta
            self.git = git
            self.other = other
        }

        package init(breakdown: TokenComponentBreakdown) {
            self.init(
                prompt: breakdown.promptDisplay,
                fileTree: breakdown.fileTree,
                meta: breakdown.instructions,
                git: breakdown.gitDiff,
                other: breakdown.other
            )
        }
    }

    package struct ActiveLiveWorkspaceInput: Equatable {
        package let reportedTotal: Int
        package let prompt: Int
        package let fileTree: Int
        package let meta: Int
        package let git: Int
        package let requestedFileTreeEstimate: Int?

        package init(
            reportedTotal: Int,
            prompt: Int,
            fileTree: Int,
            meta: Int,
            git: Int,
            requestedFileTreeEstimate: Int? = nil
        ) {
            self.reportedTotal = reportedTotal
            self.prompt = prompt
            self.fileTree = fileTree
            self.meta = meta
            self.git = git
            self.requestedFileTreeEstimate = requestedFileTreeEstimate
        }
    }

    package struct WorkspaceViews: Equatable {
        package let normalized: TokenProjection
        package let userConfigured: TokenProjection?

        package init(normalized: TokenProjection, userConfigured: TokenProjection?) {
            self.normalized = normalized
            self.userConfigured = userConfigured
        }
    }

    package static func componentEstimate(
        view: TokenProjection.View,
        scope: TokenProjection.Scope,
        source: TokenProjection.Source,
        components: TokenProjection.Components
    ) -> TokenProjection {
        TokenProjection(
            provenance: .init(
                view: view,
                scope: scope,
                source: source,
                basis: .componentEstimate
            ),
            components: components,
            total: componentTotal(components)
        )
    }

    package static func selectionProjection(
        from selection: WorkspaceSelectionProjection,
        view: TokenProjection.View,
        source: TokenProjection.Source
    ) -> TokenProjection? {
        let components: TokenProjection.Components
        switch view {
        case .normalized:
            components = .init(
                files: selection.summary.totalTokens,
                filesContent: selection.summary.fullTokens + selection.summary.sliceTokens,
                codemaps: selection.summary.codemapTokens
            )
        case .userConfigured:
            guard let alternate = selection.alternate else { return nil }
            components = .init(
                files: alternate.includedTotalTokens,
                filesContent: alternate.includesFiles ? alternate.contentTokens : 0,
                codemaps: alternate.includesFiles ? alternate.codemapTokens : alternate.includedTotalTokens
            )
        }
        return componentEstimate(
            view: view,
            scope: .selection,
            source: source,
            components: components
        )
    }

    package static func workspaceComponentEstimates(
        from selection: WorkspaceSelectionProjection,
        source: TokenProjection.Source,
        nonFile: WorkspaceNonFileComponents
    ) -> WorkspaceViews {
        let normalizedSelection = normalizedSelectionProjection(from: selection, source: source)
        let normalized = workspaceComponentEstimate(
            selection: normalizedSelection,
            view: .normalized,
            source: source,
            nonFile: nonFile
        )
        let userConfigured = selectionProjection(
            from: selection,
            view: .userConfigured,
            source: source
        ).map {
            workspaceComponentEstimate(
                selection: $0,
                view: .userConfigured,
                source: source,
                nonFile: nonFile
            )
        }
        return WorkspaceViews(normalized: normalized, userConfigured: userConfigured)
    }

    package static func activeLiveWorkspaceEstimates(
        from selection: WorkspaceSelectionProjection,
        input: ActiveLiveWorkspaceInput
    ) -> WorkspaceViews {
        let source = TokenProjection.Source.activeLive
        let normalizedSelection = normalizedSelectionProjection(from: selection, source: source)
        let normalizedFiles = normalizedSelection.total
        let tree = if input.fileTree == 0, let requested = input.requestedFileTreeEstimate, requested > 0 {
            requested
        } else {
            input.fileTree
        }
        let normalizedComponentSum = input.prompt + normalizedFiles + tree + input.meta + input.git
        let normalizedTotal = max(input.reportedTotal, normalizedComponentSum)
        let normalizedOther = max(normalizedTotal - normalizedComponentSum, 0)
        let normalized = TokenProjection(
            provenance: .init(
                view: .normalized,
                scope: .workspace,
                source: source,
                basis: .componentEstimate
            ),
            components: .init(
                files: normalizedFiles,
                prompt: input.prompt,
                fileTree: tree,
                meta: input.meta,
                git: input.git,
                other: normalizedOther,
                filesContent: positiveOptional(normalizedSelection.components.filesContent),
                codemaps: positiveOptional(normalizedSelection.components.codemaps)
            ),
            total: normalizedTotal
        )

        let userConfigured = selectionProjection(
            from: selection,
            view: .userConfigured,
            source: source
        ).map { userSelection in
            let userFiles = userSelection.total
            let userComponentSum = input.prompt + userFiles + tree + input.meta + input.git
            let replacementTotal = normalizedTotal - normalizedFiles + userFiles
            let userTotal = max(userComponentSum, replacementTotal)
            return TokenProjection(
                provenance: .init(
                    view: .userConfigured,
                    scope: .workspace,
                    source: source,
                    basis: .componentEstimate
                ),
                components: .init(
                    files: userFiles,
                    prompt: input.prompt,
                    fileTree: tree,
                    meta: input.meta,
                    git: input.git,
                    other: max(userTotal - userComponentSum, 0),
                    filesContent: positiveOptional(userSelection.components.filesContent),
                    codemaps: positiveOptional(userSelection.components.codemaps)
                ),
                total: userTotal
            )
        }
        return WorkspaceViews(normalized: normalized, userConfigured: userConfigured)
    }

    /// Estimates the complete emitted payload; the basis is exact, while tokenization remains heuristic.
    package static func exactRenderedPayload(
        _ renderedText: String,
        view: TokenProjection.View,
        source: TokenProjection.Source
    ) -> TokenProjection {
        TokenProjection(
            provenance: .init(
                view: view,
                scope: .export,
                source: source,
                basis: .exactRenderedPayload
            ),
            components: .init(),
            total: TokenCalculationService.estimateTokens(for: renderedText)
        )
    }

    private static func workspaceComponentEstimate(
        selection: TokenProjection,
        view: TokenProjection.View,
        source: TokenProjection.Source,
        nonFile: WorkspaceNonFileComponents
    ) -> TokenProjection {
        let components = TokenProjection.Components(
            files: selection.components.files,
            prompt: positiveOptional(nonFile.prompt),
            fileTree: positiveOptional(nonFile.fileTree),
            meta: positiveOptional(nonFile.meta),
            git: positiveOptional(nonFile.git),
            other: positiveOptional(nonFile.other),
            filesContent: positiveOptional(selection.components.filesContent),
            codemaps: positiveOptional(selection.components.codemaps)
        )
        return componentEstimate(
            view: view,
            scope: .workspace,
            source: source,
            components: components
        )
    }

    private static func normalizedSelectionProjection(
        from selection: WorkspaceSelectionProjection,
        source: TokenProjection.Source
    ) -> TokenProjection {
        componentEstimate(
            view: .normalized,
            scope: .selection,
            source: source,
            components: .init(
                files: selection.summary.totalTokens,
                filesContent: selection.summary.fullTokens + selection.summary.sliceTokens,
                codemaps: selection.summary.codemapTokens
            )
        )
    }

    private static func componentTotal(_ components: TokenProjection.Components) -> Int {
        let fileTotal = components.files ?? 0
        let promptTotal = components.prompt ?? 0
        let treeTotal = components.fileTree ?? 0
        let metaTotal = components.meta ?? 0
        let gitTotal = components.git ?? 0
        let otherTotal = components.other ?? 0
        return fileTotal + promptTotal + treeTotal + metaTotal + gitTotal + otherTotal
    }

    private static func positiveOptional(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func positiveOptional(_ value: Int) -> Int? {
        value > 0 ? value : nil
    }
}
