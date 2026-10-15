import Foundation
import RepoPromptDomainRuntime

/// Host-neutral inputs and receipts for the bridge's process-local lane transaction.
struct AgentSessionLaneCreateRequest {
    let idempotencyKey: String
    let role: String?
    var modelID: String?
    let sessionName: String?
    /// The caller's selector, not a window/workspace binding that can move after the request.
    var workspaceSelector: String?
    let message: String?
    let workflowReference: AgentWorkflowReference?

    var digest: String {
        let fields = [
            modelID.map { "model:\($0)" } ?? role ?? "pair", sessionName ?? "", Self.canonicalSelector(workspaceSelector),
            message ?? "", AgentWorkflowReference.canonicalSelector(for: workflowReference)
        ]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return AgentSessionLinkMessageDigest.digest(message: canonical, workflowSelector: "create_lane/v1")
    }

    static func canonicalSelector(_ value: String?) -> String {
        guard let value else { return "caller-workspace" }
        if let id = UUID(uuidString: value) { return "id:\(id.uuidString)" }
        let folded = value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        return "name:\(folded.precomposedStringWithCanonicalMapping)"
    }
}

enum AgentSessionLaneHostCreationOutcome {
    case created(sessionID: UUID, tabID: UUID, bindingToken: AgentSessionRestorationBindingToken)
    case creationIncomplete(sessionID: UUID, tabID: UUID)
}

enum AgentSessionLaneHostUnavailable: Error { case unavailable }

struct AgentSessionLaneDestination: Equatable {
    let windowID: Int
    let workspaceID: UUID
    let workspaceName: String
}

enum AgentSessionLaneDestinationFailure: Error, Equatable {
    case callerWindowHasNoWorkspace, selectorMatchedNone, selectorAmbiguous, destinationChanged
    case hostError(String)

    var subreason: String {
        switch self {
        case .callerWindowHasNoWorkspace: "caller_window_has_no_workspace"
        case .selectorMatchedNone: "selector_matched_none"
        case .selectorAmbiguous: "selector_ambiguous"
        case .destinationChanged: "destination_changed"
        case let .hostError(type): "host_error:\(type)"
        }
    }
}

enum AgentSessionLaneDestinationResolution {
    case available(AgentSessionLaneDestination)
    case unavailable(AgentSessionLaneDestinationFailure)

    var destination: AgentSessionLaneDestination? {
        if case let .available(value) = self { return value }
        return nil
    }
}

/// A destination was resolved, but scoped creation was refused before allocating any session.
/// Keeping this separate prevents the bridge from misreporting authority as destination failure.
struct AgentSessionLaneSpawnAdmissionFailure: Error {
    let detail: String

    /// Only the structured error emitted by our admission owner is decoded here, never target text.
    var subreason: String {
        guard let start = detail.firstIndex(of: "{"),
              let fields = try? JSONSerialization.jsonObject(with: Data(detail[start...].utf8)) as? [String: Any]
        else { return "scope_denied" }
        return fields["subreason"] as? String ?? fields["code"] as? String ?? "scope_denied"
    }
}

struct AgentSessionLaneCreateReceipt: Equatable {
    enum Result: Equatable { case created, creationIncomplete, refused }
    enum Reason: String, Equatable {
        case shuttingDown = "shutting_down"
        case denied
        case persistenceUnavailable = "persistence_unavailable"
        case destinationUnavailable = "destination_unavailable"
        case scopeDenied = "scope_denied"
        case hostUnavailable = "host_unavailable"
        case laneLimitReached = "lane_limit_reached"
        case admissionUnstable = "admission_unstable"
        case roleUnavailable = "role_unavailable"
        case modelUnavailable = "model_unavailable"
        case idempotencyConflict = "idempotency_conflict"
        case ledgerFull = "ledger_full"
        case saveFailed = "save_failed"
        case addFailed = "add_failed"
    }

    enum FirstTask: Equatable { case none, delivered, queued, failed }

    let result: Result
    let sessionID: UUID?
    let sessionName: String?
    let linked: Bool
    let reason: Reason?
    let firstTask: FirstTask
    let laneCount: Int
    var duplicate = false
    var firstTaskReason: String?
    var refusalDetail: String?
    var admissionSubreason: String?
    var destinationFailure: AgentSessionLaneDestinationFailure?
    var refusalStage: String?
    /// Original destination display name, preserved on replay; not a live location or selector.
    var workspaceName: String?

    static func refused(_ reason: Reason, laneCount: Int = 0) -> Self {
        Self(
            result: .refused,
            sessionID: nil,
            sessionName: nil,
            linked: false,
            reason: reason,
            firstTask: .none,
            laneCount: laneCount
        )
    }
}

/// Retirement may stash a settled subtree, but must preserve every descendant that still owns work.
struct AgentSessionLaneChildRetirementRecord {
    /// Which evidence produced the record. Only a hydrated session is newer than its unflushed disk
    /// header, so only it may shadow persisted or index blocking state; the rest can add edges and
    /// blocking evidence but never erase them.
    enum Source {
        case persisted
        case sessionIndex
        case unhydratedSession
        case hydratedSession
        /// Merge output: the verdict's provenance, not fresh evidence of its own.
        case merged

        var isSessionDerived: Bool {
            self == .unhydratedSession || self == .hydratedSession
        }
    }

    let sessionID: UUID
    let parentSessionID: UUID?
    let blocksRetirement: Bool
    let source: Source

    init(sessionID: UUID, parentSessionID: UUID?, blocksRetirement: Bool, source: Source = .persisted) {
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.blocksRetirement = blocksRetirement
        self.source = source
    }

    /// Merge all evidence for one session ID. Parent claims are tiered — session-derived, then
    /// index, then persisted. A nil parent is a real "no parent" vote only where the source is
    /// authoritative: a hydrated session knows its own lineage, and a decoded disk header is the
    /// complete persisted lineage. Index and unhydrated nils stay "unknown" and never vote. When
    /// the non-nil claims disagree across tiers, or an authoritative nil conflicts with a claimed
    /// edge, the lineage is ambiguous: the merge keeps every claimed edge and forces the block
    /// rather than guessing which subtree owns the session. Only coherent lineage lets a hydrated
    /// session's quiescence shadow a stale disk or index block.
    static func merging(sessionID: UUID, live: [Self], persisted: [Self]) -> [Self] {
        var sessionParents = Set<UUID>()
        var indexParents = Set<UUID>()
        var persistedParents = Set<UUID>()
        var hydratedNilVote = false
        var persistedNilVote = false
        for record in live {
            switch record.source {
            case .hydratedSession:
                if let parent = record.parentSessionID { sessionParents.insert(parent) } else { hydratedNilVote = true }
            case .unhydratedSession:
                if let parent = record.parentSessionID { sessionParents.insert(parent) }
            case .sessionIndex:
                if let parent = record.parentSessionID { indexParents.insert(parent) }
            case .persisted, .merged:
                if record.source == .merged {
                    assertionFailure("merged records must never re-enter merging")
                }
                if let parent = record.parentSessionID {
                    persistedParents.insert(parent)
                } else { persistedNilVote = true }
            }
        }
        for record in persisted {
            if record.source == .merged {
                assertionFailure("merged records must never re-enter merging")
            }
            if let parent = record.parentSessionID { persistedParents.insert(parent) } else { persistedNilVote = true }
        }
        let edges = sessionParents.union(indexParents).union(persistedParents)
        let authoritativeNilVote = hydratedNilVote || persistedNilVote
        let ambiguous = edges.count > 1 || (authoritativeNilVote && !edges.isEmpty)
        let hydrated = live.contains { $0.source == .hydratedSession }
        let sessionBlocks = live.contains { $0.source.isSessionDerived && $0.blocksRetirement }
        let blocks = ambiguous || (
            hydrated
                ? sessionBlocks
                : live.contains { $0.blocksRetirement } || persisted.contains { $0.blocksRetirement }
        )
        guard !edges.isEmpty else {
            return [Self(sessionID: sessionID, parentSessionID: nil, blocksRetirement: blocks, source: .merged)]
        }
        return edges.sorted { $0.uuidString < $1.uuidString }.map {
            Self(sessionID: sessionID, parentSessionID: $0, blocksRetirement: blocks, source: .merged)
        }
    }

    static func hasBlockingDescendant(of parentSessionID: UUID, in records: [Self]) -> Bool {
        let descendants = descendantIDs(of: parentSessionID, in: records)
        return records.contains { descendants.contains($0.sessionID) && $0.blocksRetirement }
    }

    static func descendantIDs(of parentSessionID: UUID, in records: [Self]) -> Set<UUID> {
        let childrenByParent = Dictionary(grouping: records.compactMap { record in
            record.parentSessionID.map { ($0, record) }
        }, by: { $0.0 })
        var visited: Set<UUID> = [parentSessionID]
        var pending = [parentSessionID]
        while let parent = pending.popLast() {
            for (_, child) in childrenByParent[parent] ?? [] {
                guard visited.insert(child.sessionID).inserted else { continue }
                pending.append(child.sessionID)
            }
        }
        visited.remove(parentSessionID)
        return visited
    }
}

enum AgentSessionLaneRetireOutcome: Equatable {
    enum Reason: String, Equatable {
        case denied
        case shuttingDown = "shutting_down"
        case notRetirable = "not_retirable"
        case managementNotGranted = "management_not_granted"
        case laneInUse = "lane_in_use"
        case laneInUseBindings = "lane_in_use_bindings"
        case laneInUseChildren = "lane_in_use_children"
        case laneInUseDiskChild = "lane_in_use_disk_child"
        case laneInUseInboundCount = "lane_in_use_in_count"
        case laneInUseInboundLink = "lane_in_use_in_link"
        case laneInUseInboundGeneration = "lane_in_use_in_gen"
        case laneInUseOutbound = "lane_in_use_outbound"
        case laneInUsePending = "lane_in_use_pending"
        case laneBusy = "lane_busy"
        case stopFailed = "stop_failed"
        case alreadyStopped = "already_stopped"

        var wireReason: String {
            subreason == nil ? rawValue : Reason.laneInUse.rawValue
        }

        var subreason: String? {
            switch self {
            case .laneInUse: "unknown"
            case .laneInUseBindings: "bindings"
            case .laneInUseChildren: "children"
            case .laneInUseDiskChild: "disk_child"
            case .laneInUseInboundCount: "in_count"
            case .laneInUseInboundLink: "in_link"
            case .laneInUseInboundGeneration: "in_gen"
            case .laneInUseOutbound: "outbound"
            case .laneInUsePending: "pending"
            default: nil
            }
        }
    }

    case retired(sessionID: UUID)
    case notRetired(sessionID: UUID, reason: Reason)
    case unlinkedNotStashed(sessionID: UUID)
}
