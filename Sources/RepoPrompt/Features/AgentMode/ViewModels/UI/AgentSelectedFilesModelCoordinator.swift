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
}

struct AgentSelectedFilesRowSplit: Equatable {
    let rows: [AgentContextExportRow]
    let fileRows: [AgentContextExportRow]
    let codemapRows: [AgentContextExportRow]

    static let empty = AgentSelectedFilesRowSplit(rows: [])

    init(rows: [AgentContextExportRow]) {
        self.rows = rows
        var fileRows: [AgentContextExportRow] = []
        var codemapRows: [AgentContextExportRow] = []
        fileRows.reserveCapacity(rows.count)
        codemapRows.reserveCapacity(rows.count)
        for row in rows {
            if row.kind == .codemap {
                codemapRows.append(row)
            } else {
                fileRows.append(row)
            }
        }
        self.fileRows = fileRows
        self.codemapRows = codemapRows
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

    static let empty = AgentSelectedFilesModelState(model: nil, rowSplit: .empty, isLoading: false)
}

@MainActor
final class AgentSelectedFilesModelCoordinator: ObservableObject {
    typealias ResolveModel = (AgentSelectedFilesModelRequest) async -> AgentContextExportModel

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

    private let resolver: ResolveModel
    private var loadedIdentity: AgentSelectedFilesModelIdentity?
    private var loadingIdentity: AgentSelectedFilesModelIdentity?
    private var refreshID: UUID?
    private var refreshTask: Task<Void, Never>?
    private let cachedModelLimit = 5
    private var cachedModels: [AgentSelectedFilesModelIdentity: AgentContextExportModel] = [:]
    private var cachedModelOrder: [AgentSelectedFilesModelIdentity] = []

    init(resolver: @escaping ResolveModel = AgentSelectedFilesModelCoordinator.resolveModel) {
        self.resolver = resolver
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
        debugStats.refreshRequests += 1
        var refreshFields = AgentSelectedFilesDiagnostics.requestFields(request)
        refreshFields["force"] = String(force)
        refreshFields["preserveDisplayedModel"] = String(preserveDisplayedModel)
        refreshFields["hasModel"] = String(model != nil)
        refreshFields["loadedMatch"] = String(loadedIdentity == request.identity)
        refreshFields["loadingMatch"] = String(loadingIdentity == request.identity)
        refreshFields["hasRefreshTask"] = String(refreshTask != nil)
        AgentSelectedFilesDiagnostics.event("coordinator.refresh.request", fields: refreshFields, includeStack: true)

        if !force, loadedIdentity == request.identity, model != nil {
            cancelActiveRefresh(reason: "skipLoaded", fields: refreshFields)
            state = AgentSelectedFilesModelState(model: state.model, rowSplit: state.rowSplit, isLoading: false)
            debugStats.skippedLoaded += 1
            AgentSelectedFilesDiagnostics.event("coordinator.refresh.skipLoaded", fields: refreshFields)
            return .skippedLoaded
        }

        if !force, let cachedModel = cachedModels[request.identity] {
            cancelActiveRefresh(reason: "skipCached", fields: refreshFields)
            debugStats.skippedLoaded += 1
            touchCachedModel(request.identity)
            state = AgentSelectedFilesModelState(
                model: cachedModel,
                rowSplit: AgentSelectedFilesRowSplit(rows: cachedModel.rows),
                isLoading: false
            )
            loadedIdentity = request.identity
            AgentSelectedFilesDiagnostics.event("coordinator.refresh.skipCached", fields: refreshFields)
            return .skippedLoaded
        }

        if !force, loadingIdentity == request.identity {
            debugStats.skippedLoading += 1
            AgentSelectedFilesDiagnostics.event("coordinator.refresh.skipLoading", fields: refreshFields)
            return .skippedLoading
        }

        cancelActiveRefresh(reason: "startReplacement", fields: refreshFields)

        let shouldClearLoadedModel = loadedIdentity != request.identity
        let shouldClearDisplayedModel = shouldClearLoadedModel && !preserveDisplayedModel
        if shouldClearDisplayedModel {
            loadedIdentity = nil
        }

        let refreshID = UUID()
        self.refreshID = refreshID
        loadingIdentity = request.identity
        state = AgentSelectedFilesModelState(
            model: shouldClearDisplayedModel ? nil : state.model,
            rowSplit: shouldClearDisplayedModel ? .empty : state.rowSplit,
            isLoading: true
        )
        debugStats.resolverStarts += 1
        refreshFields["shouldClearLoadedModel"] = String(shouldClearLoadedModel)
        refreshFields["shouldClearDisplayedModel"] = String(shouldClearDisplayedModel)
        refreshFields["refreshID"] = AgentSelectedFilesDiagnostics.shortID(refreshID)
        AgentSelectedFilesDiagnostics.event("coordinator.resolve.start", fields: refreshFields)

        refreshTask = Task { [weak self, resolver] in
            let resolveStartMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
            if Self.shouldResolveFileRowsFirst(request) {
                let fileRowsRequest = Self.fileRowsOnlyRequest(from: request)
                let fileRowsStartMS = AgentSelectedFilesDiagnostics.timestampMSIfEnabled()
                let fileRowsModel = await resolver(fileRowsRequest)
                guard !Task.isCancelled else {
                    AgentSelectedFilesDiagnostics.event(
                        "coordinator.resolve.cancelledAfterFileRows",
                        fields: refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: fileRowsStartMS)) { _, new in new }
                    )
                    return
                }
                let shouldContinue = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    guard self.refreshID == refreshID, loadingIdentity == request.identity else {
                        debugStats.staleResultsIgnored += 1
                        AgentSelectedFilesDiagnostics.event(
                            "coordinator.resolve.fileRowsStaleIgnored",
                            fields: refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: fileRowsStartMS)) { _, new in new },
                            includeStack: true
                        )
                        return false
                    }
                    var fileRowsFields = refreshFields.merging(AgentSelectedFilesDiagnostics.elapsedFields(since: fileRowsStartMS)) { _, new in new }
                    fileRowsFields["rowCount"] = String(fileRowsModel.rows.count)
                    fileRowsFields["missingPaths"] = String(fileRowsModel.missingPaths.count)
                    fileRowsFields["invalidPaths"] = String(fileRowsModel.invalidPaths.count)
                    AgentSelectedFilesDiagnostics.event("coordinator.resolve.fileRowsReady", fields: fileRowsFields)
                    state = AgentSelectedFilesModelState(
                        model: fileRowsModel,
                        rowSplit: AgentSelectedFilesRowSplit(rows: fileRowsModel.rows),
                        isLoading: true
                    )
                    return true
                }
                guard shouldContinue else { return }
            }
            let resolvedModel = await resolver(request)
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
                state = AgentSelectedFilesModelState(
                    model: resolvedModel,
                    rowSplit: AgentSelectedFilesRowSplit(rows: resolvedModel.rows),
                    isLoading: false
                )
                cacheModel(resolvedModel, for: request.identity)
                loadedIdentity = request.identity
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
            ? AgentSelectedFilesModelState(model: state.model, rowSplit: state.rowSplit, isLoading: false)
            : .empty
        if !keepLoadedModel {
            loadedIdentity = nil
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
        }
    }

    func resetDebugStats() {
        debugStats = AgentSelectedFilesModelDebugStats()
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

    private static func hasExplicitFileRows(_ selection: StoredSelection) -> Bool {
        if !selection.selectedPaths.isEmpty { return true }
        return selection.slices.contains { !$0.value.isEmpty }
    }

    private static func fileRowsOnlyRequest(from request: AgentSelectedFilesModelRequest) -> AgentSelectedFilesModelRequest {
        AgentSelectedFilesModelRequest(
            identity: AgentSelectedFilesModelIdentity(
                exportContextIdentity: request.identity.exportContextIdentity,
                filePathDisplay: request.identity.filePathDisplay,
                codeMapUsage: .none
            ),
            source: request.source,
            store: request.store,
            filePathDisplay: request.filePathDisplay,
            codeMapUsage: .none
        )
    }

    private static func resolveModel(_ request: AgentSelectedFilesModelRequest) async -> AgentContextExportModel {
        await AgentContextExportResolver.resolveModel(
            source: request.source,
            store: request.store,
            filePathDisplay: request.filePathDisplay,
            codeMapUsage: request.codeMapUsage
        )
    }
}
