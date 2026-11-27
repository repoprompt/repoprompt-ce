import Foundation
import RepoPromptDomainRuntime
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

/// Retains file roots for execution against the existing domain authority. The lease
/// proves readable resources, not an Agent writer or permission to mutate a workspace.
@MainActor
struct AgentHostWorkspaceResources {
    enum Failure: Error { case authorityUnavailable, contextUnavailable, rootsChanged, contextChanged }

    enum SnapshotAuthority {
        case canonical
        case readOverlay
    }

    let files: WorkspaceFileContextStore
    let contexts: DomainContextStore?

    #if DEBUG
        /// Deterministic suspension point right after root retention, before post-retention validation.
        var test_afterRetainRootsBeforeRecheck: (@MainActor () async -> Void)?
    #endif

    func withContexts(_ contexts: DomainContextStore?) -> AgentHostWorkspaceResources {
        var copy = AgentHostWorkspaceResources(files: files, contexts: contexts)
        #if DEBUG
            copy.test_afterRetainRootsBeforeRecheck = test_afterRetainRootsBeforeRecheck
        #endif
        return copy
    }

    func workspaceSnapshot(
        for workspaceID: UUID,
        authority: SnapshotAuthority
    ) async -> DomainWorkspaceSnapshot? {
        switch authority {
        case .canonical:
            await contexts?.canonicalWorkspaceSnapshot(workspaceID)
        case .readOverlay:
            await contexts?.workspaceSnapshot(workspaceID)
        }
    }

    /// Roots must already have been loaded through this store's ordinary bounded load API and
    /// cover the canonical workspace paths. An actually empty workspace needs no root retention.
    /// This retains resources and a read receipt, NOT writer, mutation, consent or run admission.
    func acquire(
        context identity: DomainContextIdentity,
        rootIDs: [UUID],
        authority: SnapshotAuthority = .readOverlay
    ) async throws -> Lease {
        try await acquire(workspaceID: identity.workspaceID, rootIDs: rootIDs, authority: authority) { snapshot in
            snapshot.contexts.contains { $0.metadata.identity == identity && $0.health != .removed }
        }
    }

    /// Saved starts prove a carrier in the canonical document, including stashed tabs which
    /// intentionally are not selectable domain contexts.
    func acquire(
        workspaceID: UUID,
        rootIDs: [UUID],
        authority: SnapshotAuthority = .canonical,
        admits: (DomainWorkspaceSnapshot) -> Bool
    ) async throws -> Lease {
        try Task.checkCancellation()
        guard contexts != nil else { throw Failure.authorityUnavailable }
        guard let snapshot = await workspaceSnapshot(for: workspaceID, authority: authority),
              snapshot.health != .removed, admits(snapshot)
        else { throw Failure.contextUnavailable }
        let roots = await files.rootRefs()
        let paths = snapshot.document.metadata.canonicalLoadableRepoPathSet
        let requestedIDs = Set(rootIDs)
        let requestedRoots = roots.filter { requestedIDs.contains($0.id) }
        let retainedRootPathSet = Set(requestedRoots.compactMap { StandardizedPath.canonicalWorkspaceRootPath($0.fullPath) })
        guard requestedRoots.count == requestedIDs.count,
              retainedRootPathSet == paths
        else { throw Failure.rootsChanged }
        try Task.checkCancellation()
        let retention = try await files.retainRoots(ids: rootIDs)
        do {
            #if DEBUG
                await test_afterRetainRootsBeforeRecheck?()
            #endif
            try Task.checkCancellation()
            guard let after = await workspaceSnapshot(for: workspaceID, authority: authority),
                  after.health != .removed, admits(after)
            else { throw Failure.contextChanged }
            guard after.document.metadata.canonicalLoadableRepoPathSet == retainedRootPathSet,
                  await files.isRootRetentionCurrent(retention)
            else { throw Failure.rootsChanged }
            try Task.checkCancellation()
            return Lease(
                resources: self, snapshot: after, snapshotAuthority: authority,
                roots: requestedRoots, retention: retention
            )
        } catch {
            await files.releaseRootRetention(retention)
            throw error
        }
    }

    @MainActor
    final class Lease {
        let resources: AgentHostWorkspaceResources
        let snapshot: DomainWorkspaceSnapshot
        let snapshotAuthority: SnapshotAuthority
        let roots: [WorkspaceRootRef]
        private let retention: WorkspaceFileContextStore.RootRetention
        private let rootOwner: Lease?
        private(set) var isReleased = false

        fileprivate init(
            resources: AgentHostWorkspaceResources,
            snapshot: DomainWorkspaceSnapshot,
            snapshotAuthority: SnapshotAuthority,
            roots: [WorkspaceRootRef],
            retention: WorkspaceFileContextStore.RootRetention,
            rootOwner: Lease? = nil
        ) {
            self.resources = resources
            self.snapshot = snapshot
            self.snapshotAuthority = snapshotAuthority
            self.roots = roots
            self.retention = retention
            self.rootOwner = rootOwner
        }

        /// Root lifetime revocation is independently readable after any actor hop. Context
        /// document currency remains the domain authority's async check, never a local mirror.
        var rootsAreCurrent: Bool {
            !isReleased && retention.rootLifetimesAreCurrent && (rootOwner?.rootsAreCurrent ?? true)
        }

        /// The same retained roots can outlive a presentation/document revision. Mutation
        /// callers must prove their canonical carrier separately, never reacquire replacement roots.
        func retainedRootsAreCurrent() async -> Bool {
            guard rootsAreCurrent, await resources.files.isRootRetentionCurrent(retention) else { return false }
            return rootsAreCurrent
        }

        func isCurrent() async -> Bool {
            guard rootsAreCurrent,
                  await resources.workspaceSnapshot(
                      for: snapshot.document.workspaceID, authority: snapshotAuthority
                  ) == snapshot
            else { return false }
            return await retainedRootsAreCurrent()
        }

        /// A request captures fresh canonical bytes while borrowing this activation's existing
        /// root retention. Context edits do not allocate another root lease or update old receipts.
        func capture(context: DomainContextIdentity) async throws -> Lease {
            try await capture(workspaceID: context.workspaceID) { current in
                current.contexts.contains { $0.metadata.identity == context && $0.health != .removed }
            }
        }

        func capture(
            workspaceID: UUID,
            authority: SnapshotAuthority? = nil,
            admits: (DomainWorkspaceSnapshot) -> Bool
        ) async throws -> Lease {
            let effectiveAuthority = authority ?? snapshotAuthority
            try Task.checkCancellation()
            guard rootsAreCurrent, workspaceID == snapshot.document.workspaceID,
                  let current = await resources.workspaceSnapshot(for: workspaceID, authority: effectiveAuthority),
                  current.health != .removed, admits(current)
            else { throw Failure.contextUnavailable }
            let retainedRootPathSet = Set(roots.compactMap { StandardizedPath.canonicalWorkspaceRootPath($0.fullPath) })
            guard current.document.metadata.canonicalLoadableRepoPathSet == retainedRootPathSet,
                  await resources.files.isRootRetentionCurrent(retention), rootsAreCurrent
            else { throw Failure.rootsChanged }
            guard let after = await resources.workspaceSnapshot(for: workspaceID, authority: effectiveAuthority),
                  after.health != .removed, admits(after)
            else { throw Failure.contextChanged }
            guard after.document.metadata.canonicalLoadableRepoPathSet == retainedRootPathSet else {
                throw Failure.rootsChanged
            }
            try Task.checkCancellation()
            guard rootsAreCurrent else { throw Failure.rootsChanged }
            return Lease(
                resources: resources, snapshot: after, snapshotAuthority: effectiveAuthority,
                roots: roots, retention: retention, rootOwner: rootOwner ?? self
            )
        }

        func release() async {
            guard !isReleased else { return }
            isReleased = true
            if rootOwner == nil { await resources.files.releaseRootRetention(retention) }
        }
    }
}
