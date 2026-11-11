import Foundation
import MCP
import RepoPromptVCS
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

extension AgentSessionWorktreeRuntime {
    func mergeAuthorizedRoots(_ admission: Admission) async throws -> [WorkspaceRootRef] {
        try admission.requireCurrent()
        guard let store = admission.resources.store else {
            throw MCPError.invalidParams("Worktree merge requires an authorized workspace root.")
        }
        let lookup = await AgentSessionProviderInputRuntime.WorkspaceSource(
            store: store,
            lookupSource: .init(activeAgentSessionID: admission.command.identity.sessionID, worktreeBindings: admission.bindings)
        ).lookupContext()
        try admission.requireCurrent()
        var roots = await store.rootRefs(scope: lookup.rootScope)
        try admission.requireCurrent()
        var seen = Set(roots.map { GitRepoRootAuthorization.canonicalPath($0.standardizedFullPath) })
        for binding in admission.bindings {
            let path = GitRepoRootAuthorization.canonicalPath(binding.worktreeRootPath)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            roots.append(WorkspaceRootRef(
                id: UUID(uuidString: binding.id) ?? UUID(),
                name: binding.worktreeName ?? binding.logicalRootName ?? binding.visualLabel ?? URL(fileURLWithPath: path).lastPathComponent,
                fullPath: path
            ))
        }
        guard !roots.isEmpty else { throw MCPError.invalidParams("Worktree merge requires at least one authorized workspace root.") }
        return roots
    }

    func mergeEndpoint(from binding: AgentSessionWorktreeBinding) async throws -> GitWorktreeMergeEndpoint {
        let descriptors = try await VCSService.shared.listGitWorktrees(at: URL(fileURLWithPath: binding.worktreeRootPath))
        let path = GitRepoRootAuthorization.canonicalPath(binding.worktreeRootPath)
        guard let descriptor = descriptors.first(where: {
            $0.worktreeID == binding.worktreeID && GitRepoRootAuthorization.canonicalPath($0.path) == path
        }) else { throw MCPError.invalidParams("Source worktree binding is no longer available: \(binding.worktreeRootPath)") }
        let endpoint = try GitWorktreeMergeEndpoint(descriptor: descriptor)
        guard endpoint.repositoryID == binding.repositoryID else {
            throw MCPError.invalidParams("Source worktree binding repository identity changed: \(binding.worktreeRootPath)")
        }
        if let head = binding.head?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty, head != endpoint.head {
            throw MCPError.invalidParams("Source worktree binding HEAD changed: \(binding.worktreeRootPath)")
        }
        return endpoint
    }

    func requireAuthorizedMergeEndpoint(_ endpoint: GitWorktreeMergeEndpoint, roots: [WorkspaceRootRef], label: String) async throws {
        if GitRepoRootAuthorization.isPathWithinAuthorizedRoots(endpoint.path, roots: roots.map(\.standardizedFullPath)) { return }
        do {
            _ = try await WorktreeMergeEndpointValidation.resolveAuthorizedDescriptor(for: endpoint, roots: roots)
        } catch {
            throw MCPError.invalidParams("\(label) worktree path must be inside an authorized workspace root or advertised by an authorized repository. Received: \(endpoint.path).")
        }
    }

    func resolveMergeTarget(selector: String?, source: GitWorktreeMergeEndpoint, authorizedRoots: [WorkspaceRootRef]) async throws -> GitWorktreeMergeEndpoint {
        let sourceRepo = GitRepoDescriptor(rootURL: source.url)
        var repositories = [sourceRepo]
        var seen = Set([GitRepoRootAuthorization.canonicalPath(sourceRepo.rootPath)])
        for root in authorizedRoots {
            guard let resolved = await VCSService.shared.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)) else { continue }
            let descriptor = GitRepoDescriptor(rootURL: resolved.rootURL)
            if seen.insert(GitRepoRootAuthorization.canonicalPath(descriptor.rootPath)).inserted { repositories.append(descriptor) }
        }
        do {
            let descriptor = try await GitRepoTargetResolver().resolveWorktree(
                selector: selector ?? "@main", repo: sourceRepo, allRepos: repositories, authorizedRoots: authorizedRoots
            )
            return try GitWorktreeMergeEndpoint(descriptor: descriptor)
        } catch let error as GitRepoTargetResolverError { throw MCPError.invalidParams(error.message) }
    }

    func revalidatedMergeEndpoint(_ endpoint: GitWorktreeMergeEndpoint, label: String) async throws -> GitWorktreeMergeEndpoint {
        let descriptors = try await VCSService.shared.listGitWorktrees(at: endpoint.url)
        guard let descriptor = descriptors.first(where: { WorktreeMergeEndpointValidation.matches(endpoint, descriptor: $0) }) else {
            throw MCPError.invalidParams("\(label) worktree identity or canonical path changed before it was used: \(endpoint.path)")
        }
        return try GitWorktreeMergeEndpoint(descriptor: descriptor)
    }

    func checkedMergeEndpoints(source: GitWorktreeMergeEndpoint, target: GitWorktreeMergeEndpoint, admission: Admission) async throws -> (source: GitWorktreeMergeEndpoint, target: GitWorktreeMergeEndpoint) {
        let roots = try await mergeAuthorizedRoots(admission)
        let checkedSource = try await revalidatedMergeEndpoint(source, label: "Source")
        try admission.requireCurrent()
        let checkedTarget = try await revalidatedMergeEndpoint(target, label: "Target")
        try await requireAuthorizedMergeEndpoint(checkedSource, roots: roots, label: "Source")
        try await requireAuthorizedMergeEndpoint(checkedTarget, roots: roots, label: "Target")
        try admission.requireCurrent()
        return (checkedSource, checkedTarget)
    }

    func revalidatedMergePreview(_ preview: GitWorktreeMergePreview) async throws -> GitWorktreeMergePreview {
        let source = try await revalidatedMergeEndpoint(preview.inspection.source, label: "Source")
        let target = try await revalidatedMergeEndpoint(preview.inspection.target, label: "Target")
        guard WorktreeMergeEndpointValidation.sameIdentity(preview.inspection.source, source),
              WorktreeMergeEndpointValidation.sameIdentity(preview.inspection.target, target)
        else {
            throw MCPError.invalidParams("Worktree merge endpoints changed before preview persistence.")
        }
        return GitWorktreeMergePreview(operationID: preview.operationID, inspection: GitWorktreeMergeInspection(
            source: source, target: target, mergeBase: preview.inspection.mergeBase,
            sourceHead: source.head, targetHead: target.head,
            sourceFingerprint: preview.inspection.sourceFingerprint, targetFingerprint: preview.inspection.targetFingerprint,
            blockers: preview.inspection.blockers, conflictPrediction: preview.inspection.conflictPrediction,
            summary: preview.inspection.summary, visualization: preview.inspection.visualization
        ), artifacts: preview.artifacts)
    }

    func mergePreview(from operation: AgentSessionWorktreeMergeOperation, admission: Admission) async throws -> GitWorktreeMergePreview {
        guard let sourceFingerprint = operation.sourceFingerprint, let targetFingerprint = operation.targetFingerprint else {
            throw MCPError.invalidParams("Worktree merge preview fingerprints are unavailable; run manage_worktree preview again.")
        }
        let endpoints = try await checkedMergeEndpoints(source: operation.source, target: operation.target, admission: admission)
        let current = try await VCSService.shared.inspectGitWorktreeMerge(.init(source: endpoints.source, target: endpoints.target))
        let checked = try await checkedMergeEndpoints(source: current.source, target: current.target, admission: admission)
        return GitWorktreeMergePreview(operationID: operation.id, inspection: GitWorktreeMergeInspection(
            source: checked.source, target: checked.target, mergeBase: operation.mergeBase,
            sourceHead: checked.source.head, targetHead: checked.target.head,
            sourceFingerprint: sourceFingerprint, targetFingerprint: targetFingerprint,
            blockers: current.blockers, conflictPrediction: current.conflictPrediction,
            summary: operation.summary ?? current.summary, visualization: operation.visualization ?? current.visualization
        ), artifacts: operation.previewArtifacts)
    }
}
