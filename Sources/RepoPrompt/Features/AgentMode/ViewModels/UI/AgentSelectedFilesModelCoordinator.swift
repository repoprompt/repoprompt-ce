import Foundation

struct AgentSelectedFilesModelIdentity: Equatable, Hashable {
    let exportContextIdentity: AgentContextExportIdentity
    let filePathDisplay: FilePathDisplay
    let codeMapUsage: CodeMapUsage
}

struct AgentSelectedFilesModelRequest {
    let identity: AgentSelectedFilesModelIdentity
    let source: AgentContextExportSource
    let store: WorkspaceFileContextStore
    let filePathDisplay: FilePathDisplay
    let codeMapUsage: CodeMapUsage
    let entryMetricsSnapshot: PromptContextEntryMetricsSnapshot?
}

enum AgentSelectedFilesRequestMetricsSnapshotResolver {
    @MainActor
    static func activeTokenMetricsSnapshot(
        source: AgentContextExportSource,
        promptManager: PromptViewModel,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay
    ) -> PromptContextEntryMetricsSnapshot? {
        let published = promptManager.tokenCountingViewModel.latestPublishedTokenSnapshot(
            for: source.selection,
            scheduleRefreshIfNeeded: false
        )
        return activeTokenMetricsSnapshot(
            source: source,
            activeComposeTabID: promptManager.activeComposeTabID,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            published: published
        )
    }

    @MainActor
    static func activeTokenMetricsSnapshot(
        source: AgentContextExportSource,
        activeComposeTabID: UUID?,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay,
        published: TokenCountingViewModel.PublishedTokenSnapshot
    ) -> PromptContextEntryMetricsSnapshot? {
        guard !source.hasWorktreeBindings,
              source.activeAgentSessionID == nil,
              source.tabID == activeComposeTabID,
              published.isComplete,
              !published.isStale,
              !published.refreshPending,
              published.codeMapUsage == codeMapUsage,
              published.filePathDisplay == filePathDisplay
        else { return nil }
        return published.entryMetricsSnapshot
    }
}

struct AgentContextSelectionDisplayText: Equatable {
    let compact: String
    let detailed: String
}

enum AgentContextCountReadiness: Equatable {
    case known(Int)
    case unknown
}

struct AgentContextFileCodemapCountReadiness: Equatable {
    let file: AgentContextCountReadiness
    let codemap: AgentContextCountReadiness
}

struct AgentContextFileCodemapCountSummary: Equatable {
    let fileCount: Int
    let codemapCount: Int
    let sliceRangeCount: Int

    static func intent(from summary: AgentContextSelectionSummary) -> AgentContextFileCodemapCountSummary {
        AgentContextFileCodemapCountSummary(
            fileCount: summary.fullFileCount + summary.slicedFileCount,
            codemapCount: summary.codemapFileCount,
            sliceRangeCount: summary.sliceRangeCount
        )
    }

    static func selectionDisplayText(from summary: AgentContextSelectionSummary) -> AgentContextSelectionDisplayText {
        guard summary.codemapFileCount > 0 else {
            return AgentContextSelectionDisplayText(compact: summary.compactText, detailed: summary.headlineText)
        }
        let fileCodemapSummary = intent(from: summary)
        return AgentContextSelectionDisplayText(
            compact: fileCodemapSummary.headlineText,
            detailed: fileCodemapSummary.headlineText
        )
    }

    var headlineText: String {
        var parts: [String] = []
        if fileCount > 0 || codemapCount == 0 {
            parts.append("\(fileCount) file\(fileCount == 1 ? "" : "s")")
        }
        if codemapCount > 0 {
            parts.append("\(codemapCount) codemap\(codemapCount == 1 ? "" : "s")")
        }
        if sliceRangeCount > 0 {
            parts.append("\(sliceRangeCount) slice\(sliceRangeCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

struct AgentSelectedFilesRowSplit: Equatable {
    let rows: [AgentContextExportRow]
    let fileRows: [AgentContextExportRow]
    let codemapRows: [AgentContextExportRow]
    let fileCodemapCountSummary: AgentContextFileCodemapCountSummary

    static let empty = AgentSelectedFilesRowSplit(rows: [])

    init(rows: [AgentContextExportRow]) {
        self.rows = rows
        var fileRows: [AgentContextExportRow] = []
        var codemapRows: [AgentContextExportRow] = []
        var sliceRangeCount = 0
        fileRows.reserveCapacity(rows.count)
        codemapRows.reserveCapacity(rows.count)
        for row in rows {
            if row.kind == .codemap {
                codemapRows.append(row)
            } else {
                fileRows.append(row)
                sliceRangeCount += row.lineRanges?.count ?? 0
            }
        }
        self.fileRows = fileRows
        self.codemapRows = codemapRows
        fileCodemapCountSummary = AgentContextFileCodemapCountSummary(
            fileCount: fileRows.count,
            codemapCount: codemapRows.count,
            sliceRangeCount: sliceRangeCount
        )
    }
}

enum AgentSelectedFilesRefreshOutcome: Equatable {
    case started
    case skippedLoaded
    case skippedLoading
}

struct AgentSelectedFilesModelDebugStats: Equatable {
    var refreshRequests = 0
    var resolverStarts = 0
    var resolverCompletions = 0
    var skippedLoaded = 0
    var skippedLoading = 0
    var cancellations = 0
    var staleResultsIgnored = 0
}

struct AgentSelectedFilesModelState: Equatable {
    var model: AgentContextExportModel?
    var rowSplit: AgentSelectedFilesRowSplit
    var isLoading: Bool
    var canMutateDisplayedModel: Bool

    static let empty = AgentSelectedFilesModelState(
        model: nil,
        rowSplit: .empty,
        isLoading: false,
        canMutateDisplayedModel: false
    )
}

@MainActor
final class AgentSelectedFilesModelCoordinator: ObservableObject {
    typealias ResolveInterimFileRows = (AgentContextExportModel) async -> Void
    typealias ResolveModel = (
        AgentSelectedFilesModelRequest,
        ResolveInterimFileRows?
    ) async throws -> AgentContextExportModel

    @Published private var state: AgentSelectedFilesModelState = .empty
    private(set) var debugStats = AgentSelectedFilesModelDebugStats()

    var model: AgentContextExportModel? {
        state.model
    }

    var rowSplit: AgentSelectedFilesRowSplit {
        state.rowSplit
    }

    var isLoading: Bool {
        state.isLoading
    }

    var canMutateDisplayedModel: Bool {
        state.canMutateDisplayedModel
    }

    func displayedModelMatches(_ identity: AgentSelectedFilesModelIdentity) -> Bool {
        displayedIdentity == identity && model != nil
    }

    func completedModelMatches(_ identity: AgentSelectedFilesModelIdentity) -> Bool {
        completedDisplayedModelMatches(identity)
    }

    func loadedFileCodemapCountSummary(
        for identity: AgentSelectedFilesModelIdentity
    ) -> AgentContextFileCodemapCountSummary? {
        guard completedModelMatches(identity) else { return nil }
        return rowSplit.fileCodemapCountSummary
    }

    func displayedFileCodemapCountReadiness(
        for identity: AgentSelectedFilesModelIdentity
    ) -> AgentContextFileCodemapCountReadiness? {
        guard displayedModelMatches(identity) else { return nil }
        let codemapReadiness: AgentContextCountReadiness = if loadedIdentity == identity,
                                                              let completedSnapshot = completedCountSnapshots[identity]
        {
            .known(completedSnapshot.codemapCount)
        } else if Self.codemapCountIsStableBeforeCompletion(identity) {
            .known(rowSplit.codemapRows.count)
        } else {
            .unknown
        }
        return AgentContextFileCodemapCountReadiness(
            file: .known(rowSplit.fileRows.count),
            codemap: codemapReadiness
        )
    }

    static func unresolvedFileCodemapCountReadiness(
        for identity: AgentSelectedFilesModelIdentity,
        summary: AgentContextFileCodemapCountSummary
    ) -> AgentContextFileCodemapCountReadiness {
        let fileReadiness: AgentContextCountReadiness = switch identity.codeMapUsage {
        case .selected:
            .unknown
        case .auto, .complete, .none:
            .known(summary.fileCount)
        }
        let codemapReadiness: AgentContextCountReadiness = if codemapCountIsStableBeforeCompletion(identity) {
            .known(0)
        } else {
            .unknown
        }
        return AgentContextFileCodemapCountReadiness(file: fileReadiness, codemap: codemapReadiness)
    }

    private let resolver: ResolveModel
    private var loadedIdentity: AgentSelectedFilesModelIdentity?
    private var loadingIdentity: AgentSelectedFilesModelIdentity?
    private var displayedIdentity: AgentSelectedFilesModelIdentity?
    private var refreshID: UUID?

    private func completedDisplayedModelMatches(_ identity: AgentSelectedFilesModelIdentity) -> Bool {
        loadedIdentity == identity &&
            displayedIdentity == identity &&
            model != nil &&
            loadingIdentity == nil
    }

    private var displayedModelIsMutable: Bool {
        guard let displayedIdentity else { return false }
        return completedDisplayedModelMatches(displayedIdentity)
    }

    private var refreshTask: Task<Void, Never>?
    private let cachedModelLimit = 5
    private var cachedModels: [AgentSelectedFilesModelIdentity: AgentContextExportModel] = [:]
    private var cachedModelOrder: [AgentSelectedFilesModelIdentity] = []
    private var completedCountSnapshots: [AgentSelectedFilesModelIdentity: AgentContextFileCodemapCountSummary] = [:]

    private struct VisibleFileMetricsScope: Equatable {
        let filePathDisplay: FilePathDisplay
        let codeMapUsage: CodeMapUsage
        let selectedPaths: [String]
        let manualCodemapPaths: [String]
        let slices: [String: [LineRange]]
        let codemapAutoEnabled: Bool
        let worktreeBindingFingerprint: String
    }

    private struct VisibleFileMetricsKey: Hashable {
        let rootID: UUID
        let rowID: ResolvedPromptFileEntryID
        let kind: AgentContextExportRow.Kind
    }

    private struct VisibleFileMetricsSnapshot {
        let scope: VisibleFileMetricsScope
        let keys: Set<VisibleFileMetricsKey>
        let metricsByKey: [VisibleFileMetricsKey: AgentContextExportRow.Metrics]
        let totalSelectedDisplayTokens: Int
    }

    private var visibleFileMetricsSnapshot: VisibleFileMetricsSnapshot?

    init(resolver: @escaping ResolveModel = AgentSelectedFilesModelCoordinator.resolveModel) {
        self.resolver = resolver
    }

    init(
        resolver: @escaping (AgentSelectedFilesModelRequest) async throws -> AgentContextExportModel
    ) {
        self.resolver = {
            (request: AgentSelectedFilesModelRequest, _: ResolveInterimFileRows?) async throws in
            try await resolver(request)
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    @discardableResult
    func refreshIfNeeded(
        _ request: AgentSelectedFilesModelRequest,
        force: Bool = false,
        preserveDisplayedModel: Bool = false
    ) -> AgentSelectedFilesRefreshOutcome {
        refresh(
            request,
            force: force,
            preserveDisplayedModel: preserveDisplayedModel,
            publishesInterimFileRows: true
        )
    }

    @discardableResult
    func refreshAfterTokenMetricsCompletion(
        _ request: AgentSelectedFilesModelRequest
    ) -> AgentSelectedFilesRefreshOutcome? {
        guard request.entryMetricsSnapshot != nil else { return nil }
        guard displayedModelMatches(request.identity) || loadingIdentity == request.identity else { return nil }
        return refresh(
            request,
            force: true,
            preserveDisplayedModel: true,
            publishesInterimFileRows: false
        )
    }

    private func refresh(
        _ request: AgentSelectedFilesModelRequest,
        force: Bool,
        preserveDisplayedModel: Bool,
        publishesInterimFileRows: Bool
    ) -> AgentSelectedFilesRefreshOutcome {
        debugStats.refreshRequests += 1
        var refreshFields = AgentSelectedFilesDiagnostics.requestFields(request)
        refreshFields["force"] = String(force)
        refreshFields["preserveDisplayedModel"] = String(preserveDisplayedModel)
        refreshFields["publishesInterimFileRows"] = String(publishesInterimFileRows)
        refreshFields["hasModel"] = String(model != nil)
        refreshFields["loadedMatch"] = String(loadedIdentity == request.identity)
        refreshFields["loadingMatch"] = String(loadingIdentity == request.identity)
        refreshFields["hasRefreshTask"] = String(refreshTask != nil)
        AgentSelectedFilesDiagnostics.event("coordinator.refresh.request", fields: refreshFields, includeStack: true)

        if !force, loadingIdentity == request.identity {
            debugStats.skippedLoading += 1
            AgentSelectedFilesDiagnostics.event("coordinator.refresh.skipLoading", fields: refreshFields)
            return .skippedLoading
        }

        if !force, completedDisplayedModelMatches(request.identity) {
            cancelActiveRefresh(reason: "skipLoaded", fields: refreshFields)
            state = AgentSelectedFilesModelState(
                model: state.model,
                rowSplit: state.rowSplit,
                isLoading: false,
                canMutateDisplayedModel: displayedModelIsMutable
            )
            debugStats.skippedLoaded += 1
            AgentSelectedFilesDiagnostics.event("coordinator.refresh.skipLoaded", fields: refreshFields)
            return .skippedLoaded
        }

        if !force, let cachedModel = cachedModels[request.identity] {
            cancelActiveRefresh(reason: "skipCached", fields: refreshFields)
            debugStats.skippedLoaded += 1
            touchCachedModel(request.identity)
            let cachedRowSplit = AgentSelectedFilesRowSplit(rows: cachedModel.rows)
            state = AgentSelectedFilesModelState(
                model: cachedModel,
                rowSplit: cachedRowSplit,
                isLoading: false,
                canMutateDisplayedModel: true
            )
            completedCountSnapshots[request.identity] = cachedRowSplit.fileCodemapCountSummary
            loadedIdentity = request.identity
            displayedIdentity = request.identity
            recordVisibleFileMetricsSnapshot(
                identity: request.identity,
                rowSplit: cachedRowSplit,
                totalSelectedDisplayTokens: cachedModel.totalSelectedDisplayTokens
            )
            AgentSelectedFilesDiagnostics.event("coordinator.refresh.skipCached", fields: refreshFields)
            return .skippedLoaded
        }

        cancelActiveRefresh(reason: "startReplacement", fields: refreshFields)

        let shouldClearLoadedModel = loadedIdentity != request.identity
        let shouldPreserveDisplayedModel = preserveDisplayedModel || displayedModelMatches(request.identity)
        let shouldClearDisplayedModel = shouldClearLoadedModel && !shouldPreserveDisplayedModel
        if shouldClearDisplayedModel {
            loadedIdentity = nil
            displayedIdentity = nil
        }

        let refreshID = UUID()
        self.refreshID = refreshID
        loadingIdentity = request.identity
        state = AgentSelectedFilesModelState(
            model: shouldClearDisplayedModel ? nil : state.model,
            rowSplit: shouldClearDisplayedModel ? .empty : state.rowSplit,
            isLoading: true,
            canMutateDisplayedModel: false
        )
        debugStats.resolverStarts += 1
        refreshFields["shouldClearLoadedModel"] = String(shouldClearLoadedModel)
        refreshFields["shouldClearDisplayedModel"] = String(shouldClearDisplayedModel)
        refreshFields["refreshID"] = AgentSelectedFilesDiagnostics.shortID(refreshID)
        AgentSelectedFilesDiagnostics.event("coordinator.resolve.start", fields: refreshFields)

        refreshTask = Task { [weak self, resolver] in
            let resolveStartMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
            let resolvesFileRowsFirst = publishesInterimFileRows && Self.shouldResolveFileRowsFirst(request)
            let interimFileRowsHandler: ResolveInterimFileRows? = resolvesFileRowsFirst ? { fileRowsModel in
                let fileRowsStartMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
                guard !Task.isCancelled else {
                    AgentSelectedFilesDiagnostics.event(
                        "coordinator.resolve.cancelledAfterFileRows",
                        fields: refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: fileRowsStartMS)) { _, new in new }
                    )
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.refreshID == refreshID, loadingIdentity == request.identity else {
                        debugStats.staleResultsIgnored += 1
                        AgentSelectedFilesDiagnostics.event(
                            "coordinator.resolve.fileRowsStaleIgnored",
                            fields: refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: fileRowsStartMS)) { _, new in new },
                            includeStack: true
                        )
                        return
                    }
                    var fileRowsFields = refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: fileRowsStartMS)) { _, new in new }
                    fileRowsFields["rowCount"] = String(fileRowsModel.rows.count)
                    fileRowsFields["missingPaths"] = String(fileRowsModel.missingPaths.count)
                    fileRowsFields["invalidPaths"] = String(fileRowsModel.invalidPaths.count)
                    AgentSelectedFilesDiagnostics.event("coordinator.resolve.fileRowsReady", fields: fileRowsFields)
                    let codemapReadinessIsPending = codemapReadinessPending(for: request.identity)
                    let publishedFileRowsModel = modelByPreservingKnownFileMetrics(
                        in: fileRowsModel,
                        identity: request.identity,
                        codemapReadinessPending: codemapReadinessIsPending
                    )
                    let fileRowsSplit = AgentSelectedFilesRowSplit(rows: publishedFileRowsModel.rows)
                    state = AgentSelectedFilesModelState(
                        model: publishedFileRowsModel,
                        rowSplit: fileRowsSplit,
                        isLoading: true,
                        canMutateDisplayedModel: false
                    )
                    displayedIdentity = request.identity
                    recordVisibleFileMetricsSnapshot(
                        identity: request.identity,
                        rowSplit: fileRowsSplit,
                        totalSelectedDisplayTokens: publishedFileRowsModel.totalSelectedDisplayTokens
                    )
                }
            } : nil
            let resolvedModel: AgentContextExportModel
            do {
                resolvedModel = try await resolver(request, interimFileRowsHandler)
            } catch is CancellationError {
                AgentSelectedFilesDiagnostics.event(
                    "coordinator.resolve.cancelled",
                    fields: refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: resolveStartMS)) { _, new in new }
                )
                return
            } catch {
                var failureFields = refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: resolveStartMS)) { _, new in new }
                failureFields["errorType"] = String(reflecting: type(of: error))
                AgentSelectedFilesDiagnostics.event("coordinator.resolve.failed", fields: failureFields)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.refreshID == refreshID,
                          loadingIdentity == request.identity
                    else { return }
                    loadingIdentity = nil
                    self.refreshID = nil
                    refreshTask = nil
                    state = AgentSelectedFilesModelState(
                        model: state.model,
                        rowSplit: state.rowSplit,
                        isLoading: false,
                        canMutateDisplayedModel: displayedModelIsMutable
                    )
                }
                return
            }
            guard !Task.isCancelled else {
                AgentSelectedFilesDiagnostics.event(
                    "coordinator.resolve.cancelledAfterReturn",
                    fields: refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: resolveStartMS)) { _, new in new }
                )
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.refreshID == refreshID, loadingIdentity == request.identity else {
                    debugStats.staleResultsIgnored += 1
                    AgentSelectedFilesDiagnostics.event(
                        "coordinator.resolve.staleIgnored",
                        fields: refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: resolveStartMS)) { _, new in new },
                        includeStack: true
                    )
                    return
                }
                var completionFields = refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: resolveStartMS)) { _, new in new }
                completionFields["rowCount"] = String(resolvedModel.rows.count)
                completionFields["missingPaths"] = String(resolvedModel.missingPaths.count)
                completionFields["invalidPaths"] = String(resolvedModel.invalidPaths.count)
                completionFields["hasProjection"] = String(resolvedModel.lookupContext.bindingProjection != nil)
                AgentSelectedFilesDiagnostics.event("coordinator.resolve.complete", fields: completionFields)
                let resolvedRowSplit = AgentSelectedFilesRowSplit(rows: resolvedModel.rows)
                state = AgentSelectedFilesModelState(
                    model: resolvedModel,
                    rowSplit: resolvedRowSplit,
                    isLoading: false,
                    canMutateDisplayedModel: true
                )
                completedCountSnapshots[request.identity] = resolvedRowSplit.fileCodemapCountSummary
                cacheModel(resolvedModel, for: request.identity)
                loadedIdentity = request.identity
                displayedIdentity = request.identity
                recordVisibleFileMetricsSnapshot(
                    identity: request.identity,
                    rowSplit: resolvedRowSplit,
                    totalSelectedDisplayTokens: resolvedModel.totalSelectedDisplayTokens
                )
                loadingIdentity = nil
                self.refreshID = nil
                refreshTask = nil
                debugStats.resolverCompletions += 1
            }
        }

        return .started
    }

    func cancelLoading(keepLoadedModel: Bool) {
        AgentSelectedFilesDiagnostics.event(
            "coordinator.cancelLoading",
            fields: [
                "keepLoadedModel": String(keepLoadedModel),
                "hasRefreshTask": String(refreshTask != nil),
                "hasModel": String(model != nil)
            ],
            includeStack: true
        )
        if refreshTask != nil {
            debugStats.cancellations += 1
        }
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        loadingIdentity = nil
        state = keepLoadedModel
            ? AgentSelectedFilesModelState(
                model: state.model,
                rowSplit: state.rowSplit,
                isLoading: false,
                canMutateDisplayedModel: displayedModelIsMutable
            )
            : .empty
        if !keepLoadedModel {
            loadedIdentity = nil
            displayedIdentity = nil
        }
    }

    func invalidate(keepLoadedModel: Bool = false) {
        AgentSelectedFilesDiagnostics.event(
            "coordinator.invalidate",
            fields: [
                "keepLoadedModel": String(keepLoadedModel),
                "hasModel": String(model != nil),
                "hasRefreshTask": String(refreshTask != nil)
            ],
            includeStack: true
        )
        cancelLoading(keepLoadedModel: keepLoadedModel)
        if !keepLoadedModel {
            state = .empty
            loadedIdentity = nil
            displayedIdentity = nil
        }
    }

    func resetDebugStats() {
        debugStats = AgentSelectedFilesModelDebugStats()
    }

    private func modelByPreservingKnownFileMetrics(
        in model: AgentContextExportModel,
        identity: AgentSelectedFilesModelIdentity,
        codemapReadinessPending: Bool
    ) -> AgentContextExportModel {
        guard codemapReadinessPending else { return model }
        let fileRows = model.rows.filter { $0.kind != .codemap }
        guard !fileRows.isEmpty else { return model }
        let keys = Set(fileRows.map(visibleFileMetricsKey(for:)))
        guard let metricsSnapshot = visibleFileMetricsSnapshot,
              metricsSnapshot.scope == visibleFileMetricsScope(for: identity),
              metricsSnapshot.keys == keys
        else { return model }

        var didPreserveMetrics = false
        let rows = model.rows.map { row in
            guard row.kind != .codemap,
                  row.metrics == .unknown,
                  let metrics = metricsSnapshot.metricsByKey[visibleFileMetricsKey(for: row)]
            else { return row }
            didPreserveMetrics = true
            return row.withMetrics(metrics)
        }.sorted(by: AgentContextExportResolver.rowSort)
        guard didPreserveMetrics else { return model }

        return AgentContextExportModel(
            source: model.source,
            lookupContext: model.lookupContext,
            rows: rows,
            totalSelectedDisplayTokens: metricsSnapshot.totalSelectedDisplayTokens,
            missingPaths: model.missingPaths,
            invalidPaths: model.invalidPaths,
            codemapPresentation: model.codemapPresentation
        )
    }

    private func recordVisibleFileMetricsSnapshot(
        identity: AgentSelectedFilesModelIdentity,
        rowSplit: AgentSelectedFilesRowSplit,
        totalSelectedDisplayTokens: Int
    ) {
        guard !rowSplit.fileRows.isEmpty else {
            visibleFileMetricsSnapshot = nil
            return
        }
        var metricsByKey: [VisibleFileMetricsKey: AgentContextExportRow.Metrics] = [:]
        for row in rowSplit.fileRows {
            guard row.metrics.knownValues != nil else {
                visibleFileMetricsSnapshot = nil
                return
            }
            metricsByKey[visibleFileMetricsKey(for: row)] = row.metrics
        }
        guard metricsByKey.count == rowSplit.fileRows.count else {
            visibleFileMetricsSnapshot = nil
            return
        }

        visibleFileMetricsSnapshot = VisibleFileMetricsSnapshot(
            scope: visibleFileMetricsScope(for: identity),
            keys: Set(metricsByKey.keys),
            metricsByKey: metricsByKey,
            totalSelectedDisplayTokens: totalSelectedDisplayTokens
        )
    }

    private func visibleFileMetricsScope(for identity: AgentSelectedFilesModelIdentity) -> VisibleFileMetricsScope {
        let selection = identity.exportContextIdentity.selection
        return VisibleFileMetricsScope(
            filePathDisplay: identity.filePathDisplay,
            codeMapUsage: identity.codeMapUsage,
            selectedPaths: selection.selectedPaths.sorted(),
            manualCodemapPaths: selection.manualCodemapPaths.sorted(),
            slices: selection.slices.mapValues { lineRanges in
                lineRanges.sorted { lhs, rhs in
                    if lhs.start != rhs.start { return lhs.start < rhs.start }
                    return lhs.end < rhs.end
                }
            },
            codemapAutoEnabled: selection.codemapAutoEnabled,
            worktreeBindingFingerprint: identity.exportContextIdentity.worktreeBindingFingerprint
        )
    }

    private func codemapReadinessPending(for identity: AgentSelectedFilesModelIdentity) -> Bool {
        guard !Self.codemapCountIsStableBeforeCompletion(identity) else { return false }
        guard loadedIdentity == identity else { return true }
        return completedCountSnapshots[identity] == nil
    }

    private func visibleFileMetricsKey(for row: AgentContextExportRow) -> VisibleFileMetricsKey {
        VisibleFileMetricsKey(rootID: row.rootID, rowID: row.id, kind: row.kind)
    }

    private func cancelActiveRefresh(reason: String, fields: [String: String]) {
        guard refreshTask != nil || refreshID != nil || loadingIdentity != nil else { return }
        var cancelFields = fields
        cancelFields["reason"] = reason
        cancelFields["cancelledLoadingIdentityPresent"] = String(loadingIdentity != nil)
        if refreshTask != nil {
            debugStats.cancellations += 1
            AgentSelectedFilesDiagnostics.event("coordinator.refresh.cancelExisting", fields: cancelFields, includeStack: true)
            refreshTask?.cancel()
        } else {
            AgentSelectedFilesDiagnostics.event("coordinator.refresh.clearOrphanedGeneration", fields: cancelFields, includeStack: true)
        }
        refreshTask = nil
        refreshID = nil
        loadingIdentity = nil
    }

    private func cacheModel(_ model: AgentContextExportModel, for identity: AgentSelectedFilesModelIdentity) {
        cachedModels[identity] = model
        touchCachedModel(identity)
        while cachedModelOrder.count > cachedModelLimit {
            let evicted = cachedModelOrder.removeFirst()
            cachedModels[evicted] = nil
            completedCountSnapshots[evicted] = nil
        }
    }

    private func touchCachedModel(_ identity: AgentSelectedFilesModelIdentity) {
        cachedModelOrder.removeAll { $0 == identity }
        cachedModelOrder.append(identity)
    }

    private static func shouldResolveFileRowsFirst(_ request: AgentSelectedFilesModelRequest) -> Bool {
        guard hasExplicitFileRows(request.source.selection) else { return false }
        switch request.codeMapUsage {
        case .auto:
            return request.source.selection.codemapAutoEnabled || !request.source.selection.manualCodemapPaths.isEmpty
        case .complete:
            return true
        case .none, .selected:
            return false
        }
    }

    private static func codemapCountIsStableBeforeCompletion(_ identity: AgentSelectedFilesModelIdentity) -> Bool {
        switch identity.codeMapUsage {
        case .none:
            return true
        case .auto:
            let selection = identity.exportContextIdentity.selection
            return !selection.codemapAutoEnabled && selection.manualCodemapPaths.isEmpty
        case .complete, .selected:
            return false
        }
    }

    private static func hasExplicitFileRows(_ selection: StoredSelection) -> Bool {
        if !selection.selectedPaths.isEmpty { return true }
        return selection.slices.contains { !$0.value.isEmpty }
    }

    private static func resolveModel(
        _ request: AgentSelectedFilesModelRequest,
        interimFileRowsHandler: ResolveInterimFileRows?
    ) async throws -> AgentContextExportModel {
        try await AgentContextExportResolver.resolveModel(
            source: request.source,
            store: request.store,
            filePathDisplay: request.filePathDisplay,
            codeMapUsage: request.codeMapUsage,
            entryMetricsSnapshot: request.entryMetricsSnapshot,
            interimFileRowsHandler: interimFileRowsHandler
        )
    }
}
