import Foundation
import RepoPromptRuntimeModel
import RepoPromptShared

public struct OwnedResourceReconciliationReport: Codable, Hashable, Sendable {
    public let inspected: Int
    public let transitioned: Int
    public let deleted: Int
    public let quarantined: Int
    public let failed: Int
    public let observedAt: Date

    public init(inspected: Int, transitioned: Int, deleted: Int, quarantined: Int, failed: Int, observedAt: Date) {
        self.inspected = inspected
        self.transitioned = transitioned
        self.deleted = deleted
        self.quarantined = quarantined
        self.failed = failed
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case inspected, transitioned, deleted, quarantined, failed, observedAt
    }
}

public actor OwnedResourceReconciliationService {
    private let repository: any OwnedResourceRepository
    private let artifactRoot: String
    private let worktreeRoot: String
    private let providerHomeRoot: String?
    private let providerOutputRoot: String?
    private let projectRoot: String?
    private let projectRootIdentity: String?
    private let pinnedProjectRoot: PinnedFilesystemRoot?
    private let filesystem: any FilesystemAuthorityPort
    private let runner: any WorkspaceCommandRunning
    private let gitExecutable: String

    public init(
        repository: any OwnedResourceRepository,
        artifactRoot: String,
        worktreeRoot: String,
        providerHomeRoot: String? = nil,
        providerOutputRoot: String? = nil,
        projectRoot: String? = nil,
        filesystem: any FilesystemAuthorityPort = LocalFilesystemAuthority(),
        runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(),
        gitExecutable: String = "/usr/bin/git"
    ) throws {
        self.repository = repository
        self.artifactRoot = URL(fileURLWithPath: artifactRoot).standardizedFileURL.path
        self.worktreeRoot = URL(fileURLWithPath: worktreeRoot).standardized.path
        self.providerHomeRoot = providerHomeRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.providerOutputRoot = providerOutputRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if let projectRoot {
            let standardized = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
            let canonical = try filesystem.canonicalizeRoot(standardized)
            guard canonical.path == standardized else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Configured project root or an ancestor is a symbolic link")
            }
            self.projectRoot = canonical.path
            projectRootIdentity = canonical.identity
            pinnedProjectRoot = try PinnedFilesystemRoot(path: canonical.path, identity: canonical.identity)
        } else {
            self.projectRoot = nil
            projectRootIdentity = nil
            pinnedProjectRoot = nil
        }
        self.filesystem = filesystem
        self.runner = runner
        self.gitExecutable = gitExecutable
    }

    public func reconcile(now: Date = Date()) async -> OwnedResourceReconciliationReport {
        await reconcile(now: now, recoverInterruptedPreparations: false)
    }

    public func reconcileStartup(now: Date = Date()) async throws -> OwnedResourceReconciliationReport {
        try validateProjectRootIdentity()
        return await reconcile(now: now, recoverInterruptedPreparations: true)
    }

    /// Reclaims provider files left active by an interrupted service instance.
    /// Call only after persisted provider process families have been recovered;
    /// resources owned by a still-active family are deliberately preserved.
    public func reconcileProviderResourcesAfterProcessRecovery(
        activeRunIDs: Set<UUID>,
        now: Date = Date()
    ) async -> OwnedResourceReconciliationReport {
        let records: [OwnedResourceRecord]
        do {
            records = try await repository.ownedResources(states: nil).filter {
                isProviderResource($0)
                    && $0.lifecycleState != .deleted
                    && $0.lifecycleState != .failed
                    && $0.runID.map { !activeRunIDs.contains($0) } != false
            }
        } catch {
            return .init(inspected: 0, transitioned: 0, deleted: 0, quarantined: 0, failed: 1, observedAt: now)
        }

        var transitioned = 0
        var deleted = 0
        var quarantined = 0
        var failed = 0
        for record in records {
            do {
                try removeProviderResource(record)
                _ = try await repository.transitionOwnedResource(
                    resourceID: record.resourceID,
                    expectedStates: [record.lifecycleState],
                    to: .deleted,
                    observedBytes: nil,
                    contentDigest: record.contentDigest,
                    cleanupError: nil
                )
                transitioned += 1
                deleted += 1
            } catch {
                failed += 1
                if await (try? repository.transitionOwnedResource(
                    resourceID: record.resourceID,
                    expectedStates: [record.lifecycleState],
                    to: .quarantined,
                    observedBytes: observedSize(at: record.internalPathIdentity),
                    contentDigest: record.contentDigest,
                    cleanupError: "orphaned_provider_resource_cleanup_failed"
                )) != nil {
                    transitioned += 1
                    quarantined += 1
                }
            }
        }
        return .init(
            inspected: records.count,
            transitioned: transitioned,
            deleted: deleted,
            quarantined: quarantined,
            failed: failed,
            observedAt: now
        )
    }

    private func reconcile(
        now: Date,
        recoverInterruptedPreparations: Bool
    ) async -> OwnedResourceReconciliationReport {
        var transitioned = 0
        var deleted = 0
        var quarantined = 0
        var failed = 0
        let records: [OwnedResourceRecord]
        do {
            records = try await repository.ownedResources(states: nil)
        } catch {
            return .init(inspected: 0, transitioned: 0, deleted: 0, quarantined: 0, failed: 1, observedAt: now)
        }
        for record in records where record.lifecycleState != .deleted && record.lifecycleState != .failed {
            do {
                let next = try await reconcile(
                    record,
                    now: now,
                    recoverInterruptedPreparation: recoverInterruptedPreparations
                )
                guard next != record.lifecycleState else { continue }
                _ = try await repository.transitionOwnedResource(
                    resourceID: record.resourceID,
                    expectedStates: [record.lifecycleState],
                    to: next,
                    observedBytes: observedSize(at: record.internalPathIdentity),
                    contentDigest: observedDigest(for: record),
                    cleanupError: next == .quarantined || next == .corrupt ? "resource_reconciliation_required" : nil
                )
                transitioned += 1
                if next == .deleted { deleted += 1 }
                if next == .quarantined || next == .corrupt || next == .missing { quarantined += 1 }
            } catch {
                failed += 1
                _ = try? await repository.transitionOwnedResource(
                    resourceID: record.resourceID,
                    expectedStates: [record.lifecycleState],
                    to: .quarantined,
                    observedBytes: observedSize(at: record.internalPathIdentity),
                    contentDigest: nil,
                    cleanupError: "resource_reconciliation_failed"
                )
            }
        }
        let leases = await (try? repository.worktreeMergeLeases(nonterminalOnly: true)) ?? []
        for lease in leases where lease.expiresAt <= now && lease.state != .conflicted {
            do {
                _ = try await repository.transitionWorktreeMergeLease(
                    leaseID: lease.leaseID,
                    expectedStates: [lease.state],
                    to: .conflicted,
                    conflictArtifactPath: lease.conflictArtifactPath,
                    errorCode: "merge_lease_expired"
                )
                transitioned += 1
                quarantined += 1
            } catch {
                failed += 1
            }
        }
        return .init(inspected: records.count + leases.count, transitioned: transitioned, deleted: deleted, quarantined: quarantined, failed: failed, observedAt: now)
    }

    private func reconcile(
        _ record: OwnedResourceRecord,
        now: Date,
        recoverInterruptedPreparation: Bool
    ) async throws -> OwnedResourceLifecycleState {
        let manager = FileManager.default
        let exists = resourcePaths(record).contains { manager.fileExists(atPath: $0) }
        switch record.lifecycleState {
        case .preparing:
            if exists {
                if record.kind == .artifact, artifactMatches(record) { return .prepared }
                if record.kind == .worktree, try await worktreeMatches(record, allowLegacyBackfill: false) { return .prepared }
                if isProviderResource(record), providerResourceIsSafe(record) { return .prepared }
                if record.kind == .cloneStaging, try cloneResourceIsSafe(record) {
                    if recoverInterruptedPreparation {
                        try removeCloneResource(record)
                        return .deleted
                    }
                    return .quarantined
                }
                return .quarantined
            }
            if recoverInterruptedPreparation || record.retentionDeadline.map({ $0 <= now }) == true { return .failed }
            return .preparing
        case .prepared, .cleanupPending, .quarantined:
            guard recoverInterruptedPreparation || record.retentionDeadline.map({ $0 <= now }) == true else { return record.lifecycleState }
            guard exists else { return .deleted }
            if record.kind == .artifact {
                try removeArtifact(record)
                return .deleted
            }
            if record.kind == .worktree {
                return try await removeAbandonedWorktree(record) ? .deleted : .quarantined
            }
            if isProviderResource(record) {
                try removeProviderResource(record)
                return .deleted
            }
            if record.kind == .cloneStaging {
                try removeCloneResource(record)
                return .deleted
            }
            return record.lifecycleState
        case .active:
            guard exists else { return .missing }
            if record.kind == .providerOutput,
               !resourcePaths(record).allSatisfy({ manager.fileExists(atPath: $0) })
            {
                return .corrupt
            }
            if record.kind == .artifact, !artifactMatches(record) { return .corrupt }
            if record.kind == .worktree,
               try await !worktreeMatches(record, allowLegacyBackfill: recoverInterruptedPreparation)
            {
                return .corrupt
            }
            if record.kind == .cloneStaging, try !cloneResourceIsSafe(record) { return .corrupt }
            return .active
        case .missing, .corrupt, .conflicted:
            return record.lifecycleState
        case .released:
            guard record.retentionDeadline.map({ $0 <= now }) == true else { return .released }
            return exists ? .quarantined : .deleted
        case .deleted, .failed:
            return record.lifecycleState
        }
    }

    private func artifactMatches(_ record: OwnedResourceRecord) -> Bool {
        guard isContained(record.internalPathIdentity, root: artifactRoot),
              !isSymbolicLink(record.internalPathIdentity),
              let data = try? Data(contentsOf: URL(fileURLWithPath: record.internalPathIdentity), options: [.mappedIfSafe])
        else { return false }
        return (record.observedBytes == nil || record.observedBytes == Int64(data.count))
            && (record.contentDigest == nil || record.contentDigest == PortableContentDigest.sha256Hex(data))
    }

    private func worktreeMatches(_ record: OwnedResourceRecord, allowLegacyBackfill: Bool) async throws -> Bool {
        guard isContained(record.internalPathIdentity, root: worktreeRoot),
              let bindingID = record.externalID,
              let projectID = record.projectID,
              let sessionID = record.sessionID,
              let sourceRoot = record.metadata["sourceRoot"],
              let branch = record.metadata["branch"],
              let authority = try await repository.activeOwnedWorktree(bindingID: bindingID),
              authority.projectID == projectID,
              authority.sessionID == sessionID,
              authority.physicalPath == record.internalPathIdentity,
              authority.sourceRoot == sourceRoot,
              authority.branch == branch
        else { return false }
        try PinnedFilesystemRoot.validateDirectoryChain(at: worktreeRoot)
        try PinnedFilesystemRoot.validateDirectoryChain(at: record.internalPathIdentity)
        try PinnedFilesystemRoot.validateDirectoryChain(at: sourceRoot)
        let top = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", record.internalPathIdentity, "rev-parse", "--show-toplevel"],
            workingDirectory: record.internalPathIdentity,
            maximumBytes: 65536
        )
        guard URL(fileURLWithPath: top.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path == record.internalPathIdentity else {
            return false
        }
        let registration = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", sourceRoot, "worktree", "list", "--porcelain", "-z"],
            workingDirectory: sourceRoot,
            maximumBytes: 1_048_576
        )
        let fields = registration.components(separatedBy: "\0")
        let matchingWorktrees = fields.indices.filter { fields[$0] == "worktree \(record.internalPathIdentity)" }
        guard matchingWorktrees.count == 1 else { return false }
        let start = matchingWorktrees[0] + 1
        let end = fields[start...].firstIndex(where: { $0.isEmpty || $0.hasPrefix("worktree ") }) ?? fields.endIndex
        guard fields[start ..< end].contains("branch refs/heads/\(branch)") else { return false }
        let identityDigest = try await WorktreeRuntimeIdentity.digest(path: record.internalPathIdentity, runner: runner, gitExecutable: gitExecutable)
        if let persisted = record.contentDigest { return persisted == identityDigest }
        guard allowLegacyBackfill else { return false }
        _ = try await repository.backfillActiveWorktreeContentDigest(
            resourceID: record.resourceID,
            authority: authority,
            contentDigest: identityDigest
        )
        return true
    }

    private func isProviderHomeResource(_ record: OwnedResourceRecord) -> Bool {
        record.kind == .providerHome || record.kind == .providerCredentialCopy
    }

    private func isProviderResource(_ record: OwnedResourceRecord) -> Bool {
        isProviderHomeResource(record) || record.kind == .providerOutput
    }

    private func providerResourceIsSafe(_ record: OwnedResourceRecord) -> Bool {
        let root = record.kind == .providerOutput ? providerOutputRoot : providerHomeRoot
        guard let root else { return false }
        return resourcePaths(record).allSatisfy {
            isContained($0, root: root) && !isSymbolicLink($0)
        }
    }

    private func removeProviderResource(_ record: OwnedResourceRecord) throws {
        guard providerResourceIsSafe(record) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Provider-home cleanup path is unsafe")
        }
        for path in resourcePaths(record) where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
            try DurableFilesystem.fsyncDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        }
    }

    private func cloneResourceIsSafe(_ record: OwnedResourceRecord) throws -> Bool {
        guard let projectRoot else { return false }
        try validateProjectRootIdentity()
        return resourcePaths(record).allSatisfy {
            isContained($0, root: projectRoot)
                && (try? filesystem.contains(root: projectRoot, candidate: $0)) == true
                && !isSymbolicLink($0)
        }
    }

    private func removeCloneResource(_ record: OwnedResourceRecord) throws {
        guard try cloneResourceIsSafe(record), let pinnedProjectRoot else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Project clone cleanup path is unsafe")
        }
        for path in resourcePaths(record) {
            try validateProjectRootIdentity()
            try pinnedProjectRoot.removeTree(at: path)
        }
    }

    private func validateProjectRootIdentity() throws {
        guard let projectRoot, let projectRootIdentity else { return }
        let canonical = try filesystem.canonicalizeRoot(projectRoot)
        guard canonical.path == projectRoot, canonical.identity == projectRootIdentity else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Configured project root identity changed")
        }
    }

    private func removeArtifact(_ record: OwnedResourceRecord) throws {
        guard isContained(record.internalPathIdentity, root: artifactRoot), !isSymbolicLink(record.internalPathIdentity) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Artifact cleanup path is unsafe")
        }
        try FileManager.default.removeItem(atPath: record.internalPathIdentity)
        try DurableFilesystem.fsyncDirectory(URL(fileURLWithPath: record.internalPathIdentity).deletingLastPathComponent().path)
    }

    private func removeAbandonedWorktree(_ record: OwnedResourceRecord) async throws -> Bool {
        guard isContained(record.internalPathIdentity, root: worktreeRoot),
              !isSymbolicLink(record.internalPathIdentity),
              let sourceRoot = record.metadata["sourceRoot"]
        else { return false }
        let status = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", record.internalPathIdentity, "status", "--porcelain"],
            workingDirectory: record.internalPathIdentity,
            maximumBytes: 65536
        )
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        _ = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", sourceRoot, "worktree", "remove", record.internalPathIdentity],
            workingDirectory: sourceRoot,
            maximumBytes: 65536
        )
        _ = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", sourceRoot, "worktree", "prune"],
            workingDirectory: sourceRoot,
            maximumBytes: 65536
        )
        return !FileManager.default.fileExists(atPath: record.internalPathIdentity)
    }

    private func isContained(_ path: String, root: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardized.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return standardized.hasPrefix(prefix) && standardized != root
    }

    private func isSymbolicLink(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func observedSize(at path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    private func resourcePaths(_ record: OwnedResourceRecord) -> [String] {
        [record.internalPathIdentity, record.temporaryPathIdentity].compactMap(\.self)
    }

    private func observedDigest(for record: OwnedResourceRecord) -> String? {
        guard record.kind == .artifact,
              let data = try? Data(contentsOf: URL(fileURLWithPath: record.internalPathIdentity), options: [.mappedIfSafe])
        else { return record.contentDigest }
        return PortableContentDigest.sha256Hex(data)
    }
}
