import Foundation

// Pure vocabulary and decisions behind `session_admin` inventory and organizing operations
// (design §3.1, §4.1, §4.2). The app projects records from loaded windows and the cross-workspace
// history index; everything here is AppKit-free and clock-free so it can be unit-tested directly.

// MARK: - Run state

/// Coarse run state used for inventory filters and rendering.
package enum DomainAgentSessionInventoryRunState: String, CaseIterable, Hashable, Sendable {
    case idle
    case running
    /// Waiting on the user: an approval, a question, or input.
    case waiting
    case completed
    case cancelled
    case failed
    /// No recorded state.
    case unknown

    /// Classifies a persisted `AgentSessionRunState` raw value.
    package static func classify(rawValue: String?) -> Self {
        switch rawValue {
        case "idle": .idle
        case "running": .running
        case "waitingForUser", "waitingForQuestion", "waitingForApproval": .waiting
        case "completed": .completed
        case "cancelled": .cancelled
        case "failed": .failed
        default: .unknown
        }
    }

    /// Accepted filter spellings: every case plus `active` (running or waiting).
    package static func parseFilter(_ text: String) -> Set<Self>? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "active" { return [.running, .waiting] }
        return Self(rawValue: normalized).map { [$0] }
    }
}

/// A session's oversight role, mirroring the HUD role filter.
package enum DomainAgentSessionInventoryRole: String, CaseIterable, Hashable, Sendable {
    /// Observes at least one session (live link or persisted intent).
    case overseer
    /// Is observed by at least one session.
    case overseen
}

/// Why a session counts as orphaned (design §4.2).
package enum DomainAgentSessionOrphanReason: String, CaseIterable, Hashable, Sendable {
    /// A persisted oversight intent touching this session names a session that no longer exists.
    case linkIntentMissingSession = "link_intent_missing_session"
    /// An observer of this session is archived or deleted.
    case observerArchivedOrDeleted = "observer_archived_or_deleted"
    /// The (organizational or spawn) parent no longer exists.
    case parentMissing = "parent_missing"
    /// The overseer that created this lane no longer exists.
    case laneCreatorMissing = "lane_creator_missing"
}

// MARK: - Records

/// One session as inventory sees it. Projected by the app; never built from tool arguments.
package struct DomainAgentSessionInventoryRecord: Hashable, Sendable {
    package let sessionID: UUID
    package let name: String
    package let workspaceID: UUID?
    package let workspaceName: String?
    /// The session's workspace is the active workspace of an open window. Only loaded sessions can
    /// be mutated.
    package let isLoaded: Bool
    package let isArchived: Bool
    package let isPinned: Bool
    package let pinnedOrder: Int?
    package let sidebarGroup: String?
    package let sidebarGroupOrder: Int?
    package let runState: DomainAgentSessionInventoryRunState
    package let parentSessionID: UUID?
    package let createdByOverseerSessionID: UUID?
    package let organizationalParentID: UUID?
    /// First recorded activity, when known.
    package let createdAt: Date?
    /// Last user message, else last save.
    package let lastActivityAt: Date
    package let worktreeCount: Int

    package init(
        sessionID: UUID,
        name: String,
        workspaceID: UUID?,
        workspaceName: String? = nil,
        isLoaded: Bool,
        isArchived: Bool = false,
        isPinned: Bool = false,
        pinnedOrder: Int? = nil,
        sidebarGroup: String? = nil,
        sidebarGroupOrder: Int? = nil,
        runState: DomainAgentSessionInventoryRunState = .unknown,
        parentSessionID: UUID? = nil,
        createdByOverseerSessionID: UUID? = nil,
        organizationalParentID: UUID? = nil,
        createdAt: Date? = nil,
        lastActivityAt: Date,
        worktreeCount: Int = 0
    ) {
        self.sessionID = sessionID
        self.name = name
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.isLoaded = isLoaded
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.pinnedOrder = pinnedOrder
        self.sidebarGroup = sidebarGroup
        self.sidebarGroupOrder = sidebarGroupOrder
        self.runState = runState
        self.parentSessionID = parentSessionID
        self.createdByOverseerSessionID = createdByOverseerSessionID
        self.organizationalParentID = organizationalParentID
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.worktreeCount = worktreeCount
    }

    /// Tree placement: organizational parent, else spawn parent, else lane creator.
    package var effectiveParentID: UUID? {
        organizationalParentID ?? parentSessionID ?? createdByOverseerSessionID
    }
}

/// One directed observer → target relationship: a live link, a persisted intent, or both.
package struct DomainAgentSessionInventoryEdge: Hashable, Sendable {
    package let observerSessionID: UUID
    package let targetSessionID: UUID
    /// A live link currently exists in the link authority.
    package let isLive: Bool
    /// A durable intent exists in `agentSessionOversightLinks.json`.
    package let isPersisted: Bool
    package let linkID: UUID?
    package let linkGeneration: UInt64?

    package init(
        observerSessionID: UUID,
        targetSessionID: UUID,
        isLive: Bool,
        isPersisted: Bool,
        linkID: UUID? = nil,
        linkGeneration: UInt64? = nil
    ) {
        self.observerSessionID = observerSessionID
        self.targetSessionID = targetSessionID
        self.isLive = isLive
        self.isPersisted = isPersisted
        self.linkID = linkID
        self.linkGeneration = linkGeneration
    }

    package func touches(_ sessionID: UUID) -> Bool {
        observerSessionID == sessionID || targetSessionID == sessionID
    }

    /// Merges live links and persisted intents into one edge per directed pair.
    package static func merge(
        live: [(observer: UUID, target: UUID, linkID: UUID, generation: UInt64)],
        persisted: [(observer: UUID, target: UUID)]
    ) -> [Self] {
        struct Pair: Hashable {
            let observer: UUID
            let target: UUID
        }
        var liveByPair: [Pair: (UUID, UInt64)] = [:]
        for link in live {
            liveByPair[Pair(observer: link.observer, target: link.target)] = (link.linkID, link.generation)
        }
        let persistedPairs = Set(persisted.map { Pair(observer: $0.observer, target: $0.target) })
        let allPairs = Set(liveByPair.keys).union(persistedPairs)
        return allPairs.map { pair in
            let liveLink = liveByPair[pair]
            return Self(
                observerSessionID: pair.observer,
                targetSessionID: pair.target,
                isLive: liveLink != nil,
                isPersisted: persistedPairs.contains(pair),
                linkID: liveLink?.0,
                linkGeneration: liveLink?.1
            )
        }
        .sorted {
            if $0.observerSessionID != $1.observerSessionID {
                return $0.observerSessionID.uuidString < $1.observerSessionID.uuidString
            }
            return $0.targetSessionID.uuidString < $1.targetSessionID.uuidString
        }
    }
}

// MARK: - Snapshot

/// Every known session plus the oversight edges among them, at one moment.
package struct DomainAgentSessionInventorySnapshot: Sendable {
    package let records: [UUID: DomainAgentSessionInventoryRecord]
    package let edges: [DomainAgentSessionInventoryEdge]
    /// The history scan covered every workspace. Absence-based orphan reasons ("missing") are only
    /// reported when this is true: an incomplete scan cannot tell "deleted" from "not scanned".
    package let isComplete: Bool
    /// Every session known to exist, including ones a restricted view hides. Absence from this set
    /// (on a complete scan) is what "missing" means; a session hidden by scope is never missing.
    package let knownSessionIDs: Set<UUID>

    private let edgesBySession: [UUID: [DomainAgentSessionInventoryEdge]]

    package init(
        records: [DomainAgentSessionInventoryRecord],
        edges: [DomainAgentSessionInventoryEdge],
        isComplete: Bool
    ) {
        var byID: [UUID: DomainAgentSessionInventoryRecord] = [:]
        for record in records {
            // Loaded projections win over history rows for the same session.
            if let existing = byID[record.sessionID], existing.isLoaded, !record.isLoaded { continue }
            byID[record.sessionID] = record
        }
        self.init(records: byID, edges: edges, isComplete: isComplete, knownSessionIDs: Set(byID.keys))
    }

    private init(
        records: [UUID: DomainAgentSessionInventoryRecord],
        edges: [DomainAgentSessionInventoryEdge],
        isComplete: Bool,
        knownSessionIDs: Set<UUID>
    ) {
        self.records = records
        self.edges = edges
        self.isComplete = isComplete
        self.knownSessionIDs = knownSessionIDs
        var bySession: [UUID: [DomainAgentSessionInventoryEdge]] = [:]
        for edge in edges {
            bySession[edge.observerSessionID, default: []].append(edge)
            if edge.targetSessionID != edge.observerSessionID {
                bySession[edge.targetSessionID, default: []].append(edge)
            }
        }
        edgesBySession = bySession
    }

    /// The view a scope may see: only `visibleSessionIDs`' records, and only edges whose every
    /// endpoint is visible or truly missing (deleted, on a complete scan). Edges to existing sessions
    /// outside the scope are dropped entirely, so counts, roles, and orphan reasons derived from the
    /// view never reflect, count, or name an out-of-scope session.
    package func restricted(to visibleSessionIDs: Set<UUID>) -> Self {
        let visibleRecords = records.filter { visibleSessionIDs.contains($0.key) }
        let visibleEdges = edges.filter { edge in
            [edge.observerSessionID, edge.targetSessionID].allSatisfy { id in
                visibleRecords[id] != nil || isMissing(id)
            }
        }
        return Self(
            records: visibleRecords,
            edges: visibleEdges,
            isComplete: isComplete,
            knownSessionIDs: knownSessionIDs
        )
    }

    /// Known not to exist: only on a complete scan, and never for a session merely hidden by scope.
    package func isMissing(_ sessionID: UUID) -> Bool {
        isComplete && !knownSessionIDs.contains(sessionID)
    }

    package func edges(touching sessionID: UUID) -> [DomainAgentSessionInventoryEdge] {
        edgesBySession[sessionID] ?? []
    }

    package func roles(of sessionID: UUID) -> Set<DomainAgentSessionInventoryRole> {
        var roles: Set<DomainAgentSessionInventoryRole> = []
        for edge in edges(touching: sessionID) {
            if edge.observerSessionID == sessionID { roles.insert(.overseer) }
            if edge.targetSessionID == sessionID { roles.insert(.overseen) }
        }
        return roles
    }

    package func hasLinks(_ sessionID: UUID) -> Bool {
        !edges(touching: sessionID).isEmpty
    }

    /// Orphan reasons, in a stable order. See `DomainAgentSessionOrphanReason`.
    package func orphanReasons(for sessionID: UUID) -> [DomainAgentSessionOrphanReason] {
        guard let record = records[sessionID] else { return [] }
        var reasons: Set<DomainAgentSessionOrphanReason> = []
        for edge in edges(touching: sessionID) {
            if edge.isPersisted, isMissing(edge.observerSessionID) || isMissing(edge.targetSessionID) {
                reasons.insert(.linkIntentMissingSession)
            }
            if edge.targetSessionID == sessionID, edge.observerSessionID != sessionID {
                if isMissing(edge.observerSessionID) || records[edge.observerSessionID]?.isArchived == true {
                    reasons.insert(.observerArchivedOrDeleted)
                }
            }
        }
        if let parent = record.organizationalParentID ?? record.parentSessionID, isMissing(parent) {
            reasons.insert(.parentMissing)
        }
        if let creator = record.createdByOverseerSessionID, isMissing(creator) {
            reasons.insert(.laneCreatorMissing)
        }
        return DomainAgentSessionOrphanReason.allCases.filter(reasons.contains)
    }

    /// True when `sessionID` is `rootSessionID` or its placement chain reaches it.
    package func isInTree(_ sessionID: UUID, rootSessionID: UUID, maxChainLength: Int = 256) -> Bool {
        var cursor = sessionID
        var seen: Set<UUID> = []
        while seen.count < maxChainLength {
            if cursor == rootSessionID { return true }
            guard seen.insert(cursor).inserted, let parent = records[cursor]?.effectiveParentID else { return false }
            cursor = parent
        }
        return false
    }

    /// Whole days since last activity, never negative.
    package func idleDays(_ sessionID: UUID, now: Date) -> Int? {
        guard let record = records[sessionID] else { return nil }
        return max(0, Int(now.timeIntervalSince(record.lastActivityAt) / 86400))
    }
}

// MARK: - Filter

/// Structured inventory filter (design §3.1). `query` is free text and is evaluated by the app with
/// the shared session search matcher, so it is carried here but not interpreted.
package struct DomainAgentSessionInventoryFilter: Hashable, Sendable {
    package enum GroupMatch: Hashable, Sendable {
        case named(String)
        /// Sessions with no sidebar group.
        case none
    }

    package var workspaceID: UUID?
    package var rootOverseerSessionID: UUID?
    package var states: Set<DomainAgentSessionInventoryRunState>?
    package var pinned: Bool?
    package var group: GroupMatch?
    package var query: String?
    package var idleDaysGreaterThan: Int?
    package var createdBefore: Date?
    package var createdAfter: Date?
    package var hasLinks: Bool?
    package var role: DomainAgentSessionInventoryRole?
    package var orphaned: Bool?
    package var archived: Bool?
    package var loaded: Bool?

    package init(
        workspaceID: UUID? = nil,
        rootOverseerSessionID: UUID? = nil,
        states: Set<DomainAgentSessionInventoryRunState>? = nil,
        pinned: Bool? = nil,
        group: GroupMatch? = nil,
        query: String? = nil,
        idleDaysGreaterThan: Int? = nil,
        createdBefore: Date? = nil,
        createdAfter: Date? = nil,
        hasLinks: Bool? = nil,
        role: DomainAgentSessionInventoryRole? = nil,
        orphaned: Bool? = nil,
        archived: Bool? = nil,
        loaded: Bool? = nil
    ) {
        self.workspaceID = workspaceID
        self.rootOverseerSessionID = rootOverseerSessionID
        self.states = states
        self.pinned = pinned
        self.group = group
        self.query = query
        self.idleDaysGreaterThan = idleDaysGreaterThan
        self.createdBefore = createdBefore
        self.createdAfter = createdAfter
        self.hasLinks = hasLinks
        self.role = role
        self.orphaned = orphaned
        self.archived = archived
        self.loaded = loaded
    }

    /// Every structured predicate except `query`. Unknown facts fail closed: a record with no
    /// creation date never matches a creation bound.
    package func matchesStructured(
        _ record: DomainAgentSessionInventoryRecord,
        in snapshot: DomainAgentSessionInventorySnapshot,
        now: Date
    ) -> Bool {
        if let workspaceID, record.workspaceID != workspaceID { return false }
        if let rootOverseerSessionID,
           !snapshot.isInTree(record.sessionID, rootSessionID: rootOverseerSessionID)
        {
            return false
        }
        if let states, !states.contains(record.runState) { return false }
        if let pinned, record.isPinned != pinned { return false }
        switch group {
        case let .named(name):
            guard let recordGroup = record.sidebarGroup,
                  recordGroup.compare(name, options: [.caseInsensitive]) == .orderedSame
            else { return false }
        case .none?:
            if record.sidebarGroup != nil { return false }
        case nil:
            break
        }
        if let idleDaysGreaterThan {
            guard let idle = snapshot.idleDays(record.sessionID, now: now), idle > idleDaysGreaterThan else {
                return false
            }
        }
        if let createdBefore {
            guard let createdAt = record.createdAt, createdAt < createdBefore else { return false }
        }
        if let createdAfter {
            guard let createdAt = record.createdAt, createdAt > createdAfter else { return false }
        }
        if let hasLinks, snapshot.hasLinks(record.sessionID) != hasLinks { return false }
        if let role, !snapshot.roles(of: record.sessionID).contains(role) { return false }
        if let orphaned, snapshot.orphanReasons(for: record.sessionID).isEmpty == orphaned { return false }
        if let archived, record.isArchived != archived { return false }
        if let loaded, record.isLoaded != loaded { return false }
        return true
    }
}

// MARK: - Ordering (compare-and-swap)

package enum DomainAgentSessionOrderingError: Error, Hashable, Sendable {
    /// `order` and `expected_order` must name the same items, each once.
    case orderSetMismatch
    /// An item in `order` is not currently in the ordered set.
    case unknownItem
    /// The current order of the named items differs from `expected_order`.
    case expectedOrderMismatch(current: [String])
}

package enum DomainAgentSessionOrdering {
    /// Permutes `desired` items among the slots they currently occupy in `current`, leaving every
    /// other item in place. CAS: the named items' current relative order must equal `expected`.
    ///
    /// Generic over the item so pins (session IDs) and groups (names) share one rule.
    package static func permute<Item: Hashable>(
        current: [Item],
        expected: [Item],
        desired: [Item],
        describe: (Item) -> String
    ) -> Result<[Item], DomainAgentSessionOrderingError> {
        let desiredSet = Set(desired)
        guard desiredSet.count == desired.count,
              Set(expected).count == expected.count,
              desiredSet == Set(expected),
              !desired.isEmpty
        else { return .failure(.orderSetMismatch) }
        guard desiredSet.isSubset(of: Set(current)) else { return .failure(.unknownItem) }
        let currentNamed = current.filter(desiredSet.contains)
        guard currentNamed == expected else {
            return .failure(.expectedOrderMismatch(current: currentNamed.map(describe)))
        }
        var replacements = desired.makeIterator()
        return .success(current.map { item in
            desiredSet.contains(item) ? (replacements.next() ?? item) : item
        })
    }
}

// MARK: - Groups

package enum DomainAgentSessionSidebarGroup {
    package static let maxNameCharacters = 64

    /// Trimmed group name, or `nil` when empty, too long, or multi-line.
    package static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maxNameCharacters,
              !trimmed.contains(where: \.isNewline)
        else { return nil }
        return trimmed
    }

    /// Distinct groups ordered by their order value (then name), from per-session mirrors.
    package static func orderedGroups(_ entries: [(group: String, order: Int?)]) -> [String] {
        var rank: [String: Int] = [:]
        for entry in entries {
            let order = entry.order ?? Int.max
            rank[entry.group] = min(rank[entry.group] ?? Int.max, order)
        }
        return rank.keys.sorted { lhs, rhs in
            let left = rank[lhs] ?? Int.max
            let right = rank[rhs] ?? Int.max
            if left != right { return left < right }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    /// The order value for a group: the existing group's own order value, else one past the largest
    /// order value in use (0 when none is). Never a position index, so joining an existing group
    /// keeps its mirror consistent and a new group never collides with another group's value.
    package static func order(for group: String, existing: [(group: String, order: Int?)]) -> Int {
        if let value = existing.filter({ $0.group == group }).compactMap(\.order).min() {
            return value
        }
        return (existing.compactMap(\.order).max() ?? -1) + 1
    }

    /// New order values for `desired` (a permutation of the named groups): the named groups'
    /// current values are redistributed among them, so groups outside the call keep their values
    /// and their carriers are never written. When the named groups lack distinct values (legacy or
    /// malformed mirrors), fresh values after every value in use are assigned to them instead.
    package static func redistributedOrders(
        desired: [String],
        entries: [(group: String, order: Int?)]
    ) -> [String: Int] {
        let named = Set(desired)
        let currentNamed = orderedGroups(entries).filter(named.contains)
        let values = currentNamed.map { group in entries.filter { $0.group == group }.compactMap(\.order).min() }
        let explicit = values.compactMap(\.self)
        let slots: [Int]
        if explicit.count == values.count, Set(explicit).count == explicit.count {
            slots = explicit.sorted()
        } else {
            let base = (entries.compactMap(\.order).max() ?? -1) + 1
            slots = desired.indices.map { base + $0 }
        }
        return Dictionary(uniqueKeysWithValues: zip(desired, slots).map { ($0, $1) })
    }
}

// MARK: - Pin ranks

package enum DomainAgentSessionPinRanks {
    /// Explicit ranks after reordering `desired` pins within the slots they occupy in `current`
    /// (displayed order, with each pin's current explicit rank).
    ///
    /// When `current` is already backed by distinct, increasing explicit ranks, the named pins swap
    /// those rank values among themselves and no other pin changes. Otherwise ranks are first
    /// *materialized* (`0..<count` in displayed order, so no pin moves) and then permuted; that is
    /// the only case that writes ranks to pins outside `desired`, and it never changes their position.
    package static func reordered(
        current: [(id: UUID, rank: Int?)],
        desired: [UUID]
    ) -> (ranks: [UUID: Int], materialized: Bool) {
        let ranks = current.map(\.rank)
        let explicit = ranks.compactMap(\.self)
        let consistent = explicit.count == ranks.count && zip(explicit, explicit.dropFirst()).allSatisfy { $0 < $1 }
        var base: [UUID: Int] = [:]
        for (offset, pin) in current.enumerated() {
            base[pin.id] = consistent ? (pin.rank ?? offset) : offset
        }
        let named = Set(desired)
        let slots = current.map(\.id).filter(named.contains).compactMap { base[$0] }
        var result = base
        for (id, slot) in zip(desired, slots) {
            result[id] = slot
        }
        return (result, !consistent)
    }
}

// MARK: - Ledgers

/// Idempotency for direct (uncarded) administration calls: a key replays its first result for the
/// identical request and conflicts for any other. Bounded; oldest entries are evicted first.
package struct DomainAgentSessionAdministrationIdempotencyLedger<Result: Sendable>: Sendable {
    package enum Lookup: Sendable {
        case miss
        case replay(Result)
        case conflict
    }

    private struct Key: Hashable {
        let granteeSessionID: UUID
        let idempotencyKey: String
    }

    private struct Entry {
        let fingerprint: String
        let result: Result
    }

    package let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []

    package init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    package func lookup(granteeSessionID: UUID, idempotencyKey: String, fingerprint: String) -> Lookup {
        guard let entry = entries[Key(granteeSessionID: granteeSessionID, idempotencyKey: idempotencyKey)] else {
            return .miss
        }
        return entry.fingerprint == fingerprint ? .replay(entry.result) : .conflict
    }

    package mutating func record(granteeSessionID: UUID, idempotencyKey: String, fingerprint: String, result: Result) {
        let key = Key(granteeSessionID: granteeSessionID, idempotencyKey: idempotencyKey)
        if entries[key] == nil { order.append(key) }
        entries[key] = Entry(fingerprint: fingerprint, result: result)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    package var count: Int {
        entries.count
    }
}

/// Undo tokens for reversible bulk operations (design §2.5): one token per applied call, bound to
/// its grantee and to the exact scope generation it was issued under, valid for a bounded window,
/// consumed at most once (a refused undo may be `restore`d rather than burned).
package struct DomainAgentSessionAdministrationUndoLedger<Payload: Sendable>: Sendable {
    package struct Entry: Sendable {
        package let token: String
        package let granteeSessionID: UUID
        package let scopeID: UUID
        /// The scope generation the call ran under; any other generation authorizes nothing.
        package let scopeGeneration: UInt64
        package let operation: DomainAgentSessionTargetOperation
        package let targetSessionIDs: [UUID]
        package let payload: Payload
        package let expiresAt: Date
    }

    package enum Redeem: Sendable {
        case redeemed(Entry)
        /// Unknown token, another grantee's token, or already consumed. Deliberately one case.
        case unavailable
        case expired
    }

    package let capacity: Int
    package let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    /// Default lifetime is 15 minutes.
    package init(capacity: Int = 128, lifetime: TimeInterval = 15 * 60) {
        self.capacity = max(1, capacity)
        self.lifetime = lifetime
    }

    package mutating func issue(
        token: String,
        granteeSessionID: UUID,
        scopeID: UUID,
        scopeGeneration: UInt64,
        operation: DomainAgentSessionTargetOperation,
        targetSessionIDs: [UUID],
        payload: Payload,
        now: Date
    ) -> Entry {
        let entry = Entry(
            token: token,
            granteeSessionID: granteeSessionID,
            scopeID: scopeID,
            scopeGeneration: scopeGeneration,
            operation: operation,
            targetSessionIDs: targetSessionIDs,
            payload: payload,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        entries[token] = entry
        order.append(token)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        return entry
    }

    /// Consumes the token for its grantee. An expired token is dropped and reported as expired.
    package mutating func redeem(token: String, granteeSessionID: UUID, now: Date) -> Redeem {
        guard let entry = entries[token], entry.granteeSessionID == granteeSessionID else { return .unavailable }
        entries.removeValue(forKey: token)
        order.removeAll { $0 == token }
        return entry.expiresAt > now ? .redeemed(entry) : .expired
    }

    /// Puts a redeemed entry back, for an undo that could not be applied.
    package mutating func restore(_ entry: Entry) {
        guard entries[entry.token] == nil else { return }
        entries[entry.token] = entry
        order.append(entry.token)
    }

    package var count: Int {
        entries.count
    }
}
