import Foundation
import RepoPromptDomainRuntime
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

/// Retains file roots for execution against the existing domain authority. The lease
/// proves readable resources, not an Agent writer or permission to mutate a workspace.
@MainActor
struct AgentHostWorkspaceResources {
    enum Failure: Error { case authorityUnavailable, contextUnavailable, rootsChanged, contextChanged }

    let files: WorkspaceFileContextStore
    let contexts: DomainContextStore?

    /// Roots must already have been loaded through this store's ordinary bounded load API and
    /// cover the canonical workspace paths. An actually empty workspace needs no root retention.
    /// This retains resources and a read receipt, NOT writer, mutation, consent or run admission.
    func acquire(context identity: DomainContextIdentity, rootIDs: [UUID]) async throws -> Lease {
        try await acquire(workspaceID: identity.workspaceID, rootIDs: rootIDs) { snapshot in
            snapshot.contexts.contains { $0.metadata.identity == identity && $0.health != .removed }
        }
    }

    /// Saved starts prove a carrier in the canonical document, including stashed tabs which
    /// intentionally are not selectable domain contexts.
    func acquire(
        workspaceID: UUID, rootIDs: [UUID], admits: (DomainWorkspaceSnapshot) -> Bool
    ) async throws -> Lease {
        try Task.checkCancellation()
        guard let contexts else { throw Failure.authorityUnavailable }
        guard let snapshot = await contexts.workspaceSnapshot(workspaceID),
              snapshot.health != .removed, admits(snapshot)
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
            guard let latest = await contexts.workspaceSnapshot(workspaceID),
                  latest.isExecutionEquivalent(to: snapshot),
                  admits(latest)
            else { throw Failure.contextChanged }
            guard await files.isRootRetentionCurrent(retention) else { throw Failure.rootsChanged }
            try Task.checkCancellation()
            return Lease(resources: self, snapshot: latest, roots: requestedRoots, retention: retention)
        } catch {
            await files.releaseRootRetention(retention)
            throw error
        }
    }

    @MainActor
    final class Lease {
        let resources: AgentHostWorkspaceResources
        let snapshot: DomainWorkspaceSnapshot
        let roots: [WorkspaceRootRef]
        private let retention: WorkspaceFileContextStore.RootRetention
        private let rootOwner: Lease?
        private(set) var isReleased = false

        fileprivate init(resources: AgentHostWorkspaceResources, snapshot: DomainWorkspaceSnapshot, roots: [WorkspaceRootRef], retention: WorkspaceFileContextStore.RootRetention, rootOwner: Lease? = nil) {
            self.resources = resources
            self.snapshot = snapshot
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
                  let current = await resources.contexts?.workspaceSnapshot(snapshot.document.workspaceID),
                  current.isExecutionEquivalent(to: snapshot)
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

        func capture(workspaceID: UUID, admits: (DomainWorkspaceSnapshot) -> Bool) async throws -> Lease {
            try Task.checkCancellation()
            guard rootsAreCurrent, workspaceID == snapshot.document.workspaceID,
                  let current = await resources.contexts?.workspaceSnapshot(workspaceID),
                  current.health != .removed, admits(current)
            else { throw Failure.contextUnavailable }
            let originalPaths = Set(snapshot.document.metadata.repoPaths.map { ($0 as NSString).standardizingPath })
            guard Set(current.document.metadata.repoPaths.map { ($0 as NSString).standardizingPath }) == originalPaths,
                  await resources.files.isRootRetentionCurrent(retention), rootsAreCurrent
            else { throw Failure.rootsChanged }
            guard let latest = await resources.contexts?.workspaceSnapshot(workspaceID),
                  latest.isExecutionEquivalent(to: current),
                  admits(latest)
            else { throw Failure.contextChanged }
            try Task.checkCancellation()
            guard rootsAreCurrent else { throw Failure.rootsChanged }
            return Lease(resources: resources, snapshot: latest, roots: roots, retention: retention, rootOwner: rootOwner ?? self)
        }

        func release() async {
            guard !isReleased else { return }
            isReleased = true
            if rootOwner == nil { await resources.files.releaseRootRetention(retention) }
        }
    }
}

extension WorkspaceModel {
    /// Returns a copy with presentation/metadata-only fields normalized so two canonical
    /// snapshots can be compared for execution- and structure-relevant equality.
    ///
    /// Normalized fields mirror `WorkspaceManagerViewModel.ComposeTabPresentation` (`name`,
    /// `lastModified`, `isPinned`, `pinnedOrder`, `sidebarGroup`, `sidebarGroupOrder`) plus
    /// workspace save/focus metadata (`dateModified`, `lastUsed`, `activeComposeTabID`).
    /// Workspace identity, name, roots, storage paths, stashed tabs, tab membership, carrier
    /// bindings (`activeAgentSessionID`), selections, prompt text, and context configuration
    /// remain exact so real workspace or context conflicts still fail closed.
    func normalizedForExecutionEquivalence() -> WorkspaceModel {
        var copy = self
        let sentinelDate = Date(timeIntervalSince1970: 0)
        copy.dateModified = sentinelDate
        copy.lastUsed = sentinelDate
        copy.activeComposeTabID = nil
        for index in copy.composeTabs.indices {
            copy.composeTabs[index].name = ""
            copy.composeTabs[index].lastModified = sentinelDate
            copy.composeTabs[index].isPinned = false
            copy.composeTabs[index].pinnedOrder = nil
            copy.composeTabs[index].sidebarGroup = nil
            copy.composeTabs[index].sidebarGroupOrder = nil
        }
        return copy
    }
}

extension DomainWorkspaceSnapshot {
    /// Returns true when `other` represents the same execution and structural workspace state,
    /// ignoring compose-tab presentation and workspace save/focus metadata-only edits.
    func isExecutionEquivalent(to other: DomainWorkspaceSnapshot) -> Bool {
        if self == other { return true }
        guard health != .removed, other.health != .removed, health == other.health,
              document.workspaceID == other.document.workspaceID,
              document.fileURL == other.document.fileURL,
              document.metadata.repoPaths == other.document.metadata.repoPaths,
              contexts.count == other.contexts.count
        else { return false }
        for (lhs, rhs) in zip(contexts, other.contexts) {
            guard lhs.metadata.identity == rhs.metadata.identity,
                  lhs.health != .removed, rhs.health != .removed,
                  lhs.health == rhs.health
            else { return false }
        }
        if document.documentBytes == other.document.documentBytes { return true }
        guard let lhsWorkspace = try? JSONDecoder().decode(WorkspaceModel.self, from: document.documentBytes),
              let rhsWorkspace = try? JSONDecoder().decode(WorkspaceModel.self, from: other.document.documentBytes),
              !lhsWorkspace.composeTabsDecodeWasLossy,
              !rhsWorkspace.composeTabsDecodeWasLossy
        else { return false }
        return lhsWorkspace.normalizedForExecutionEquivalence() == rhsWorkspace.normalizedForExecutionEquivalence()
    }
}
