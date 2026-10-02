import Foundation

/// A sidebar row's oversight roles, derived from the published link projection.
///
/// One role value replaces the old `isOverseer: Bool`: the row knows its own group slot when it
/// oversees anything, and its overseers — in link-creation order — when it is overseen. This is a
/// presentation value only; it carries no closures and is rebuilt from the live projection on every
/// oversight-change notification.
struct AgentSessionOversightRole: Equatable {
    /// One session overseeing this row, with its allocated group colour slot.
    struct Overseer: Equatable, Identifiable {
        let sessionID: UUID
        let displayName: String
        let slot: Int

        var id: UUID {
            sessionID
        }
    }

    /// This row's own group colour slot while it oversees at least one session; `nil` otherwise.
    let ownOverseerSlot: Int?
    /// Sessions overseeing this row, earliest link first.
    let overseers: [Overseer]
    /// Names of the sessions this row oversees, in projection order — the tooltip's
    /// `Overseeing:` segment.
    let overseeingNames: [String]

    var isOverseer: Bool {
        ownOverseerSlot != nil
    }

    var isOverseen: Bool {
        !overseers.isEmpty
    }

    /// Whether the row carries any role mark at all. A row with neither role renders nothing.
    var hasMark: Bool {
        isOverseer || isOverseen
    }

    static let none = AgentSessionOversightRole(ownOverseerSlot: nil, overseers: [], overseeingNames: [])

    /// Derives the role from one published monitor projection. Inbound rows are deduplicated by
    /// overseer session (a duplicated incarnation shares one group) and sorted by link creation,
    /// so `overseers.first` is always the overseer whose colour the mark wears.
    /// Link rows reduced to what role derivation needs — keeps this file off ViewModels-layer
    /// pill props so the layering index stays clean.
    struct OverseerLink {
        var observerSessionID: UUID
        var displayName: String
        var linkID: UUID
        var linkCreatedAt: Date?
    }

    struct OverseeingLink {
        var displayName: String
    }

    @MainActor
    static func make(
        inbound: [OverseerLink],
        outbound: [OverseeingLink],
        ownSessionID: UUID,
        slot: (UUID) -> Int
    ) -> AgentSessionOversightRole {
        var seen: Set<UUID> = []
        let ordered = inbound
            .sorted { lhs, rhs in
                let lhsDate = lhs.linkCreatedAt ?? .distantFuture
                let rhsDate = rhs.linkCreatedAt ?? .distantFuture
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.linkID.uuidString < rhs.linkID.uuidString
            }
            .filter { seen.insert($0.observerSessionID).inserted }
        return AgentSessionOversightRole(
            ownOverseerSlot: outbound.isEmpty ? nil : slot(ownSessionID),
            overseers: ordered.map {
                Overseer(
                    sessionID: $0.observerSessionID,
                    displayName: $0.displayName,
                    slot: slot($0.observerSessionID)
                )
            },
            overseeingNames: outbound.map(\.displayName)
        )
    }
}

/// Assigns each active overseer session a stable `AgentOversightPalette` slot.
///
/// In-memory only — nothing is persisted, so slots are reassigned in link-creation order after a
/// relaunch. An overseer takes the lowest free slot when its first link appears in the published
/// projections, keeps that slot while any of its links remain (re-sorts never reshuffle), and
/// releases it when its last link disappears. Beyond `slotCount` concurrent overseers, slots wrap
/// and collide deterministically.
///
/// The allocator stores slots only — never roles — so a row's live role still comes from the
/// projection; only the colour identity is sticky.
@MainActor
final class AgentOversightColourAllocator {
    private(set) var slotsByOverseerID: [UUID: Int] = [:]
    /// Round-robin cursor used only once every slot is taken.
    private var overflowCursor = 0

    private var slotCount: Int {
        AgentOversightPalette.slotCount
    }

    /// The overseer's slot, allocating the lowest free one on first sight. Every published
    /// projection passes through `reconcile` before the change notification, so readers always
    /// see a settled map; the allocating read exists only as a defensive pre-reconcile fallback.
    @discardableResult
    func slot(for overseerSessionID: UUID) -> Int {
        if let existing = slotsByOverseerID[overseerSessionID] { return existing }
        let used = Set(slotsByOverseerID.values)
        let slot: Int
        if let free = (0 ..< slotCount).first(where: { !used.contains($0) }) {
            slot = free
        } else {
            slot = overflowCursor % slotCount
            overflowCursor += 1
        }
        slotsByOverseerID[overseerSessionID] = slot
        return slot
    }

    /// Reconciles the slot map with the overseers present in the latest published projections:
    /// frees overseers with no remaining link, then assigns unknowns in link-creation order
    /// (`firstLinkCreatedAt`, session UUID tie-break) so colours are deterministic across relaunch.
    func reconcile(activeOverseerFirstLinkDates: [UUID: Date]) {
        slotsByOverseerID = slotsByOverseerID.filter {
            activeOverseerFirstLinkDates[$0.key] != nil
        }
        let newcomers = activeOverseerFirstLinkDates.keys
            .filter { slotsByOverseerID[$0] == nil }
            .sorted { lhs, rhs in
                let lhsDate = activeOverseerFirstLinkDates[lhs] ?? .distantFuture
                let rhsDate = activeOverseerFirstLinkDates[rhs] ?? .distantFuture
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.uuidString < rhs.uuidString
            }
        for overseerID in newcomers {
            slot(for: overseerID)
        }
    }
}
