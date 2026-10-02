import Foundation

/// Single owner of user-visible copy for the unified sidebar oversight UI.
///
/// Scope: the row relationship marks, the shared lane menu ("Oversee by"), the inverse
/// "Oversee" menu, the Session-ID sheets, and the link confirmation
/// dialog. Existing dashboard/pill copy (`AgentMonitorPillModels`, resolver `uiMessage`
/// strings, persistence copy) stays in its current owners and is only referenced from here.
///
/// Session names, UUIDs, counts, and locations are data interpolated into these templates;
/// templates never decide authority — every action still revalidates exact endpoints through
/// `AgentSessionLinkRuntimeBridge`.
package enum AgentOversightUICopy {
    // MARK: - Mark glyphs (Fb iconography, approved 2026-09-30)

    /// Overseer role mark: a filled eye in this session's own group colour.
    package static let overseerMarkIcon = "eye.fill"
    /// Overseen role mark: an eye outline in the (first) overseer's group colour.
    package static let overseenMarkIcon = "eye"
    /// Both roles at once: the eye takes the row's own group colour, the ring its first
    /// overseer's.
    package static let dualRoleMarkIcon = "eye.circle.fill"
    /// Grey affordance on rows with no role, and the icon for the context-menu oversight entries.
    /// An eye only ever means a role, so the management affordance uses a different glyph.
    package static let manageOversightIcon = "person.2.badge.gearshape"

    // MARK: - Row mark tooltip (VoiceOver reads the same text)

    /// Renders at most three names, then a compact remainder: `A, B, C +2 more`.
    package static func truncatedNameList(_ names: [String]) -> String {
        let head = names.prefix(3).joined(separator: ", ")
        let remainder = names.count - 3
        guard remainder > 0 else { return head }
        return "\(head) +\(remainder) more"
    }

    /// The mark's single combined line (approved 2026-09-30):
    /// `Overseeing: A, B, C +N more · Overseen by: D, E · Created by: F`, with segments omitted
    /// when empty. When the creator is the row's only overseer, the last two segments collapse to
    /// `Created and overseen by: F`. Empty only when the row has no role and no provenance — callers
    /// only invoke this for rows that render a mark.
    package static func oversightMarkTooltip(
        overseeingNames: [String],
        overseenByNames: [String],
        creator: String?,
        creatorIsSoleOverseer: Bool
    ) -> String {
        var segments: [String] = []
        if !overseeingNames.isEmpty {
            segments.append("Overseeing: \(truncatedNameList(overseeingNames))")
        }
        if creatorIsSoleOverseer, let creator {
            segments.append("Created and overseen by: \(creator)")
        } else {
            if !overseenByNames.isEmpty {
                segments.append("Overseen by: \(truncatedNameList(overseenByNames))")
            }
            if let creator {
                segments.append("Created by: \(creator)")
            }
        }
        return segments.joined(separator: " · ")
    }

    /// Stashed-row provenance: the creator-navigation button's label. Stashed lanes have no live
    /// role, so this is the only place their origin still surfaces outside the menus.
    package static func createdByTooltip(creator: String) -> String {
        "Created by: \(creator)"
    }

    /// Hover affordance on rows that currently have no oversight role.
    package static let manageOversightTooltip = "Manage oversight"

    // MARK: - Menus

    package static let overseeByTitle = "Oversee by"
    /// Candidate submenu for starting outbound links — always "Oversee new ▸" (Cristian,
    /// 2026-10-01).
    package static let overseeNewTitle = "Oversee new"
    /// The link-unlink submenu. Approved by Cristian 2026-10-01.
    package static let unlinkTitle = "Unlink"
    package static let sessionIDMenuItem = "Session ID…"
    package static let noEligibleOverseers = "No eligible overseers"
    package static let noSessionsToOversee = "No sessions to oversee"
    /// Disabled labels over the linked-jump lists at the top of the menu — and for the
    /// matching groups inside Unlink ▸, which reuse these same constants. Colon-less per
    /// Cristian 2026-10-01.
    package static let overseeingSectionLabel = "Overseeing"
    package static let overseenBySectionLabel = "Overseen by"
    /// Creator-collapse variants of the section labels: the combined label when the creator is
    /// the row's only overseer, and the standalone label when the creator is not linked.
    /// Approved by Cristian 2026-10-01.
    package static let createdAndOverseenBySectionLabel = "Created and overseen by"
    package static let createdBySectionLabel = "Created by"
    /// SF Symbol marking jump items (the linked/creator sessions) so they read as links.
    /// Approved by Cristian 2026-10-01.
    package static let jumpItemIcon = "arrow.up.forward"
    /// Disabled header line atop the oversight menu when the row has no link sections to
    /// explain — one plain line about what the popup does. Approved by Cristian 2026-10-01.
    package static let oversightMenuHeader = "Manage session oversight"
    /// Disabled reason shown in the Oversee-by / Oversee-new context submenus on a row whose chat
    /// has no session ID yet (fresh chat before the first send). Approved by Cristian 2026-10-01.
    package static let oversightAvailableAfterFirstMessage = "Available after the first message"

    /// VoiceOver hint on a linked/creator jump item: selecting it opens that session.
    package static func openHint(_ displayName: String) -> String {
        "Opens \"\(displayName)\""
    }

    /// VoiceOver action name for a checked (linked) menu item: selecting it unlinks.
    package static func unlinkAccessibilityLabel(_ displayName: String) -> String {
        "Unlink \"\(displayName)\""
    }

    /// VoiceOver value of the Oversee menu (approved: "Overseeing {N}; {M} available").
    package static func overseeMenuAccessibilityValue(
        overseeingCount: Int,
        availableCount: Int
    ) -> String {
        "Overseeing \(overseeingCount); \(availableCount) available"
    }

    /// VoiceOver value of the Oversee-by menu — mirrors the approved Oversee value.
    /// TODO(copy-approval): derived phrasing, pending sign-off.
    package static func overseeByMenuAccessibilityValue(
        overseenByCount: Int,
        availableCount: Int
    ) -> String {
        "Overseen by \(overseenByCount); \(availableCount) available"
    }

    /// VoiceOver value of the Unlink ▸ submenu.
    package static func unlinkMenuAccessibilityValue(linkCount: Int) -> String {
        "\(linkCount) linked"
    }

    /// Unified capitalization for every "Copy Session ID" surface.
    package static let copySessionIDTitle = "Copy Session ID"

    /// Disabled placeholder shown in the Oversee-by menu when the row's exact target
    /// endpoint exists but cannot currently accept a new inbound link.
    package static func unavailableReasonItem(_ reason: String) -> String {
        reason
    }

    // MARK: - Session-ID sheet

    /// Outbound sheet (the row picks what it oversees): the row is `{observer}`.
    package static func sessionIDSheetTitle(observer: String) -> String {
        "Choose a session for \"\(observer)\" to oversee"
    }

    /// Inbound sheet (the row picks who oversees it): the row is `{session}`.
    package static func inboundSessionIDSheetTitle(session: String) -> String {
        "Choose an overseer for \"\(session)\""
    }

    package static let sessionIDFieldPlaceholder = "Session ID"
    package static let sessionIDFieldAccessibilityLabel = "Session ID to oversee"
    /// Approved VoiceOver label for the inbound (choose-an-overseer) field.
    package static let overseerSessionIDFieldAccessibilityLabel = "Overseer Session ID"
    package static let pasteFromClipboard = "Paste from Clipboard"
    package static let pasteFromClipboardHint = "Pastes a copied session ID"
    package static let overseeSessionButton = "Oversee session"
    /// Inbound submit: the pasted session becomes an overseer of this row.
    package static let addOverseerButton = "Add overseer"
    package static let cancelButton = "Cancel"

    // MARK: - Confirmation dialog

    package static func confirmationTitle(observer: String, target: String) -> String {
        "Allow \"\(observer)\" to oversee \"\(target)\"?"
    }

    package static func confirmationBody(observer: String, target: String) -> String {
        """
        “\(observer)” will be able to:
         • read \(target)’s status and conversation
         • send it instructions, steer it and stop its current run
         • answer its questions and one-time approval requests
         • compact its context, and be woken up by its updates

        You can unlink anytime.
        """
    }

    package static let confirmationAllowButton = "Allow oversight"
    package static let confirmationCancelButton = "Cancel"
    package static let confirmationSuppressionCheckbox = "Don’t ask again"

    /// Shown when the endpoints or menu options captured before a confirm/submit no longer
    /// resolve — the sole stale-state error for every oversight surface.
    package static let staleSelectionMessage = "Sessions changed. Please choose again."

    /// Approved fallback when no resolver is wired (unreachable in the current wiring).
    package static let oversightUnavailableMessage = "Oversight is unavailable right now."
}
