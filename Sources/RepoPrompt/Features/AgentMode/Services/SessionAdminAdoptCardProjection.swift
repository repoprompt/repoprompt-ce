import Foundation
import MCP
import RepoPromptDomainRuntime

/// The agent-facing view of an `adopt` batch card.
///
/// The user's card lists every session that would move (each adoptee and its whole organizational
/// subtree, with names and run state). Those descendants are outside the caller's scope until the user
/// approves, so the agent never sees their IDs or titles: agent-facing replies (`pending_confirmation`,
/// `preview`, `confirmation_status`, `confirmation_mismatch`) show only the adoptee IDs the caller
/// named, a per-adoptee `descendant_count`, and aggregate counts. A descendant that is already a
/// member of the caller's scope chain is shown normally. After approval the moved sessions are
/// members, and ordinary inventory applies to them.
///
/// The card model is shared with other operations and the user UI, so the adoptee/descendant layout
/// is recorded here when the adopt handler builds the card items, keyed by grantee, idempotency key,
/// and the exact item set. Without a recorded layout no item IDs are rendered at all.
@MainActor
enum SessionAdminAdoptCardProjection {
    struct Layout: Equatable {
        /// Adoptees in card order, each with its descendants (sessions that move with it).
        let adoptees: [UUID]
        let descendantsByAdoptee: [UUID: [UUID]]
        let runningSessionIDs: Set<UUID>
        /// Descendants already in the caller's scope chain: visible to the agent as ordinary rows.
        var memberDescendants: Set<UUID> = []

        /// Every session ID an agent-facing reply may name, in card order.
        var visibleSessionIDs: [UUID] {
            adoptees.flatMap { adoptee in
                [adoptee] + (descendantsByAdoptee[adoptee] ?? []).filter(memberDescendants.contains)
            }
        }
    }

    private struct Key: Hashable {
        let granteeSessionID: UUID
        let idempotencyKey: String
        let itemSessionIDs: Set<UUID>
    }

    static let maxRetainedLayouts = 512
    private static var layouts: [Key: Layout] = [:]
    private static var order: [Key] = []

    static func record(_ layout: Layout, granteeSessionID: UUID, idempotencyKey: String?, itemSessionIDs: Set<UUID>) {
        let key = Key(granteeSessionID: granteeSessionID, idempotencyKey: idempotencyKey ?? "", itemSessionIDs: itemSessionIDs)
        if layouts.updateValue(layout, forKey: key) == nil { order.append(key) }
        while order.count > maxRetainedLayouts {
            layouts.removeValue(forKey: order.removeFirst())
        }
    }

    static func layout(granteeSessionID: UUID, idempotencyKey: String?, itemSessionIDs: Set<UUID>) -> Layout? {
        layouts[Key(granteeSessionID: granteeSessionID, idempotencyKey: idempotencyKey ?? "", itemSessionIDs: itemSessionIDs)]
    }

    /// Agent-facing rows: each adoptee (ID, effect, `descendant_count`; no title) followed by its
    /// descendants that are already scope members. Never an outside descendant's ID or title.
    static func agentItems(
        _ items: [BatchConfirmationItem],
        layout: Layout?,
        approved: Set<UUID>?
    ) -> [Value] {
        guard let layout else { return [] }
        let byID = Dictionary(items.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.adoptees.flatMap { adoptee -> [Value] in
            guard let item = byID[adoptee] else { return [] }
            let descendants = layout.descendantsByAdoptee[adoptee] ?? []
            var row: [String: Value] = [
                "session_id": .string(adoptee.uuidString),
                "effect": .string(item.effect),
                "descendant_count": .int(descendants.count)
            ]
            if let approved {
                row["approved"] = .bool(approved.contains(adoptee))
                row["all_descendants_approved"] = .bool(descendants.allSatisfy(approved.contains))
            }
            let memberRows = descendants.filter(layout.memberDescendants.contains).compactMap { id -> Value? in
                guard let member = byID[id] else { return nil }
                // The card's own effect names the adoptee's title; the agent gets its ID instead.
                var memberRow: [String: Value] = [
                    "session_id": .string(id.uuidString),
                    "title": .string(member.title),
                    "effect": .string("Moves with \(adoptee.uuidString) (descendant)"),
                    "moves_with_session_id": .string(adoptee.uuidString)
                ]
                if let approved { memberRow["approved"] = .bool(approved.contains(id)) }
                return .object(memberRow)
            }
            return [.object(row)] + memberRows
        }
    }

    /// Aggregates over every session the card would move.
    static func aggregates(_ items: [BatchConfirmationItem], layout: Layout?) -> [String: Value] {
        [
            "total_session_count": .int(items.count),
            "running_session_count": .int(items.count { layout?.runningSessionIDs.contains($0.sessionID) ?? false })
        ]
    }

    /// Projects a rendered card value (`SessionAdminMCPToolService.confirmationValue`).
    static func agentCardValue(_ card: PendingBatchConfirmation, rendered: Value) -> Value {
        guard card.operation == .adminAdopt, case var .object(object) = rendered else { return rendered }
        let layout = layout(for: card)
        object["items"] = .array(agentItems(card.items, layout: layout, approved: card.approvedSessionIDs))
        object.merge(aggregates(card.items, layout: layout)) { _, new in new }
        return .object(object)
    }

    /// Approved IDs an agent may see for a card: for `adopt`, only the approved adoptees.
    static func agentApprovedSessionIDs(_ card: PendingBatchConfirmation) -> [UUID] {
        let approved = card.items.map(\.sessionID).filter(card.approvedSessionIDs.contains)
        guard card.operation == .adminAdopt else { return approved }
        let visible = Set(layout(for: card)?.visibleSessionIDs ?? [])
        return approved.filter(visible.contains)
    }

    private static func layout(for card: PendingBatchConfirmation) -> Layout? {
        layout(
            granteeSessionID: card.granteeSessionID,
            idempotencyKey: card.idempotencyKey,
            itemSessionIDs: Set(card.items.map(\.sessionID))
        )
    }
}
