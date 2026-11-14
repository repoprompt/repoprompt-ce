import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext

/// Resource composition only: reads the existing domain authority and never owns another catalog.
/// Legacy windows and future unpresented hosts use the same file-store construction and lease API.
@MainActor
struct AgentHostWorkspaceResources {
    enum Failure: Error { case authorityUnavailable, contextUnavailable, rootsChanged, contextChanged }

    let files: WorkspaceFileContextStore
    let contexts: DomainContextStore?

    static func makeFiles(settingsStore: GlobalSettingsStore) -> WorkspaceFileContextStore {
        #if DEBUG
            WorkspaceFileContextStore(
                startupFeatureFlags: .current(), enableCatalogShardShadowValidation: false,
                nonGitCodeMapsEnabled: settingsStore.nonGitCodeMapsEnabled,
                codeMapsGloballyDisabled: settingsStore.globalCodeMapsDisabled(),
                restorePerfRecorder: AppWorkspaceRestorePerfRecorder(), perfRecorder: AppAgentModePerfRecorder()
            )
        #else
            WorkspaceFileContextStore(
                startupFeatureFlags: .current(), nonGitCodeMapsEnabled: settingsStore.nonGitCodeMapsEnabled,
                codeMapsGloballyDisabled: settingsStore.globalCodeMapsDisabled(),
                restorePerfRecorder: AppWorkspaceRestorePerfRecorder(), perfRecorder: AppAgentModePerfRecorder()
            )
        #endif
    }

    /// Roots must already have been loaded through this store's ordinary bounded load API and
    /// cover the canonical workspace paths. An actually empty workspace needs no root retention.
    /// This retains resources and a read receipt, NOT writer, mutation, consent or run admission.
    func acquire(context identity: DomainContextIdentity, rootIDs: [UUID]) async throws -> Lease {
        try Task.checkCancellation()
        guard let contexts else { throw Failure.authorityUnavailable }
        guard let snapshot = await contexts.workspaceSnapshot(identity.workspaceID),
              snapshot.health != .removed,
              snapshot.contexts.contains(where: { $0.metadata.identity == identity && $0.health != .removed })
        else { throw Failure.contextUnavailable }
        let roots = await files.rootRefs()
        let paths = Set(snapshot.document.metadata.repoPaths.map { ($0 as NSString).standardizingPath })
        let requestedIDs = Set(rootIDs)
        let requestedRoots = roots.filter { requestedIDs.contains($0.id) }
        guard requestedRoots.count == requestedIDs.count,
              Set(requestedRoots.map { ($0.fullPath as NSString).standardizingPath }) == paths
        else { throw Failure.rootsChanged }
        try Task.checkCancellation()
        let retention = try await files.retainRoots(ids: rootIDs)
        do {
            try Task.checkCancellation()
            guard await contexts.workspaceSnapshot(identity.workspaceID) == snapshot else { throw Failure.contextChanged }
            guard await files.isRootRetentionCurrent(retention) else { throw Failure.rootsChanged }
            try Task.checkCancellation()
            return Lease(resources: self, snapshot: snapshot, retention: retention)
        } catch {
            await files.releaseRootRetention(retention)
            throw error
        }
    }

    @MainActor
    final class Lease {
        let resources: AgentHostWorkspaceResources
        let snapshot: DomainWorkspaceSnapshot
        private let retention: WorkspaceFileContextStore.RootRetention
        private(set) var isReleased = false

        fileprivate init(resources: AgentHostWorkspaceResources, snapshot: DomainWorkspaceSnapshot, retention: WorkspaceFileContextStore.RootRetention) {
            self.resources = resources
            self.snapshot = snapshot
            self.retention = retention
        }

        func isCurrent() async -> Bool {
            guard !isReleased,
                  await resources.contexts?.workspaceSnapshot(snapshot.document.workspaceID) == snapshot,
                  await resources.files.isRootRetentionCurrent(retention) else { return false }
            return !isReleased
        }

        func release() async {
            guard !isReleased else { return }
            isReleased = true
            await resources.files.releaseRootRetention(retention)
        }
    }
}
