import Foundation

package struct WorkspaceReadableFileService {
    package let store: WorkspaceFileContextStore
    package let homeDirectoryURL: URL
    package let externalFileReader: any WorkspaceExternalFileReading

    package init(
        store: WorkspaceFileContextStore,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        externalFileReader: (any WorkspaceExternalFileReading)? = nil
    ) {
        self.store = store
        self.homeDirectoryURL = homeDirectoryURL
        self.externalFileReader = externalFileReader ?? WorkspaceExternalFileReaderProvider.makeReader()
    }

    package func awaitFreshnessForExplicitRequest(
        _ userPath: String,
        fallbackScope: WorkspaceLookupRootScope
    ) async {
        let lifecycleCorrelation = WorkspaceRuntimePerf.currentLifecycleCorrelation
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.ReadFile.explicitFreshnessBegan,
            correlation: lifecycleCorrelation
        )
        let freshnessState = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.explicitIngressFreshnessWait)
        let samples = await store.awaitAppliedIngressForExplicitRequest(
            userPath: userPath,
            fallbackScope: fallbackScope
        )
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.explicitIngressFreshnessWait,
            freshnessState,
            WorkspaceRuntimePerf.Dimensions(
                rootCount: samples.count,
                pendingRootCount: samples.count(where: { $0.pendingRawEventCountBeforeFlush > 0 }),
                pendingRawEventCount: samples.reduce(0) { $0 + $1.pendingRawEventCountBeforeFlush }
            )
        )
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.ReadFile.explicitFreshnessEnded,
            correlation: lifecycleCorrelation,
            WorkspaceRuntimePerf.Dimensions(
                rootCount: samples.count,
                pendingRootCount: samples.count(where: { $0.pendingRawEventCountBeforeFlush > 0 }),
                pendingRawEventCount: samples.reduce(0) { $0 + $1.pendingRawEventCountBeforeFlush }
            )
        )
    }

    package static func exactAbsoluteCatalogHitInput(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return expanded
    }

    package func resolveExactAbsoluteWorkspaceCatalogHit(
        _ rawPath: String,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspaceFileRecord? {
        guard let absolutePath = Self.exactAbsoluteCatalogHitInput(rawPath) else { return nil }
        return await resolveExactWorkspaceCatalogHit(absolutePath, rootScope: rootScope)
    }

    package func resolveExactWorkspaceCatalogHit(
        _ rawPath: String,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspaceFileRecord? {
        guard case let .matched(file) = await store.lookupCatalogFileForExplicitRequest(rawPath, rootScope: rootScope) else {
            return nil
        }
        return file
    }

    package func resolveReadableFile(
        _ userPath: String,
        profile: PathLocateProfile = .mcpRead,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceReadableFileHandle? {
        let trimmed = normalizedInput(userPath)
        guard !trimmed.isEmpty else { return nil }
        let exactCatalogLookupAwait = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.exactCatalogLookupAwait)
        let exactCatalogLookup = await store.lookupCatalogFileForExplicitRequest(trimmed, rootScope: rootScope)
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.exactCatalogLookupAwait,
            exactCatalogLookupAwait,
            WorkspaceRuntimePerf.Dimensions(outcome: {
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
        let explicitMaterialization = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.explicitMaterialization)
        let materialization = try? await store.materializeExplicitlyRequestedFile(trimmed, rootScope: rootScope)
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.explicitMaterialization,
            explicitMaterialization,
            WorkspaceRuntimePerf.Dimensions(outcome: {
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
        let generalLookupFallback = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.generalLookupFallback)
        let workspaceFile = await store.lookupPath(
            WorkspacePathLookupRequest(userPath: trimmed, profile: profile, rootScope: rootScope)
        )?.file
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.generalLookupFallback,
            generalLookupFallback,
            WorkspaceRuntimePerf.Dimensions(outcome: workspaceFile == nil ? "noCandidate" : "matched")
        )
        if let workspaceFile {
            return .workspace(workspaceFile)
        }
        guard trimmed.hasPrefix("/") else { return nil }
        let externalFileFallback = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.externalFileFallback)
        let externalFile = resolveAlwaysReadableExternalFile(atAbsolutePath: trimmed)
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.externalFileFallback,
            externalFileFallback,
            WorkspaceRuntimePerf.Dimensions(outcome: externalFile == nil ? "noCandidate" : "external")
        )
        return externalFile.map { .external($0) }
    }

    package func resolveAlwaysReadableExternalFolderDisplayPath(_ userPath: String) -> String? {
        let normalized = normalizedInput(userPath)
        guard normalized.hasPrefix("/"), isAlwaysReadableExternalPath(normalized) else { return nil }
        let directories = AgentSupportDirectoryCatalog.effectiveAlwaysReadableDirectories(homeDirectoryURL: homeDirectoryURL)
        guard let absolutePath = try? externalFileReader.resolveDirectory(
            atAbsolutePath: normalized,
            allowedDirectories: directories
        ) else {
            return nil
        }
        return displayPath(forExternalPath: absolutePath)
    }

    package func displayPath(forExternalPath userPath: String) -> String {
        AgentSupportDirectoryCatalog.displayPath(for: normalizedInput(userPath), homeDirectoryURL: homeDirectoryURL)
    }

    package func isAlwaysReadableExternalPath(_ userPath: String) -> Bool {
        let normalized = normalizedInput(userPath)
        guard normalized.hasPrefix("/") else { return false }
        let directories = AgentSupportDirectoryCatalog.effectiveAlwaysReadableDirectories(homeDirectoryURL: homeDirectoryURL)
        return directories.contains { AgentSupportDirectoryCatalog.contains(absolutePath: normalized, in: $0) }
    }

    package func readAlwaysReadableExternalFile(_ file: WorkspaceExternalReadableFile) async throws -> String {
        let path = file.absolutePath
        let directories = AgentSupportDirectoryCatalog.effectiveAlwaysReadableDirectories(homeDirectoryURL: homeDirectoryURL)
        let reader = externalFileReader
        return try await Task.detached(priority: .userInitiated) {
            let data = try reader.readRegularFile(atAbsolutePath: path, allowedDirectories: directories)
            if let decoded = String(data: data, encoding: .utf8) { return decoded }
            if let decoded = String(data: data, encoding: .unicode) { return decoded }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    package func resolveAlwaysReadableExternalFile(atAbsolutePath path: String) -> WorkspaceExternalReadableFile? {
        guard isAlwaysReadableExternalPath(path) else { return nil }
        let directories = AgentSupportDirectoryCatalog.effectiveAlwaysReadableDirectories(homeDirectoryURL: homeDirectoryURL)
        guard let absolutePath = try? externalFileReader.resolveRegularFile(
            atAbsolutePath: path,
            allowedDirectories: directories
        ) else {
            return nil
        }
        return WorkspaceExternalReadableFile(
            absolutePath: absolutePath,
            displayPath: displayPath(forExternalPath: absolutePath)
        )
    }

    private func normalizedInput(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}
