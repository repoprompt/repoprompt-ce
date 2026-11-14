import Foundation
import RepoPromptDomainRuntime

struct CommandCenterSessionRow: Identifiable, Equatable {
    enum Provenance: Equatable {
        case live(DomainAgentSessionLinkEndpointIdentity, sequence: UInt64, observedAt: Date)
        case saved(recordedAt: Date)
        case unknown(String)
    }

    enum Attention: Int, CaseIterable {
        case needsYou, failed, finished, working, idle, saved, unknown

        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .failed: "Failed"
            case .finished: "Finished · review status unknown"
            case .working: "Working"
            case .idle: "Idle · review status unknown"
            case .saved: "Saved"
            case .unknown: "Unknown / unavailable"
            }
        }
    }

    struct ID: Hashable {
        let workspaceID: UUID
        let sessionID: UUID
    }

    var id: ID {
        ID(workspaceID: workspaceID, sessionID: sessionID)
    }

    let sessionID: UUID
    let workspaceID: UUID
    let tabID: UUID?
    let name: String
    let provider: String?
    let attention: Attention
    let detail: String?
    let provenance: Provenance
    var activityDate: Date = .distantPast
    var isPinned = false
    var parentSessionID: UUID?
    var createdByOverseerSessionID: UUID?
    var oversightRole: AgentSessionOversightRole = .none
}

struct CommandCenterWorkspaceRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let roots: [String]
    let unavailable: Bool
    let hidden: Bool
    let sessions: [CommandCenterSessionRow]
    let coverage: String?
    let savedCount: Int?
    let savedLimit: Int
    var catalogUnavailable = false
    var metadata: DomainWorkspaceMetadata?

    var rollup: String {
        if unavailable { return "Unavailable" }
        if let attention = sessions.map(\.attention).min(by: { $0.rawValue < $1.rawValue }) {
            return attention.title
        }
        if coverage != nil { return "Unknown" }
        return savedCount == nil ? "Saved inventory not loaded" : "No indexed saved sessions"
    }
}

struct CommandCenterSnapshot: Equatable {
    var workspaces: [CommandCenterWorkspaceRow] = []
    var catalogCoverage: String? = "Loading workspace catalog…"

    var projects: [DomainWorkspaceMetadata] {
        WorkspaceMenuPolicy.items(in: workspaces.filter { !$0.catalogUnavailable }.compactMap(\.metadata).filter { $0.consolidatedIntoWorkspaceID == nil })
    }

    var sessions: [CommandCenterSessionRow] {
        workspaces.flatMap(\.sessions)
    }

    var coverage: [String] {
        (catalogCoverage.map { [$0] } ?? []) + workspaces.compactMap { workspace in
            workspace.coverage.map { "\(workspace.name): \($0)" }
        }
    }
}

/// A pure join. A saved run-state string is deliberately never interpreted as live state.
enum CommandCenterProjection {
    struct SavedInventory: Equatable {
        struct Entry: Equatable {
            let id: UUID
            let tabID: UUID?
            let name: String
            let provider: String?
            let recordedAt: Date
            var parentSessionID: UUID?
            var createdByOverseerSessionID: UUID?
            var lastUserMessageAt: Date?
        }

        let entries: [Entry]
        let totalCount: Int
        let coverage: String?
    }

    static func build(
        catalog: DomainWorkspaceCatalogSnapshot,
        live: [AgentSessionStatusCensus.Row],
        saved: [UUID: SavedInventory],
        limits: [UUID: Int],
        unwitnessed: [AgentSessionStatusCensus.Row] = []
    ) -> CommandCenterSnapshot {
        let candidatesByID = Dictionary(grouping: live, by: { $0.sample.candidate.sessionID })
        let liveByWorkspace = Dictionary(grouping: live, by: { $0.sample.candidate.workspaceID })
        let unwitnessedByWorkspace = Dictionary(grouping: unwitnessed, by: { $0.sample.candidate.workspaceID })
        func overlayLive(_ initial: [UUID: CommandCenterSessionRow], workspaceID: UUID) -> [UUID: CommandCenterSessionRow] {
            var rows = initial
            for liveRow in liveByWorkspace[workspaceID] ?? [] {
                let candidate = liveRow.sample.candidate
                let ambiguous = (candidatesByID[candidate.sessionID]?.count ?? 0) > 1
                let eligible = !ambiguous && candidate.hasLoadedPersistedState
                    && candidate.restorationReadiness.permitsBoundOperationAndSave
                    && candidate.persistentBindingGeneration != nil
                    && !candidate.bindingTransitionInProgress && !candidate.isClosing && !candidate.isDeletionInProgress
                guard eligible, let status = liveRow.sample.status else {
                    if ambiguous || rows[candidate.sessionID] == nil {
                        let reason = ambiguous ? "Ambiguous live owners" : "Owner not ready; saved state not witnessed live"
                        rows[candidate.sessionID] = CommandCenterSessionRow(
                            sessionID: candidate.sessionID, workspaceID: workspaceID, tabID: nil,
                            name: candidate.resolvedDisplayName, provider: candidate.providerDisplayName,
                            attention: .unknown, detail: reason, provenance: .unknown(reason)
                        )
                    }
                    continue
                }
                let attention: CommandCenterSessionRow.Attention = if status.pendingInteractionKind != nil || status.status == .awaitingUser {
                    .needsYou
                } else {
                    switch liveRow.sample.outcome {
                    case .failed: .failed
                    case .completed: .finished
                    case .running: .working
                    case .awaitingUser: .needsYou
                    case .cancelled, .some(.none): status.status == .running ? .working : .idle
                    case nil: .unknown
                    }
                }
                rows[candidate.sessionID] = CommandCenterSessionRow(
                    sessionID: candidate.sessionID, workspaceID: workspaceID, tabID: candidate.tabID,
                    name: candidate.resolvedDisplayName, provider: candidate.providerDisplayName,
                    attention: attention, detail: status.pendingInteractionKind?.rawValue,
                    provenance: .live(candidate.domainEndpoint, sequence: liveRow.sequence, observedAt: liveRow.observedAt),
                    activityDate: status.lastActivityAt ?? rows[candidate.sessionID]?.activityDate ?? .distantPast,
                    parentSessionID: candidate.parentSessionID, createdByOverseerSessionID: candidate.createdByOverseerSessionID,
                    oversightRole: liveRow.sample.oversightRole
                )
            }
            // Losing a live witness is not a deletion. Until a saved index supplies the row, keep
            // an honest coverage placeholder instead of silently shrinking the inbox.
            for prior in unwitnessedByWorkspace[workspaceID] ?? [] {
                let candidate = prior.sample.candidate
                guard rows[candidate.sessionID] == nil else { continue }
                let reason = "Live owner no longer witnessed; saved inventory could not establish this session"
                rows[candidate.sessionID] = CommandCenterSessionRow(
                    sessionID: candidate.sessionID, workspaceID: workspaceID, tabID: candidate.tabID,
                    name: candidate.resolvedDisplayName, provider: candidate.providerDisplayName,
                    attention: .unknown, detail: reason, provenance: .unknown(reason)
                )
            }
            return rows
        }
        var workspaceRows = catalog.workspaces.map { workspace in
            let metadata = workspace.document.metadata
            let inventory = saved[metadata.workspaceID]
            var rows = Dictionary(inventory?.entries.map { entry in
                (entry.id, CommandCenterSessionRow(
                    sessionID: entry.id, workspaceID: metadata.workspaceID, tabID: entry.tabID,
                    name: entry.name, provider: entry.provider, attention: .saved, detail: nil,
                    provenance: .saved(recordedAt: entry.recordedAt), activityDate: entry.lastUserMessageAt ?? entry.recordedAt,
                    parentSessionID: entry.parentSessionID, createdByOverseerSessionID: entry.createdByOverseerSessionID
                ))
            } ?? [], uniquingKeysWith: { first, _ in first })
            rows = overlayLive(rows, workspaceID: metadata.workspaceID)
            // The canonical compose-tab document owns pinning; the metadata index does not.
            let pinnedIDs = Set(metadata.agentIdentityClaims.filter(\.isPinned).compactMap(\.activeAgentSessionID))
            for id in rows.keys {
                rows[id]?.isPinned = pinnedIDs.contains(id)
            }
            let coverageMessages = [
                catalog.unavailableWorkspaceIDs.contains(metadata.workspaceID) ? "Workspace unavailable in canonical catalog" : nil,
                workspace.health == .writable ? nil : "Workspace health: \(workspace.health)",
                rows.values.contains(where: { $0.attention == .unknown }) ? "Some owners are ambiguous or unavailable" : nil,
                inventory?.coverage
            ].compactMap(\.self)
            return CommandCenterWorkspaceRow(
                id: metadata.workspaceID, name: metadata.name, roots: metadata.repoPaths,
                unavailable: catalog.unavailableWorkspaceIDs.contains(metadata.workspaceID) || workspace.health != .writable, hidden: metadata.isHiddenInMenus || metadata.isSystemWorkspace,
                sessions: rows.values.sorted {
                    if $0.attention != $1.attention { return $0.attention.rawValue < $1.attention.rawValue }
                    return $0.sessionID.uuidString < $1.sessionID.uuidString
                },
                coverage: coverageMessages.isEmpty ? nil : coverageMessages.joined(separator: "; "),
                savedCount: inventory?.totalCount,
                savedLimit: limits[metadata.workspaceID] ?? 100,
                catalogUnavailable: catalog.unavailableWorkspaceIDs.contains(metadata.workspaceID),
                metadata: metadata
            )
        }
        // #1705 correctly excludes ephemeral projects from durable membership, not from a
        // human's live census. These presentation-only groups never become picker projects.
        let catalogIDs = Set(catalog.workspaces.map(\.document.workspaceID))
        let observedIDs = Set(liveByWorkspace.keys).union(unwitnessedByWorkspace.keys).subtracting(catalogIDs)
        for id in observedIDs {
            let witness = liveByWorkspace[id]?.first ?? unwitnessedByWorkspace[id]?.first
            workspaceRows.append(.init(
                id: id,
                name: witness?.sample.workspaceName ?? id.uuidString,
                roots: witness?.sample.workspaceRoots ?? [],
                unavailable: false,
                hidden: false,
                sessions: Array(overlayLive([:], workspaceID: id).values),
                coverage: "Observed workspace is not in the durable catalog (temporary or unavailable).",
                savedCount: nil,
                savedLimit: 100
            ))
        }
        for id in catalog.unavailableWorkspaceIDs where !workspaceRows.contains(where: { $0.id == id }) {
            workspaceRows.append(CommandCenterWorkspaceRow(
                id: id, name: id.uuidString, roots: [], unavailable: true, hidden: false,
                sessions: [], coverage: "Workspace unavailable in canonical catalog", savedCount: nil, savedLimit: 100
            ))
        }
        return CommandCenterSnapshot(
            workspaces: workspaceRows.sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            },
            catalogCoverage: !catalog.isBootstrapped ? "Workspace catalog is loading" :
                (catalog.health != .writable ? "Workspace catalog health: \(catalog.health)" : nil)
        )
    }
}
