import Foundation
import MCP

struct MCPGitArtifactAdvertisementCheckout: Hashable {
    let logicalRootPath: String
    let logicalRootName: String
    let physicalWorktreeRootPath: String
    let repositoryID: String
    let worktreeID: String

    init(_ checkout: FrozenBoundCheckoutIdentity) {
        logicalRootPath = StandardizedPath.absolute(checkout.logicalRootPath)
        logicalRootName = checkout.logicalRootName
        physicalWorktreeRootPath = StandardizedPath.absolute(checkout.physicalWorktreeRootPath)
        repositoryID = checkout.repositoryID
        worktreeID = checkout.worktreeID
    }

    var sortKey: String {
        [logicalRootPath, logicalRootName, physicalWorktreeRootPath, repositoryID, worktreeID]
            .joined(separator: "\u{1f}")
    }
}

struct MCPGitArtifactAdvertisementVisibleCheckout: Hashable {
    let workspaceRoot: WorkspaceRootRef
    let visibleRootPath: String
    let repositoryRootPath: String
    let worktreeRootPath: String
    let commonGitDirectoryPath: String
    let mainWorktreeRootPath: String?
    let repositoryID: String
    let worktreeID: String
    let kind: FrozenVisibleGitCheckoutKind

    init(_ checkout: FrozenVisibleGitCheckoutIdentity) {
        workspaceRoot = checkout.workspaceRoot
        visibleRootPath = checkout.visibleRootPath
        repositoryRootPath = checkout.repositoryRootPath
        worktreeRootPath = checkout.worktreeRootPath
        commonGitDirectoryPath = checkout.commonGitDirectoryPath
        mainWorktreeRootPath = checkout.mainWorktreeRootPath
        repositoryID = checkout.repositoryID
        worktreeID = checkout.worktreeID
        kind = checkout.kind
    }

    var sortKey: String {
        [
            visibleRootPath,
            repositoryRootPath,
            worktreeRootPath,
            commonGitDirectoryPath,
            mainWorktreeRootPath ?? "",
            repositoryID,
            worktreeID,
            workspaceRoot.id.uuidString,
            String(describing: kind)
        ].joined(separator: "\u{1f}")
    }
}

struct MCPGitArtifactAdvertisementProvenance: Equatable {
    let identity: WorkspaceSelectionIdentity
    let gitDataRoot: WorkspaceRootRef
    let sessionID: UUID?
    let boundCheckouts: [MCPGitArtifactAdvertisementCheckout]
    let visibleRootCheckouts: [MCPGitArtifactAdvertisementVisibleCheckout]
    let canonicalWorkspaceRootPaths: [String]

    init(identity: WorkspaceSelectionIdentity, capability: SelectedGitArtifactCapability) {
        self.identity = identity
        gitDataRoot = capability.gitDataRoot
        sessionID = capability.sessionID
        boundCheckouts = capability.boundCheckouts
            .map(MCPGitArtifactAdvertisementCheckout.init)
            .sorted { $0.sortKey < $1.sortKey }
        visibleRootCheckouts = capability.visibleRootCheckouts
            .map(MCPGitArtifactAdvertisementVisibleCheckout.init)
            .sorted { $0.sortKey < $1.sortKey }
        canonicalWorkspaceRootPaths = capability.canonicalWorkspaceRootPaths
            .map(StandardizedPath.absolute)
            .sorted()
    }

    func matches(_ capability: SelectedGitArtifactCapability) -> Bool {
        self == MCPGitArtifactAdvertisementProvenance(
            identity: WorkspaceSelectionIdentity(
                workspaceID: capability.workspaceID,
                tabID: capability.creatorTabID
            ),
            capability: capability
        )
    }
}

struct MCPGitArtifactAdvertisementGrant: Equatable {
    let generation: UInt64
    let provenance: MCPGitArtifactAdvertisementProvenance
    let artifactsByAlias: [String: GitDiffPublishedArtifact]
}

struct MCPGitArtifactAdvertisementSnapshot: Equatable {
    let identity: WorkspaceSelectionIdentity
    let generation: UInt64
    let provenance: MCPGitArtifactAdvertisementProvenance
}

enum MCPGitArtifactGrantMismatch: Equatable {
    case neverAdvertised
    case wrongWorkspace
    case wrongTab
    case sessionMismatch
    case checkoutBindingMismatch
    case staleGeneration

    var diagnosticLabel: String {
        switch self {
        case .neverAdvertised:
            "alias was never advertised for this tab"
        case .wrongWorkspace:
            "alias belongs to a different workspace"
        case .wrongTab:
            "alias belongs to a different tab"
        case .sessionMismatch:
            "artifact advertisement session no longer matches"
        case .checkoutBindingMismatch:
            "artifact advertisement checkout provenance no longer matches"
        case .staleGeneration:
            "artifact advertisement was replaced"
        }
    }
}

enum MCPGitArtifactGrantLookup: Equatable {
    case granted(
        artifact: GitDiffPublishedArtifact,
        snapshot: MCPGitArtifactAdvertisementSnapshot
    )
    case rejected(MCPGitArtifactGrantMismatch)
}

/// Window-lifetime, tab-scoped authority for aliases actually advertised by successful Git replies.
///
/// The registry is intentionally not persisted and provides no enumeration surface to MCP clients.
@MainActor
final class MCPGitArtifactAdvertisementRegistry {
    private var nextGeneration: UInt64 = 0
    private var grantsByIdentity: [WorkspaceSelectionIdentity: MCPGitArtifactAdvertisementGrant] = [:]

    func replace(
        identity: WorkspaceSelectionIdentity,
        capability: SelectedGitArtifactCapability,
        artifacts: [GitDiffPublishedArtifact]
    ) throws -> MCPGitArtifactAdvertisementSnapshot {
        guard identity.workspaceID == capability.workspaceID,
              identity.tabID == capability.creatorTabID
        else {
            throw MCPError.internalError("Git artifact advertisement identity does not match the frozen capability")
        }

        let rootPath = capability.gitDataRoot.standardizedFullPath
        var artifactsByAlias: [String: GitDiffPublishedArtifact] = [:]
        for artifact in artifacts {
            guard artifact.selectionDisposition == .primaryAutoSelect
                || artifact.selectionDisposition == .advertisedSelectable
            else { continue }
            guard let alias = artifact.clientAlias,
                  alias == "_git_data/\(artifact.gitDataRelativePath)",
                  alias.hasPrefix("_git_data/"),
                  GitDiffArtifactPathPolicy.isSafeRelativeArtifactPath(artifact.gitDataRelativePath),
                  artifact.absolutePath == StandardizedPath.join(
                      standardizedRoot: rootPath,
                      standardizedRelativePath: artifact.gitDataRelativePath
                  )
            else { continue }
            if artifactsByAlias[alias] == nil {
                artifactsByAlias[alias] = artifact
            }
        }

        nextGeneration &+= 1
        if nextGeneration == 0 {
            nextGeneration = 1
        }
        let provenance = MCPGitArtifactAdvertisementProvenance(
            identity: identity,
            capability: capability
        )
        let grant = MCPGitArtifactAdvertisementGrant(
            generation: nextGeneration,
            provenance: provenance,
            artifactsByAlias: artifactsByAlias
        )
        grantsByIdentity[identity] = grant
        return MCPGitArtifactAdvertisementSnapshot(
            identity: identity,
            generation: grant.generation,
            provenance: provenance
        )
    }

    func lookup(
        exactAlias: String,
        identity: WorkspaceSelectionIdentity,
        capability: SelectedGitArtifactCapability
    ) -> MCPGitArtifactGrantLookup {
        guard identity.workspaceID == capability.workspaceID else {
            return .rejected(.wrongWorkspace)
        }
        guard identity.tabID == capability.creatorTabID else {
            return .rejected(.wrongTab)
        }

        guard let grant = grantsByIdentity[identity] else {
            return .rejected(classifyForeignAlias(exactAlias, identity: identity))
        }
        guard grant.provenance.sessionID == capability.sessionID else {
            grantsByIdentity.removeValue(forKey: identity)
            return .rejected(.sessionMismatch)
        }

        let current = MCPGitArtifactAdvertisementProvenance(
            identity: identity,
            capability: capability
        )
        guard grant.provenance.gitDataRoot == current.gitDataRoot,
              grant.provenance.boundCheckouts == current.boundCheckouts,
              grant.provenance.visibleRootCheckouts == current.visibleRootCheckouts,
              grant.provenance.canonicalWorkspaceRootPaths == current.canonicalWorkspaceRootPaths
        else {
            grantsByIdentity.removeValue(forKey: identity)
            return .rejected(.checkoutBindingMismatch)
        }
        guard let artifact = grant.artifactsByAlias[exactAlias] else {
            return .rejected(classifyForeignAlias(exactAlias, identity: identity))
        }

        return .granted(
            artifact: artifact,
            snapshot: MCPGitArtifactAdvertisementSnapshot(
                identity: identity,
                generation: grant.generation,
                provenance: grant.provenance
            )
        )
    }

    func isCurrent(_ snapshot: MCPGitArtifactAdvertisementSnapshot) -> Bool {
        guard let grant = grantsByIdentity[snapshot.identity] else { return false }
        return grant.generation == snapshot.generation
            && grant.provenance == snapshot.provenance
    }

    func invalidate(identity: WorkspaceSelectionIdentity, generation: UInt64? = nil) {
        guard let generation else {
            grantsByIdentity.removeValue(forKey: identity)
            return
        }
        guard grantsByIdentity[identity]?.generation == generation else { return }
        grantsByIdentity.removeValue(forKey: identity)
    }

    func removeTab(_ identity: WorkspaceSelectionIdentity) {
        grantsByIdentity.removeValue(forKey: identity)
    }

    func removeTab(tabID: UUID) {
        grantsByIdentity = grantsByIdentity.filter { $0.key.tabID != tabID }
    }

    func removeWorkspace(_ workspaceID: UUID) {
        grantsByIdentity = grantsByIdentity.filter { $0.key.workspaceID != workspaceID }
    }

    func retainWorkspaces(_ workspaceIDs: Set<UUID>) {
        grantsByIdentity = grantsByIdentity.filter {
            workspaceIDs.contains($0.key.workspaceID)
        }
    }

    private func classifyForeignAlias(
        _ exactAlias: String,
        identity: WorkspaceSelectionIdentity
    ) -> MCPGitArtifactGrantMismatch {
        for (otherIdentity, grant) in grantsByIdentity
            where grant.artifactsByAlias[exactAlias] != nil
        {
            if otherIdentity.workspaceID != identity.workspaceID {
                return .wrongWorkspace
            }
            if otherIdentity.tabID != identity.tabID {
                return .wrongTab
            }
        }
        return .neverAdvertised
    }
}
