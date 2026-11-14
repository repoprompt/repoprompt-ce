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
        private let rootOwner: Lease?
        private(set) var isReleased = false

        fileprivate init(resources: AgentHostWorkspaceResources, snapshot: DomainWorkspaceSnapshot, retention: WorkspaceFileContextStore.RootRetention, rootOwner: Lease? = nil) {
            self.resources = resources
            self.snapshot = snapshot
            self.retention = retention
            self.rootOwner = rootOwner
        }

        /// Root lifetime revocation is independently readable after any actor hop. Context
        /// document currency remains the domain authority's async check, never a local mirror.
        var rootsAreCurrent: Bool {
            !isReleased && retention.rootLifetimesAreCurrent && (rootOwner?.rootsAreCurrent ?? true)
        }

        func isCurrent() async -> Bool {
            guard rootsAreCurrent,
                  await resources.contexts?.workspaceSnapshot(snapshot.document.workspaceID) == snapshot,
                  await resources.files.isRootRetentionCurrent(retention) else { return false }
            return rootsAreCurrent
        }

        /// A request captures fresh canonical bytes while borrowing this activation's existing
        /// root retention. Context edits do not allocate another root lease or update old receipts.
        func capture(context: DomainContextIdentity) async throws -> Lease {
            try Task.checkCancellation()
            guard rootsAreCurrent, context.workspaceID == snapshot.document.workspaceID,
                  let current = await resources.contexts?.workspaceSnapshot(context.workspaceID),
                  current.health != .removed,
                  current.contexts.contains(where: { $0.metadata.identity == context && $0.health != .removed })
            else { throw Failure.contextUnavailable }
            let originalPaths = Set(snapshot.document.metadata.repoPaths.map { ($0 as NSString).standardizingPath })
            guard Set(current.document.metadata.repoPaths.map { ($0 as NSString).standardizingPath }) == originalPaths,
                  await resources.files.isRootRetentionCurrent(retention), rootsAreCurrent
            else { throw Failure.rootsChanged }
            guard await resources.contexts?.workspaceSnapshot(context.workspaceID) == current else { throw Failure.contextChanged }
            try Task.checkCancellation()
            guard rootsAreCurrent else { throw Failure.rootsChanged }
            return Lease(resources: resources, snapshot: current, retention: retention, rootOwner: rootOwner ?? self)
        }

        func release() async {
            guard !isReleased else { return }
            isReleased = true
            if rootOwner == nil { await resources.files.releaseRootRetention(retention) }
        }
    }
}
