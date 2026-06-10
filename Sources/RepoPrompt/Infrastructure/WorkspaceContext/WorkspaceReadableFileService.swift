import Foundation

struct WorkspaceReadableFileService {
    let store: WorkspaceFileContextStore
    let homeDirectoryURL: URL

    init(
        store: WorkspaceFileContextStore,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.homeDirectoryURL = homeDirectoryURL
    }

    func awaitFreshnessForExplicitRequest(
        _ userPath: String,
        fallbackScope: WorkspaceLookupRootScope
    ) async throws {
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessBegan,
            correlation: lifecycleCorrelation
        )
        let freshnessState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.explicitIngressFreshnessWait)
        let samples = await store.awaitAppliedIngressForExplicitRequest(
            userPath: userPath,
            fallbackScope: fallbackScope
        )
        try Task.checkCancellation()
        EditFlowPerf.end(
            EditFlowPerf.Stage.ReadFile.explicitIngressFreshnessWait,
            freshnessState,
            EditFlowPerf.Dimensions(
                rootCount: samples.count,
                pendingRootCount: samples.count(where: { $0.pendingRawEventCountBeforeFlush > 0 }),
                pendingRawEventCount: samples.reduce(0) { $0 + $1.pendingRawEventCountBeforeFlush }
            )
        )
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.ReadFile.explicitFreshnessEnded,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                rootCount: samples.count,
                pendingRootCount: samples.count(where: { $0.pendingRawEventCountBeforeFlush > 0 }),
                pendingRawEventCount: samples.reduce(0) { $0 + $1.pendingRawEventCountBeforeFlush }
            )
        )
    }

    static func exactAbsoluteCatalogHitInput(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return expanded
    }

    func resolveExactAbsoluteWorkspaceCatalogHit(
        _ rawPath: String,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspaceFileRecord? {
        guard let absolutePath = Self.exactAbsoluteCatalogHitInput(rawPath) else { return nil }
        return await resolveExactWorkspaceCatalogHit(absolutePath, rootScope: rootScope)
    }

    func resolveExactWorkspaceCatalogHit(
        _ rawPath: String,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspaceFileRecord? {
        guard case let .matched(file) = await store.lookupCatalogFileForExplicitRequest(rawPath, rootScope: rootScope) else {
            return nil
        }
        return file
    }

    func resolveReadableFile(
        _ userPath: String,
        profile: PathLocateProfile = .mcpRead,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceReadableFileHandle? {
        let trimmed = normalizedInput(userPath)
        guard !trimmed.isEmpty else { return nil }
        let exactCatalogLookupAwait = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.exactCatalogLookupAwait)
        let exactCatalogLookup = await store.lookupCatalogFileForExplicitRequest(trimmed, rootScope: rootScope)
        EditFlowPerf.end(
            EditFlowPerf.Stage.ReadFile.exactCatalogLookupAwait,
            exactCatalogLookupAwait,
            EditFlowPerf.Dimensions(outcome: {
                switch exactCatalogLookup {
                case .matched:
                    "matched"
                case .noCandidate:
                    "noCandidate"
                case .ambiguous:
                    "ambiguous"
                case .blocked:
                    "blocked"
                }
            }())
        )
        switch exactCatalogLookup {
        case let .matched(file):
            return .workspace(file)
        case .ambiguous, .blocked:
            return nil
        case .noCandidate:
            break
        }
        let explicitMaterialization = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.explicitMaterialization)
        let materialization = try? await store.materializeExplicitlyRequestedFile(trimmed, rootScope: rootScope)
        EditFlowPerf.end(
            EditFlowPerf.Stage.ReadFile.explicitMaterialization,
            explicitMaterialization,
            EditFlowPerf.Dimensions(outcome: {
                switch materialization {
                case .some(.materialized):
                    "materialized"
                case .some(.noCandidate):
                    "noCandidate"
                case .some(.ambiguous):
                    "ambiguous"
                case .some(.blocked):
                    "blocked"
                case .none:
                    "error"
                }
            }())
        )
        switch materialization {
        case let .some(.materialized(file)):
            return .workspace(file)
        case .some(.ambiguous), .some(.blocked):
            return nil
        case .some(.noCandidate), .none:
            break
        }
        let generalLookupFallback = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.generalLookupFallback)
        let workspaceFile = await store.lookupPath(
            WorkspacePathLookupRequest(userPath: trimmed, profile: profile, rootScope: rootScope)
        )?.file
        EditFlowPerf.end(
            EditFlowPerf.Stage.ReadFile.generalLookupFallback,
            generalLookupFallback,
            EditFlowPerf.Dimensions(outcome: workspaceFile == nil ? "noCandidate" : "matched")
        )
        if let workspaceFile {
            return .workspace(workspaceFile)
        }
        guard trimmed.hasPrefix("/") else { return nil }
        let externalFileFallback = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.externalFileFallback)
        let externalFile = resolveAlwaysReadableExternalFile(atAbsolutePath: trimmed)
        EditFlowPerf.end(
            EditFlowPerf.Stage.ReadFile.externalFileFallback,
            externalFileFallback,
            EditFlowPerf.Dimensions(outcome: externalFile == nil ? "noCandidate" : "external")
        )
        return externalFile.map { .external($0) }
    }

    func resolveAlwaysReadableExternalFolderDisplayPath(_ userPath: String) -> String? {
        let normalized = normalizedInput(userPath)
        guard normalized.hasPrefix("/"), isAlwaysReadableExternalPath(normalized) else { return nil }
        let absolutePath = normalizedAlwaysReadableAbsolutePath(for: normalized)
        guard isAlwaysReadableExternalPath(absolutePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return displayPath(forExternalPath: absolutePath)
    }

    func displayPath(forExternalPath userPath: String) -> String {
        AgentSupportDirectoryCatalog.displayPath(for: normalizedInput(userPath), homeDirectoryURL: homeDirectoryURL)
    }

    func isAlwaysReadableExternalPath(_ userPath: String) -> Bool {
        let normalized = normalizedInput(userPath)
        guard normalized.hasPrefix("/") else { return false }
        let directories = AgentSupportDirectoryCatalog.effectiveAlwaysReadableDirectories(homeDirectoryURL: homeDirectoryURL)
        return directories.contains { AgentSupportDirectoryCatalog.contains(absolutePath: normalized, in: $0) }
    }

    func readAlwaysReadableExternalFile(_ file: WorkspaceExternalReadableFile) async throws -> String {
        let path = file.absolutePath
        return try await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            if let decoded = String(data: data, encoding: .utf8) { return decoded }
            if let decoded = String(data: data, encoding: .unicode) { return decoded }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    func resolveAlwaysReadableExternalFile(atAbsolutePath path: String) -> WorkspaceExternalReadableFile? {
        guard isAlwaysReadableExternalPath(path) else { return nil }
        let absolutePath = normalizedAlwaysReadableAbsolutePath(for: path)
        guard isAlwaysReadableExternalPath(absolutePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return WorkspaceExternalReadableFile(
            absolutePath: absolutePath,
            displayPath: displayPath(forExternalPath: absolutePath)
        )
    }

    private func normalizedAlwaysReadableAbsolutePath(for path: String) -> String {
        let normalized = AgentSupportDirectoryCatalog.normalizedPath(for: path)
        if FileManager.default.fileExists(atPath: normalized) {
            return AgentSupportDirectoryCatalog.normalizedPath(
                for: URL(fileURLWithPath: normalized).resolvingSymlinksInPath().standardizedFileURL.path
            )
        }
        return normalized
    }

    private func normalizedInput(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}
