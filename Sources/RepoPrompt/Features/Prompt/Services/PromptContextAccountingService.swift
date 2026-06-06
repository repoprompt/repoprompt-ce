import Foundation
import RepoPromptCore

/// App diagnostics and compatibility facade over canonical Core prompt accounting.
actor PromptContextAccountingService {
    private let core = RepoPromptCore.PromptContextAccountingService()

    func calculatePromptStats(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore,
        fileTreeSnapshotRequest: WorkspaceFileTreeSnapshotRequest
    ) async throws -> PromptContextAccountingResult {
        try await withDiagnostics(selection: request.selection, operation: "calculate") {
            try await core.calculatePromptStats(
                request: request,
                store: store,
                fileTreeSnapshotRequest: fileTreeSnapshotRequest
            )
        }
    }

    func calculatePromptStats(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore
    ) async throws -> PromptContextAccountingResult {
        try await withDiagnostics(selection: request.selection, operation: "calculate") {
            try await core.calculatePromptStats(request: request, store: store)
        }
    }

    func resolveEntries(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        profile: PathLocateProfile = .uiAssisted,
        codeMapUsage: CodeMapUsage = .auto
    ) async -> PromptContextAccountingResolution {
        do {
            return try await withDiagnostics(selection: selection, operation: "resolveEntries") {
                try await core.resolveEntries(
                    selection: selection,
                    store: store,
                    rootScope: rootScope,
                    profile: profile,
                    codeMapUsage: codeMapUsage
                )
            }
        } catch {
            return .empty
        }
    }

    private func withDiagnostics<T>(
        selection: StoredSelection,
        operation: String,
        body: () async throws -> T
    ) async throws -> T {
        #if DEBUG
            let startMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.accounting.\(operation).begin",
                fields: PromptTokenRecountDiagnostics.selectionFields(selection)
            )
        #endif
        do {
            let result = try await body()
            #if DEBUG
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.accounting.\(operation).end",
                    fields: [
                        "outcome": "completed",
                        "duration": startMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return result
        } catch {
            #if DEBUG
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.accounting.\(operation).end",
                    fields: [
                        "outcome": error is CancellationError ? "cancelled" : "error",
                        "duration": startMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            throw error
        }
    }
}
