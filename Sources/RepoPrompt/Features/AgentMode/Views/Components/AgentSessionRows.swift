import AppKit
import RepoPromptDomainRuntime
import SwiftUI

// MARK: - Agent Session Row

/// Code-level UX switch (deliberately not a user setting, repurposed from the overseer-only
/// variant): `false` lets every role mark open the unified oversight menu on click; `true`
/// renders all marks passive — tooltip only. Cristian decided right-click is the only
/// interaction (2026-10-02): the click affordance and the hover gear both made oversight
/// too obscure to be a habit, so marks are passive status.
@MainActor
var agentOversightRoleMarksArePassive = true

/// The mark opens the unified oversight menu unless the passive switch above is on.
@MainActor
func agentSessionRowOversightMarkIsInteractive(role _: AgentSessionOversightRole) -> Bool {
    !agentOversightRoleMarksArePassive
}

struct AgentSessionRow: View {
    let title: String
    let isActive: Bool
    /// Fb mark model: the row's own group slot when it oversees, plus its overseers in
    /// link-creation order. Drives the inline eye mark; `.none` renders nothing.
    var oversightRole = AgentSessionOversightRole.none
    /// Overseer-creator provenance for the tooltip's `Created by:` segment. Live links still own
    /// the mark's colour; this never paints a separate origin mark.
    var creatorSessionID: UUID?
    var creatorDisplayName: String?
    /// Revalidates and navigates to the lane's creator for the `Open creator "{name}"` item.
    /// The label itself comes from the shared menu model.
    var onOpenCreator: (() -> Void)?
    let isPinned: Bool
    let isMCPControlled: Bool
    let runState: AgentSessionRunState
    /// When non-nil, the session raised a completed/failed/waiting transition
    /// while the user was NOT viewing it. Drives a persistent attention badge
    /// that survives re-renders until the session is selected/resumed or the
    /// user dismisses the badge explicitly.
    var attentionRunState: AgentSessionRunState?
    /// Bound-worktree visual identity for this session (Item 10). When non-nil,
    /// a small colored dot/ring is overlaid at the bottom-right of the status
    /// plate without shifting the title — see `worktreeMarker`.
    var worktree: AgentWorktreeIndicator?
    /// Active worktree merge attention for this session (Item 8). When non-nil
    /// the row paints a compact merge marker after the title slot and exposes
    /// it through the row's hover tooltip and accessibility label without
    /// shifting layout — see `mergeAttentionBadge`.
    var worktreeMergeAttention: AgentWorktreeMergeAttention?
    let threadDepth: Int
    var hasThreadChildren: Bool = false
    var isThreadCollapsed: Bool = false
    var hiddenThreadDescendantCount: Int = 0
    /// Number of descendants hidden under this collapsed parent that carry
    /// an unseen run-state attention badge. When > 0 the hidden-count chip is
    /// tinted to mirror the mcp-status-style "something happened" cue.
    var hiddenThreadDescendantAttentionCount: Int = 0
    var onToggleThreadCollapse: (() -> Void)?
    var isSelected = false
    var showsSelectionPresentation = false
    var isInteractionEnabled = true
    var commandProgressKind: AgentSidebarBulkActionKind?
    let onSelectionGesture: (AgentSidebarSelectionGesture) -> AgentSidebarSelectionGestureDisposition
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    var onStash: (() -> Void)?
    let onDelete: () -> Void
    let onRename: (String) -> Void
    var onDismissAttention: (() -> Void)?
    /// Copies this row's exact canonical session UUID.
    ///
    /// Non-nil only for live, exactly-bound, top-level sessions. The closure revalidates the captured
    /// generation-bearing target immediately before writing and returns `false` when it went stale,
    /// so a stale row performs zero clipboard writes and shows no false success.
    var onCopySessionID: (() -> Bool)?
    /// Bounded current row facts for rendering, never the full available choices.
    var resolveSidebarOversightSummary: (@MainActor () -> AgentSidebarOversightSummary?)?
    /// Fresh full choices at activation; action handlers revalidate captured exact identities.
    var resolveSidebarOversightMenu: (@MainActor () -> AgentSidebarOversightMenuProps?)?
    var prepareSidebarOversightMenu: (@MainActor () -> Void)?
    /// Non-nil when the row could host oversight but lacks a bound session ID (a fresh chat
    /// before the first send, or any ID-less row): the context menu then offers the Oversee-by
    /// and Oversee submenus containing only this disabled reason.
    var sidebarOversightUnavailableReason: String?
    /// Resolves the row's current exact target even when lifecycle eligibility makes its menu nil.
    /// This fences feedback from a system menu that stayed open across an in-place rebind.
    var resolveSidebarOversightTargetEndpoint:
        (@MainActor () -> DomainAgentSessionLinkEndpointIdentity?)?
    /// Exact Add and Stop callbacks. They never focus either endpoint's window and never mutate row
    /// presentation optimistically; the next projection publication supplies relationship state.
    var onAddSidebarOversight: (@MainActor (
        DomainAgentSessionLinkEndpointIdentity,
        DomainAgentSessionLinkEndpointIdentity
    ) async -> AgentSidebarOversightActionOutcome)?
    var onStopSidebarOversight: (@MainActor (
        DomainAgentSessionLinkEndpointIdentity,
        DomainAgentSessionLinkEndpointIdentity,
        DomainAgentSessionLinkReference
    ) async -> AgentSidebarOversightActionOutcome)?
    /// General exact-endpoint Add for the inverse direction (this row as observer). Unlike
    /// `onAddSidebarOversight` it may create the row's *first* outbound link.
    var onAddOutboundOversight: (@MainActor (
        DomainAgentSessionLinkEndpointIdentity,
        DomainAgentSessionLinkEndpointIdentity
    ) async -> AgentSidebarOversightActionOutcome)?
    /// Read-only pasted-ID resolution for the row's Session-ID sheets. Inbound resolves the
    /// prospective overseer (existing-overseer rule); outbound resolves the prospective target.
    var resolveOverseerSessionIDCandidate: (@MainActor (
        String
    ) async -> Result<AgentOversightSessionIDResolution, AgentOversightResolutionMessage>)?
    var resolveTargetSessionIDCandidate: (@MainActor (
        String
    ) async -> Result<AgentOversightSessionIDResolution, AgentOversightResolutionMessage>)?
    /// Navigates to a linked peer's exact route (the `Open "{name}"` menu items).
    /// Jump target for a linked session row item — the caller (sidebar) owns routing so the row
    /// never references App-layer deep-link types directly.
    var onOpenLinkedSession: (@MainActor (DomainAgentSessionLinkEndpointIdentity) -> Void)?
    let sessionIDCopyAction: AgentSidebarSessionIDCopyAction

    @State private var isHovered = false
    @State private var isCopySessionIDHovered = false
    /// One generation-qualified busy marker per relationship. Different observers of the same target
    /// remain independently actionable.
    @State private var sidebarOversightBusyKeys: Set<AgentSidebarOversightActionKey> = []
    /// Survives hover loss and system-menu dismissal. Only a later action, success, exact target
    /// replacement, or row removal clears it.
    @State private var sidebarOversightFailureMessage: String?
    /// Invalidates every in-flight presentation outcome only when the row's exact target changes.
    /// Unrelated exact action keys may finish independently and update feedback in completion order.
    @State private var sidebarOversightTargetRevision: UInt64 = 0
    @State private var copiedFeedbackGeneration: UInt64 = 0
    @State private var showsCopiedFeedback = false
    @State private var isPinHovered = false
    @State private var isDeleteHovered = false
    @State private var isRenameHovered = false
    @State private var isStashHovered = false
    @State private var isDisclosureHovered = false
    @State private var isDismissAttentionHovered = false
    @State private var showRenameAlert = false
    @State private var showDeleteConfirmation = false
    @State private var renameText = ""
    /// Presented Session-ID sheet request, carrying the direction and the exact row endpoint
    /// captured when the menu item was chosen.
    @State private var oversightSessionIDSheet: OversightIDSheetRequest?

    private struct OversightIDSheetRequest: Identifiable {
        enum Direction {
            /// The pasted ID names the prospective overseer of this row.
            case chooseOverseer
            /// The pasted ID names the prospective target for this row.
            case chooseTarget
        }

        let direction: Direction
        let rowEndpoint: DomainAgentSessionLinkEndpointIdentity
        let rowDisplayName: String
        let id = UUID()
    }

    // MARK: - Context Menu Snapshot

    /// Captured once at accepted native opening, not on hover. The presenter materializes
    /// an independent NSMenu, so subsequent row updates cannot change its item count.
    private struct ContextMenuSnapshot {
        var isInteractionEnabled: Bool
        var showsSelectionPresentation: Bool
        var hasAttentionRunState: Bool
        var hasOnStash: Bool
        var hasOnDismissAttention: Bool
        /// Freezes root relationship sections. Only the two candidate submenus resolve
        /// again at their own AppKit pre-tracking update boundary.
        var sidebarOversightMenu: AgentSidebarOversightMenuProps?
        /// Frozen alongside the menu for the same reason — an ID gaining a session mid-menu
        /// must not swap a disabled pair for a live section while the menu is open.
        var sidebarOversightUnavailableReason: String?
    }

    @StateObject private var contextMenuAnchor = StableMenuAnchor()

    /// The oversight menu as it should appear, or nil when the section must not be offered.
    /// Reads the stored exact projection only when a menu is opened.
    ///
    /// Ineligible or empty directions render a greyed reason inside the menu rather than hiding
    /// it, so a non-nil projection is always presentable when the action callbacks exist.
    private var presentableSidebarOversightMenu: AgentSidebarOversightMenuProps? {
        guard allowsDirectMutations,
              let menu = resolveSidebarOversightMenu?(),
              onAddSidebarOversight != nil,
              onStopSidebarOversight != nil
        else { return nil }
        return menu
    }

    /// An ID-less row (a fresh chat before the first send) still lists both Oversee submenus in
    /// its context menu — enabled labels containing only the disabled reason — so the feature is
    /// discoverable without minting a session ID early. Suppressed while direct mutations are
    /// off (multi-select, bulk action in flight) — those modes hide the oversight section.
    var showsDisabledOversightContextSubmenus: Bool {
        allowsDirectMutations
            && sidebarOversightUnavailableReason != nil
            && resolveSidebarOversightSummary?() == nil
    }

    private func currentContextMenuSnapshot() -> ContextMenuSnapshot {
        if allowsDirectMutations { prepareSidebarOversightMenu?() }
        let menu = presentableSidebarOversightMenu
        var unavailableReason = sidebarOversightUnavailableReason
        if unavailableReason == nil,
           resolveSidebarOversightMenu != nil,
           onAddSidebarOversight != nil,
           onStopSidebarOversight != nil
        {
            unavailableReason = AgentOversightUICopy.oversightMenuUnavailableMessage
        }
        return ContextMenuSnapshot(
            isInteractionEnabled: isInteractionEnabled,
            showsSelectionPresentation: showsSelectionPresentation,
            hasAttentionRunState: attentionRunState != nil,
            hasOnStash: onStash != nil,
            hasOnDismissAttention: onDismissAttention != nil,
            sidebarOversightMenu: menu,
            sidebarOversightUnavailableReason: allowsDirectMutations && menu == nil
                ? unavailableReason : nil
        )
    }

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var rowMinHeight: CGFloat {
        fontPreset.scaledClamped(28, min: 28, max: 38)
    }

    private var rowHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(10, max: 14)
    }

    private var rowVerticalPadding: CGFloat {
        fontPreset.scaledClamped(4, max: 7)
    }

    private var rowCornerRadius: CGFloat {
        fontPreset.scaledClamped(14, max: 18)
    }

    private var rowSpacing: CGFloat {
        fontPreset.scaledClamped(8, max: 11)
    }

    private var titlePinSpacing: CGFloat {
        fontPreset.scaledClamped(6, max: 8)
    }

    private var titleVStackSpacing: CGFloat {
        fontPreset.scaledClamped(2, max: 3)
    }

    private var pinFontSize: CGFloat {
        fontPreset.scaledClamped(10, max: 13)
    }

    private var oversightMarkFontSize: CGFloat {
        fontPreset.scaledClamped(10, min: 9, max: 12)
    }

    private var chipHorizontalPadding: CGFloat {
        fontPreset.scaledClamped(5, max: 7)
    }

    private var chipVerticalPadding: CGFloat {
        fontPreset.scaledClamped(1, max: 2)
    }

    private var leadingIndent: CGFloat {
        CGFloat(threadDepth) * fontPreset.scaledClamped(14, min: 14, max: 20)
    }

    private var showsDisclosureChevron: Bool {
        hasThreadChildren && onToggleThreadCollapse != nil
    }

    private var hiddenCountTooltip: String {
        let base = hiddenThreadDescendantCount == 1
            ? "1 sub-agent chat hidden"
            : "\(hiddenThreadDescendantCount) sub-agent chats hidden"
        guard hiddenThreadDescendantAttentionCount > 0 else { return base }
        let suffix = hiddenThreadDescendantAttentionCount == 1
            ? "1 needs attention"
            : "\(hiddenThreadDescendantAttentionCount) need attention"
        return base + " — " + suffix
    }

    private var disclosureAccessibilityLabel: String {
        isThreadCollapsed ? "Expand sub-agent chats" : "Collapse sub-agent chats"
    }

    private var pinActionLabel: String {
        isPinned ? "Unpin chat" : "Pin chat"
    }

    private var copySessionIDActionLabel: String {
        AgentOversightUICopy.copySessionIDTitle
    }

    private var copySessionIDIconColor: Color {
        if showsCopiedFeedback {
            return .green
        }
        return isCopySessionIDHovered ? .accentColor : .secondary
    }

    /// Revision-guarded transient confirmation: a later copy always supersedes an in-flight reset.
    private func performCopySessionID() {
        guard let onCopySessionID, onCopySessionID() else { return }
        copiedFeedbackGeneration &+= 1
        let generation = copiedFeedbackGeneration
        showsCopiedFeedback = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard copiedFeedbackGeneration == generation else { return }
            showsCopiedFeedback = false
        }
    }

    /// Resolves the full menu only when the AppKit trigger opens it, on the main actor without a
    /// Task hop. `allowsDirectMutations` repeats the render-time mount gate: it closes the
    /// small window where a click lands between a mode flip and the re-render that removes
    /// the trigger; the action handlers then revalidate exact endpoints as before.
    private func sidebarOversightStableMenuItems() -> [StableMenuItem] {
        MainActor.assumeIsolated {
            guard allowsDirectMutations, let menu = resolveSidebarOversightMenu?() else { return [] }
            return sidebarOversightMenuItems(menu)
        }
    }

    private func sidebarOversightMenuItems(
        _ menu: AgentSidebarOversightMenuProps
    ) -> [StableMenuItem] {
        Self.sidebarOversightMenuItems(
            menu,
            busyKeys: sidebarOversightBusyKeys,
            actions: AgentSidebarOversightMenuActions(
                openLinkedSession: { openLinkedSession($0) },
                openCreator: onOpenCreator,
                addInbound: { addSidebarOversight($0, menu: menu) },
                addOutbound: { addOutboundOversight($0, menu: menu) },
                unlink: { observerEndpoint, targetEndpoint, reference in
                    stopSidebarOversightLink(
                        observerEndpoint: observerEndpoint,
                        targetEndpoint: targetEndpoint,
                        reference: reference
                    )
                },
                presentChooseTargetSheet: {
                    presentOversightSessionIDSheet(.chooseTarget, menu: menu)
                },
                presentChooseOverseerSheet: {
                    presentOversightSessionIDSheet(.chooseOverseer, menu: menu)
                }
            )
        )
    }

    /// The right-click menu's fixed root tree for `StableMenuContextRegion`:
    /// the oversight section reuses the same builder the mark and hover menus present, and
    /// the standard row actions mirror the removed `.contextMenu` item-for-item. The builder
    /// reads the opening snapshot. Candidate submenus read live props when AppKit asks
    /// to update them, without replacing or changing the root items mid-track.
    private func sidebarContextMenuItems(_ snapshot: ContextMenuSnapshot) -> [StableMenuItem] {
        MainActor.assumeIsolated {
            var items: [StableMenuItem] = []
            if let menu = snapshot.sidebarOversightMenu {
                items += sidebarOversightMenuItems(menu)
                items.append(.separator)
            } else if let reason = snapshot.sidebarOversightUnavailableReason {
                items += sidebarOversightUnavailableMenuItems(reason: reason)
                items.append(.separator)
            }

            items = items.map { item in
                guard item.title == AgentOversightUICopy.overseeNewTitle
                    || item.title == AgentOversightUICopy.overseeByTitle
                else { return item }
                return item.refreshingSubmenu {
                    if allowsDirectMutations { prepareSidebarOversightMenu?() }
                    guard let menu = presentableSidebarOversightMenu else {
                        let reason = sidebarOversightUnavailableReason
                            ?? AgentOversightUICopy.oversightMenuUnavailableMessage
                        return .submenu(item.title, accessibilityValue: reason, items: [.message(reason)])
                    }
                    return sidebarOversightMenuItems(menu).first { $0.title == item.title } ?? item
                }
            }

            guard !snapshot.showsSelectionPresentation else { return items }

            if snapshot.isInteractionEnabled {
                items.append(.action("Select chat") { toggleSelection() })
                items.append(.separator)
                items.append(.action(pinActionLabel) { onTogglePin() })
                items.append(.action(renameActionLabel) { beginRename() })
            }

            if onCopySessionID != nil {
                items.append(.action(copySessionIDActionLabel) { performCopySessionID() })
            } else {
                items.append(.action(
                    AgentSidebarSessionIDCopyAction.menuTitle,
                    isEnabled: sessionIDCopyAction.isEnabled
                ) { sessionIDCopyAction.perform() })
            }

            if snapshot.isInteractionEnabled, snapshot.hasOnStash {
                items.append(.action(stashActionLabel) { onStash?() })
            }
            if snapshot.hasAttentionRunState, snapshot.hasOnDismissAttention {
                items.append(.action(dismissAttentionActionLabel) { onDismissAttention?() })
            }
            if snapshot.isInteractionEnabled {
                items.append(.separator)
                items.append(
                    .action(deleteActionLabel, style: .warning) { requestDeleteConfirmation() }
                )
            }
            return items
        }
    }

    /// The two Oversee submenus for an unavailable or ID-less row: the labels stay
    /// enabled so the reason is discoverable, while the only item inside each is the
    /// disabled explanation. Same order as the live menu: "Link overseer" leads.
    private func sidebarOversightUnavailableMenuItems(reason: String) -> [StableMenuItem] {
        [
            .submenu(
                AgentOversightUICopy.overseeByTitle,
                imageSystemName: AgentOversightUICopy.manageOversightIcon,
                accessibilityLabel: AgentOversightUICopy.overseeByTitle,
                accessibilityValue: reason,
                items: [.message(reason)]
            ),
            .submenu(
                AgentOversightUICopy.overseeNewTitle,
                imageSystemName: AgentOversightUICopy.manageOversightIcon,
                accessibilityLabel: AgentOversightUICopy.overseeNewTitle,
                accessibilityValue: reason,
                items: [.message(reason)]
            )
        ]
    }

    private func addSidebarOversight(
        _ option: AgentSidebarOversightMenuProps.ObserverOption,
        menu: AgentSidebarOversightMenuProps
    ) {
        let key = AgentSidebarOversightActionKey.add(
            observerEndpoint: option.peerEndpoint,
            targetEndpoint: menu.targetEndpoint
        )
        guard let revision = beginSidebarOversightAction(key) else { return }
        guard let current = resolveSidebarOversightMenu?(),
              current.targetEndpoint == menu.targetEndpoint,
              current.availableObservers.contains(where: {
                  $0.peerEndpoint == option.peerEndpoint
              }),
              let onAddSidebarOversight
        else {
            sidebarOversightBusyKeys.remove(key)
            setSynchronousSidebarOversightFailure(
                AgentOversightUICopy.staleSelectionMessage,
                revision: revision,
                targetEndpoint: menu.targetEndpoint
            )
            return
        }

        // Deliberately unstructured: dismissing the system menu or losing hover must not cancel an
        // authority transaction that already started.
        Task { @MainActor in
            // Shared UI confirmation gate. The dialog captures these exact endpoints; the bridge
            // revalidates them again on acceptance inside the durable Add transaction.
            let confirmed = await AgentOversightLinkConfirmation.confirm(
                observerLabel: option.displayName,
                targetLabel: menu.targetDisplayName,
                windowID: menu.targetEndpoint.windowID
            )
            guard confirmed else {
                sidebarOversightBusyKeys.remove(key)
                return
            }
            let outcome = await onAddSidebarOversight(
                option.peerEndpoint,
                menu.targetEndpoint
            )
            guard sidebarOversightBusyKeys.remove(key) != nil else { return }
            finishSidebarOversightAction(
                outcome,
                revision: revision,
                targetEndpoint: menu.targetEndpoint
            )
        }
    }

    /// Inverse-direction Add: this row becomes the observer of the chosen target. Uses the general
    /// exact-endpoint Add so a row can acquire its *first* outbound link — the inbound menu's
    /// existing-overseer precondition does not apply to this direction.
    private func addOutboundOversight(
        _ option: AgentSidebarOversightMenuProps.TargetOption,
        menu: AgentSidebarOversightMenuProps
    ) {
        let key = AgentSidebarOversightActionKey.add(
            observerEndpoint: menu.targetEndpoint,
            targetEndpoint: option.peerEndpoint
        )
        guard let revision = beginSidebarOversightAction(key) else { return }
        guard let current = resolveSidebarOversightMenu?(),
              current.targetEndpoint == menu.targetEndpoint,
              current.observerIneligibleReason == nil,
              current.availableTargets.contains(where: {
                  $0.peerEndpoint == option.peerEndpoint
              }),
              let onAddOutboundOversight
        else {
            sidebarOversightBusyKeys.remove(key)
            setSynchronousSidebarOversightFailure(
                AgentOversightUICopy.staleSelectionMessage,
                revision: revision,
                targetEndpoint: menu.targetEndpoint
            )
            return
        }

        // Deliberately unstructured: dismissing the system menu or losing hover must not cancel an
        // authority transaction that already started.
        Task { @MainActor in
            let confirmed = await AgentOversightLinkConfirmation.confirm(
                observerLabel: menu.targetDisplayName,
                targetLabel: option.displayName,
                windowID: menu.targetEndpoint.windowID
            )
            guard confirmed else {
                sidebarOversightBusyKeys.remove(key)
                return
            }
            let outcome = await onAddOutboundOversight(
                menu.targetEndpoint,
                option.peerEndpoint
            )
            guard sidebarOversightBusyKeys.remove(key) != nil else { return }
            finishSidebarOversightAction(
                outcome,
                revision: revision,
                targetEndpoint: menu.targetEndpoint
            )
        }
    }

    /// Unlinks one generation-qualified relationship in either direction. The row endpoint used for
    /// feedback fencing is always `menu.targetEndpoint` — the row this view renders.
    private func stopSidebarOversightLink(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
        reference: DomainAgentSessionLinkReference
    ) {
        let key = AgentSidebarOversightActionKey.unlink(
            observerEndpoint: observerEndpoint,
            targetEndpoint: targetEndpoint,
            reference: reference
        )
        let rowEndpoint = resolveSidebarOversightTargetEndpoint?() ?? targetEndpoint
        guard let revision = beginSidebarOversightAction(key) else { return }
        guard let onStopSidebarOversight else {
            sidebarOversightBusyKeys.remove(key)
            setSidebarOversightFailure(
                "That oversight relationship is no longer active.",
                revision: revision,
                targetEndpoint: rowEndpoint
            )
            return
        }

        // Stop intentionally does not re-resolve the peer option. Its captured authority reference
        // is the proof that lets a row unlink a peer whose live candidate has disappeared.
        Task { @MainActor in
            let outcome = await onStopSidebarOversight(
                observerEndpoint,
                targetEndpoint,
                reference
            )
            guard sidebarOversightBusyKeys.remove(key) != nil else { return }
            finishSidebarOversightAction(
                outcome,
                revision: revision,
                targetEndpoint: rowEndpoint
            )
        }
    }

    private func openLinkedSession(_ peerEndpoint: DomainAgentSessionLinkEndpointIdentity) {
        onOpenLinkedSession?(peerEndpoint)
    }

    // MARK: - Session-ID sheets

    private func presentOversightSessionIDSheet(
        _ direction: OversightIDSheetRequest.Direction,
        menu: AgentSidebarOversightMenuProps
    ) {
        oversightSessionIDSheet = OversightIDSheetRequest(
            direction: direction,
            rowEndpoint: menu.targetEndpoint,
            rowDisplayName: menu.targetDisplayName
        )
    }

    @ViewBuilder
    private func oversightSessionIDSheetView(
        for request: OversightIDSheetRequest
    ) -> some View {
        switch request.direction {
        case .chooseOverseer:
            AgentOversightSessionIDSheet(
                title: AgentOversightUICopy.inboundSessionIDSheetTitle(
                    session: request.rowDisplayName
                ),
                fieldAccessibilityLabel: AgentOversightUICopy
                    .overseerSessionIDFieldAccessibilityLabel,
                submitLabel: AgentOversightUICopy.addOverseerButton,
                resolve: { raw in
                    guard let resolveOverseerSessionIDCandidate else {
                        return .failure(AgentOversightResolutionMessage(
                            message: AgentOversightUICopy.oversightUnavailableMessage
                        ))
                    }
                    return await resolveOverseerSessionIDCandidate(raw)
                },
                submit: { peer in
                    await submitOversightSessionID(peer, direction: .chooseOverseer, request: request)
                },
                onDismiss: { oversightSessionIDSheet = nil }
            )
        case .chooseTarget:
            AgentOversightSessionIDSheet(
                title: AgentOversightUICopy.sessionIDSheetTitle(
                    observer: request.rowDisplayName
                ),
                fieldAccessibilityLabel: AgentOversightUICopy.sessionIDFieldAccessibilityLabel,
                submitLabel: AgentOversightUICopy.overseeSessionButton,
                resolve: { raw in
                    guard let resolveTargetSessionIDCandidate else {
                        return .failure(AgentOversightResolutionMessage(
                            message: AgentOversightUICopy.oversightUnavailableMessage
                        ))
                    }
                    return await resolveTargetSessionIDCandidate(raw)
                },
                submit: { peer in
                    await submitOversightSessionID(peer, direction: .chooseTarget, request: request)
                },
                onDismiss: { oversightSessionIDSheet = nil }
            )
        }
    }

    /// Confirms and submits a Session-ID-sheet link. The exact row endpoint captured when the menu
    /// item was chosen is revalidated here — if the row rebound while the sheet or dialog was open,
    /// the request fails instead of retargeting a replacement incarnation.
    private func submitOversightSessionID(
        _ peer: AgentOversightSessionIDSheet.ResolvedPeer,
        direction: OversightIDSheetRequest.Direction,
        request: OversightIDSheetRequest
    ) async -> AgentOversightSessionIDSubmitOutcome {
        guard resolveSidebarOversightTargetEndpoint?() == request.rowEndpoint else {
            return .failed(AgentOversightUICopy.staleSelectionMessage)
        }
        let confirmed: Bool
        let outcome: AgentSidebarOversightActionOutcome
        switch direction {
        case .chooseOverseer:
            confirmed = await AgentOversightLinkConfirmation.confirm(
                observerLabel: peer.displayName,
                targetLabel: request.rowDisplayName,
                windowID: request.rowEndpoint.windowID
            )
            guard confirmed else { return .cancelled }
            guard let onAddSidebarOversight else {
                return .failed(AgentOversightUICopy.staleSelectionMessage)
            }
            outcome = await onAddSidebarOversight(peer.endpoint, request.rowEndpoint)
        case .chooseTarget:
            confirmed = await AgentOversightLinkConfirmation.confirm(
                observerLabel: request.rowDisplayName,
                targetLabel: peer.displayName,
                windowID: request.rowEndpoint.windowID
            )
            guard confirmed else { return .cancelled }
            guard let onAddOutboundOversight else {
                return .failed(AgentOversightUICopy.staleSelectionMessage)
            }
            outcome = await onAddOutboundOversight(request.rowEndpoint, peer.endpoint)
        }
        switch outcome {
        case .changed, .alreadyInRequestedState:
            return .succeeded
        case let .failed(message):
            return .failed(message)
        }
    }

    private func beginSidebarOversightAction(
        _ key: AgentSidebarOversightActionKey
    ) -> UInt64? {
        guard sidebarOversightBusyKeys.insert(key).inserted else { return nil }
        sidebarOversightFailureMessage = nil
        return sidebarOversightTargetRevision
    }

    private func finishSidebarOversightAction(
        _ outcome: AgentSidebarOversightActionOutcome,
        revision: UInt64,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        switch outcome {
        case .changed, .alreadyInRequestedState:
            setSidebarOversightFailure(nil, revision: revision, targetEndpoint: targetEndpoint)
        case let .failed(message):
            setSidebarOversightFailure(message, revision: revision, targetEndpoint: targetEndpoint)
        }
    }

    /// Stores a failure discovered by the synchronous Add re-resolution. The menu may have become
    /// `nil` precisely because the captured target or observer just became ineligible, so requiring a
    /// currently resolvable target here would suppress the stale-option feedback. If the row actually
    /// rebound, its endpoint `onChange` clears this state before any later presentation can retain it.
    private func setSynchronousSidebarOversightFailure(
        _ message: String,
        revision: UInt64,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard sidebarOversightTargetRevision == revision,
              resolveSidebarOversightTargetEndpoint?() == targetEndpoint,
              sidebarOversightFailureMessage != message
        else {
            return
        }
        sidebarOversightFailureMessage = message
        announceSidebarOversightFailure(message)
    }

    /// Writes post-await feedback only for an action on the row's still-current exact target.
    /// Unrelated action keys remain independent and update the single feedback line in completion
    /// order; endpoint replacement invalidates every captured revision at once.
    private func setSidebarOversightFailure(
        _ message: String?,
        revision: UInt64,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard sidebarOversightTargetRevision == revision,
              resolveSidebarOversightTargetEndpoint?() == targetEndpoint,
              sidebarOversightFailureMessage != message
        else {
            return
        }
        sidebarOversightFailureMessage = message
        if let message {
            announceSidebarOversightFailure(message)
        }
    }

    private func resetSidebarOversightPresentation() {
        sidebarOversightTargetRevision &+= 1
        sidebarOversightBusyKeys.removeAll()
        sidebarOversightFailureMessage = nil
    }

    /// Announces a newly stored failure once. Keeping this out of `body` prevents a hover, scroll, or
    /// projection repaint from repeating the VoiceOver announcement.
    private func announceSidebarOversightFailure(_ message: String) {
        let element: Any = if let window = NSApplication.shared.keyWindow {
            window
        } else {
            NSApplication.shared
        }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    private var renameActionLabel: String {
        "Rename chat"
    }

    private var stashActionLabel: String {
        "Stash chat for later"
    }

    private var dismissAttentionActionLabel: String {
        "Dismiss status badge"
    }

    private var deleteActionLabel: String {
        "Delete chat"
    }

    private var allowsDirectMutations: Bool {
        isInteractionEnabled && !showsSelectionPresentation
    }

    private var rowAccessibilityValue: String {
        var parts = [isSelected ? "Selected" : "Not selected"]
        // VoiceOver reads the same combined line the mark shows on hover.
        if oversightRole.hasMark {
            parts.append(oversightMarkTooltip())
        }
        if let sidebarOversightFailureMessage {
            parts.append("Oversight action failed: \(sidebarOversightFailureMessage)")
        }
        return parts.joined(separator: "; ")
    }

    private func beginRename() {
        guard allowsDirectMutations else { return }
        renameText = title
        showRenameAlert = true
    }

    private func requestDeleteConfirmation() {
        guard allowsDirectMutations else { return }
        showDeleteConfirmation = true
    }

    private var currentSelectionGesture: AgentSidebarSelectionGesture {
        var modifiers: AgentSidebarSelectionModifiers = []
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return AgentSidebarSelectionGesture(modifiers: modifiers)
    }

    private func handleRowTap() {
        guard isInteractionEnabled else { return }
        if onSelectionGesture(currentSelectionGesture) == .activate {
            onSelect()
        }
    }

    private func toggleSelection() {
        guard isInteractionEnabled else { return }
        _ = onSelectionGesture(.toggle)
    }

    // MARK: - Oversight role mark (Fb iconography)

    /// The mark's combined tooltip/VoiceOver line — `Overseeing: … · Overseen by: … · Created
    /// by: …`, segments omitted when empty. Only called for rows carrying a role, so at least one
    /// segment is always present; provenance joins the same line rather than painting its own mark.
    private func oversightMarkTooltip() -> String {
        let creatorIsSoleOverseer = oversightRole.overseers.count == 1
            && oversightRole.overseers.first?.sessionID == creatorSessionID
        return AgentOversightUICopy.oversightMarkTooltip(
            overseeingNames: oversightRole.overseeingNames,
            overseenByNames: oversightRole.overseers.map(\.displayName),
            creator: creatorDisplayName,
            creatorIsSoleOverseer: creatorIsSoleOverseer
        )
    }

    /// The always-visible role mark, drawn inline just before the title. One mark per row:
    /// `eye.fill` in the row's own group colour when it oversees, `eye` in its first overseer's
    /// group colour when it is overseen, and a two-tone `eye.circle.fill` when both apply. Several
    /// overseers keep the first overseer's colour (link-creation order) plus a count superscript.
    /// When mutations are allowed, clicking opens the Oversee-by lane menu — the same menu model
    /// as the hover affordance and the context submenu. Otherwise it stays a passive state marker
    /// so it can never offer a mutation the row forbids.
    @ViewBuilder
    private func oversightMark(
        summary: AgentSidebarOversightSummary?,
        tooltip: String,
        interactive: Bool
    ) -> some View {
        if interactive, let summary {
            // A menu label image template-renders, which would flatten the palette
            // colours (and the two-tone/count colours) to the control tint — and to white on
            // selected rows. The coloured glyph therefore stays ordinary content underneath a
            // clear-label StableMenuButton that owns the same hit target; the glyph itself
            // never hit-tests. The AppKit menu also survives the SwiftUI invalidations that
            // repopulated — and dismissed — the live SwiftUI Menu mid-browse.
            oversightMarkGlyph
                .accessibilityHidden(true)
                .overlay {
                    StableMenuButton(
                        items: sidebarOversightStableMenuItems,
                        triggerStyle: .plain
                    ) {
                        // `Color.clear` produces no hit region, which left the
                        // mark's overlay button unclickable — the explicit shape
                        // keeps it transparent AND clickable.
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel(tooltip)
                    .accessibilityValue(summary.accessibilityValue)
                }
                .fixedSize()
        } else {
            // No hover tooltip: the combined line is the mark's VoiceOver label only — the
            // click menu's sections carry the same information for sighted users.
            oversightMarkGlyph
                .fixedSize()
                .accessibilityLabel(tooltip)
        }
    }

    @ViewBuilder
    private var oversightMarkGlyph: some View {
        let ownColor = oversightRole.ownOverseerSlot.map { AgentOversightPalette.color(for: $0) }
        let overseerColor = oversightRole.overseers.first
            .map { AgentOversightPalette.color(for: $0.slot) }
        HStack(spacing: 1) {
            switch (ownColor, overseerColor) {
            case let (.some(own), .some(overseer)):
                // Both roles: the eye keeps this row's own group colour, the ring its overseer's.
                Image(systemName: AgentOversightUICopy.dualRoleMarkIcon)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(own, overseer)
            case let (.some(own), .none):
                Image(systemName: AgentOversightUICopy.overseerMarkIcon)
                    .foregroundStyle(own)
            case let (.none, .some(overseer)):
                Image(systemName: AgentOversightUICopy.overseenMarkIcon)
                    .foregroundStyle(overseer)
            case (.none, .none):
                EmptyView()
            }
            if oversightRole.overseers.count > 1 {
                Text("\(oversightRole.overseers.count)")
                    .font(.system(size: 7, weight: .bold))
                    .baselineOffset(4)
                    .foregroundStyle(overseerColor ?? .secondary)
            }
        }
        .font(.system(size: oversightMarkFontSize, weight: .semibold))
    }

    @ViewBuilder
    private var sidebarOversightFailureLine: some View {
        if let sidebarOversightFailureMessage {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(sidebarOversightFailureMessage)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
            .foregroundStyle(Color.red)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Oversight action failed")
            .accessibilityValue(sidebarOversightFailureMessage)
        }
    }

    var body: some View {
        let sidebarOversightSummary = resolveSidebarOversightSummary?()
        let sidebarOversightTargetEndpoint = resolveSidebarOversightTargetEndpoint?()
        HStack(spacing: rowSpacing) {
            if showsSelectionPresentation {
                Button(action: toggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-6) // Keep the row layout unchanged around the larger hit target.
                .disabled(!isInteractionEnabled)
                .accessibilityLabel("\(isSelected ? "Deselect" : "Select") \(title)")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }

            if threadDepth > 0 {
                Spacer()
                    .frame(width: leadingIndent)
            }

            // MCP-controlled cue is folded into the existing status plate
            // (orange-tinted dot/chevron + orange running arc) so it no
            // longer pushes the title sideways. See `mcpAccentColor`,
            // `plateGlyph`, and `AgentRowActivityArc(tint:)` below.

            // Unified 14pt status plate.
            //
            // One slot carries both the row's identity glyph (chevron for
            // expandable roots, arrow for sub-agents, anchor dot or attention
            // glyph for leaf roots) AND its run-state status (plate fill +
            // optional halo + optional running arc). Folding both into a
            // single slot keeps the title's leading X stable regardless of
            // run state — previously the title shifted ~14pt sideways when a
            // row transitioned in/out of running/waiting/failed.
            statusPlate

            // Session name
            VStack(alignment: .leading, spacing: titleVStackSpacing) {
                HStack(spacing: titlePinSpacing) {
                    // The oversight role mark sits inline just before the title text; the status
                    // plate keeps carrying the dot/chevron run state ahead of it.
                    if oversightRole.hasMark {
                        oversightMark(
                            summary: sidebarOversightSummary,
                            tooltip: oversightMarkTooltip(),
                            interactive: allowsDirectMutations
                                && onAddSidebarOversight != nil
                                && onStopSidebarOversight != nil
                                && agentSessionRowOversightMarkIsInteractive(role: oversightRole)
                        )
                    }

                    Text(title)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(0)

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: pinFontSize))
                            .foregroundStyle(.secondary)
                    }

                    if let attention = worktreeMergeAttention {
                        mergeAttentionBadge(for: attention)
                    }

                    if isThreadCollapsed, hiddenThreadDescendantCount > 0 {
                        hiddenCountChip
                    }
                }

                sidebarOversightFailureLine
            }

            Spacer()

            // Trailing command progress or hover actions.
            if let commandProgressKind {
                commandProgressIndicator(for: commandProgressKind)
            } else if isHovered {
                if !showsSelectionPresentation, attentionRunState != nil, let onDismissAttention {
                    Button(action: onDismissAttention) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 11))
                            .foregroundColor(isDismissAttentionHovered ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isDismissAttentionHovered = $0 }
                    .hoverTooltip(dismissAttentionActionLabel)
                    .accessibilityLabel(dismissAttentionActionLabel)
                }

                if !showsSelectionPresentation, onCopySessionID != nil {
                    Button(action: performCopySessionID) {
                        Image(systemName: showsCopiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(copySessionIDIconColor)
                    }
                    .buttonStyle(.plain)
                    .onHover { isCopySessionIDHovered = $0 }
                    .hoverTooltip(showsCopiedFeedback ? "Session ID copied" : copySessionIDActionLabel)
                    .accessibilityLabel(copySessionIDActionLabel)
                    .accessibilityValue(showsCopiedFeedback ? "Session ID copied" : "")
                }

                if allowsDirectMutations {
                    Button(action: onTogglePin) {
                        Image(systemName: isPinned ? "pin.slash" : "pin")
                            .font(.system(size: 11))
                            .foregroundColor(isPinHovered ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isPinHovered = $0 }
                    .hoverTooltip(pinActionLabel)

                    Button(action: beginRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundColor(isRenameHovered ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isRenameHovered = $0 }
                    .hoverTooltip(renameActionLabel)

                    if let onStash {
                        Button(action: onStash) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 11))
                                .foregroundColor(isStashHovered ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .onHover { isStashHovered = $0 }
                        .hoverTooltip(stashActionLabel)
                    }

                    Button(action: requestDeleteConfirmation) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(isDeleteHovered ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isDeleteHovered = $0 }
                    .hoverTooltip(deleteActionLabel)
                }
            }
            // Selected state is already signaled by the accent-tinted background +
            // semibold title weight; a trailing checkmark was redundant.
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, rowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(isActive ? 0.28 : 0.18))
                } else if isActive {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                } else if isHovered {
                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .stroke(Color(NSColor.systemGray).opacity(0.5), lineWidth: 1)
                }
            }
        )
        .contentShape(Rectangle())
        // A SwiftUI `.contextMenu` tracks its menu inside SwiftUI's own machinery, which
        // dismantles it when this row re-renders — the disappearing-lists defect Cristian
        // reported. The AppKit-backed region presents through the window-scoped
        // `StableMenuPresenter` instead, so rebuilds cannot tear the menu down and window
        // close still can. The hit gate passes every non-context event through untouched.
        .overlay(
            StableMenuContextRegion(anchor: contextMenuAnchor) {
                sidebarContextMenuItems(currentContextMenuSnapshot())
            }
            .accessibilityHidden(true)
        )
        .accessibilityAction(.showMenu) {
            (contextMenuAnchor.view as? StableMenuContextView)?.presentAtRegionOrigin()
        }
        .onHover { hovered in
            isHovered = hovered
        }
        // Presentation is frozen in the independent native menu. Endpoint changes reset only
        // feedback; Add re-resolves eligibility and Stop remains generation-reference qualified.
        .onChange(of: sidebarOversightTargetEndpoint) { previous, current in
            guard previous != current else { return }
            resetSidebarOversightPresentation()
        }
        .onTapGesture(perform: handleRowTap)
        .focusable()
        .onKeyPress(.space) {
            toggleSelection()
            return .handled
        }
        .accessibilityLabel(title)
        .accessibilityValue(rowAccessibilityValue)
        .accessibilityAction(named: Text(isSelected ? "Deselect chat" : "Select chat"), toggleSelection)
        .popover(isPresented: $showDeleteConfirmation, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete chat?")
                    .font(.headline)
                Text("This permanently deletes this chat.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        showDeleteConfirmation = false
                    }
                    Button("Delete") {
                        guard allowsDirectMutations else { return }
                        showDeleteConfirmation = false
                        onDelete()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allowsDirectMutations)
                }
            }
            .padding()
            .frame(width: 280)
        }
        .sheet(isPresented: $showRenameAlert) {
            AgentSessionRenameSheet(
                renameText: $renameText,
                onConfirm: { newName in
                    guard allowsDirectMutations else { return }
                    showRenameAlert = false
                    onRename(newName)
                },
                onCancel: {
                    showRenameAlert = false
                }
            )
        }
        .sheet(item: $oversightSessionIDSheet) { request in
            oversightSessionIDSheetView(for: request)
        }
        .onChange(of: isInteractionEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            showDeleteConfirmation = false
            showRenameAlert = false
            oversightSessionIDSheet = nil
        }
    }

    /// True when this row should advertise that it was opened by an
    /// external MCP client. Only root rows wear this cue — sub-agent
    /// rows are always MCP-driven by their parent, so the indent + arrow
    /// glyph already convey the same meaning.
    private var isMCPControlledRoot: Bool {
        isMCPControlled && threadDepth == 0
    }

    /// Compact merge-attention marker shown after the title for sessions with
    /// an active worktree merge operation in `awaiting_approval`,
    /// `conflicted`, or `awaiting_commit` state. Sized to match the existing
    /// pin glyph so layout does not jitter when attention attaches/detaches.
    private func mergeAttentionBadge(for attention: AgentWorktreeMergeAttention) -> some View {
        let tint: Color = switch attention.kind {
        case .conflicted: .orange
        case .awaitingApproval: .purple
        case .awaitingCommit: .yellow
        }
        let glyph = switch attention.kind {
        case .conflicted: "exclamationmark.triangle.fill"
        case .awaitingApproval: "arrow.triangle.merge"
        case .awaitingCommit: "checkmark.circle"
        }
        return Image(systemName: glyph)
            .font(.system(size: pinFontSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: pinFontSize + 2, height: pinFontSize + 2)
            .accessibilityLabel(attention.tooltipText)
            .hoverTooltip(attention.tooltipText)
    }

    private var hiddenCountChip: some View {
        let hasHiddenAttention = hiddenThreadDescendantAttentionCount > 0
        return Text("\(hiddenThreadDescendantCount)")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: hasHiddenAttention ? .semibold : .medium))
            .foregroundStyle(hasHiddenAttention ? Color.orange : Color.secondary)
            .padding(.horizontal, chipHorizontalPadding)
            .padding(.vertical, chipVerticalPadding)
            .background(
                Capsule()
                    .fill(
                        hasHiddenAttention
                            ? Color.orange.opacity(0.18)
                            : Color(NSColor.systemGray).opacity(0.18)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(Color.orange.opacity(hasHiddenAttention ? 0.6 : 0), lineWidth: 1)
            )
            .hoverTooltip(hiddenCountTooltip)
            .accessibilityLabel(hiddenCountTooltip)
    }

    /// The state the status slot should visually reflect.
    ///
    /// Rules:
    /// - Running always wins (live activity outranks any stale attention).
    /// - Otherwise prefer the unseen attention state (mirrors the MCP status
    ///   "inactive/active/attention" pattern — attention is the "look at me"
    ///   signal and trumps steady-state).
    /// - Fall back to the current run state.
    private var effectiveStatusState: AgentSessionRunState {
        if runState == .running {
            return .running
        }
        if let attentionRunState {
            return attentionRunState
        }
        return runState
    }

    /// True when the current signal is a background transition the user
    /// hasn't acknowledged yet. Drives the stronger "badge" treatment.
    private var isUnseenAttention: Bool {
        guard let attentionRunState else { return false }
        // If the row is currently running we prefer to show the running arc
        // rather than a stale attention ring — attention will re-raise when
        // this run terminates.
        if runState == .running {
            return false
        }
        return AgentSessionSidebarUIStore.isAttentionEligible(attentionRunState)
    }

    /// Shared accent used to flag MCP-controlled root rows in the status
    /// plate. Orange is the same hue used elsewhere for MCP affordances
    /// (file drawer chips, in-progress streaming badge, etc).
    private static let mcpAccentColor = Color.orange

    // MARK: - Unified status plate

    ///
    /// Single 14pt leading slot that carries BOTH row identity (chevron /
    /// arrow / anchor dot / attention glyph) AND run-state status (plate
    /// fill tint + optional halo stroke + optional running arc overlay).
    ///
    /// Status vocabulary:
    ///   - idle / cancelled     → clear plate, leaf rows show a hairline dot
    ///   - running              → accent-tinted plate + rotating arc overlay,
    ///                            identity glyph remains inside
    ///   - waiting (*)          → green-tinted plate; unseen raises to a
    ///                            louder halo stroke ("needs you" cue)
    ///   - completed + unseen   → green-tinted plate + checkmark glyph
    ///   - failed               → red-tinted plate; unseen swaps the glyph
    ///                            for an exclamation mark
    ///
    /// The identity glyph (chevron / arrow / dot) is preserved except when
    /// a strong background-attention cue requires a dedicated state glyph
    /// (checkmark for unseen-completed, exclamationmark for unseen-failed).
    /// This way the plate always reserves 14pt of leading width and the
    /// title's X offset is a pure function of threadDepth.
    private var statusPlate: some View {
        ZStack {
            // Status-encoding fill tint. Stays decorative so the chevron
            // button's hit test isn't blocked.
            Circle()
                .fill(plateFillColor)
                .allowsHitTesting(false)

            // Louder halo for unseen waiting states — preserves the pre-
            // refactor "green halo ring" cue that tells the user a
            // background session is waiting on them.
            if showsWaitingHalo {
                Circle()
                    .stroke(Color.green.opacity(0.55), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }

            // Spinning arc overlay while a run is live. Sits between the
            // plate fill and the identity glyph so the chevron/arrow/dot
            // remains visually centered while the ring conveys motion.
            if runState == .running {
                AgentRowActivityArc(tint: runningAccentColor)
                    .allowsHitTesting(false)
            }

            // Foreground glyph — identity for normal states, attention
            // glyph when an unseen background transition demands it.
            plateGlyph
        }
        .frame(width: 16, height: 16)
        .overlay(alignment: .bottomTrailing) {
            worktreeMarker
        }
        .hoverTooltip(plateTooltip)
        .accessibilityLabel(plateAccessibilityLabel)
    }

    /// Compact bound-worktree marker overlaid on the status plate's
    /// bottom-right corner. Purely decorative for hit-testing so it never
    /// blocks the disclosure chevron, and layout-neutral so the title's
    /// leading X stays a pure function of `threadDepth`. Its identity is
    /// folded into `plateTooltip` / `plateAccessibilityLabel`.
    @ViewBuilder
    private var worktreeMarker: some View {
        if let worktree {
            worktreeMarkerShape(for: worktree)
                .frame(width: 7, height: 7)
                .padding(1.3)
                .background(
                    Circle().fill(Color(NSColor.controlBackgroundColor))
                )
                .offset(x: 2.5, y: 2.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Marker geometry. Available worktrees use the persisted marker style
    /// (filled dot for dot/capsule, hollow ring for ring); missing worktrees
    /// always render a muted dashed ring so a stale binding reads as such.
    @ViewBuilder
    private func worktreeMarkerShape(for worktree: AgentWorktreeIndicator) -> some View {
        if !worktree.isAvailable {
            Circle()
                .strokeBorder(
                    Color.secondary,
                    style: StrokeStyle(lineWidth: 1.3, dash: [1.6, 1.4])
                )
        } else if worktree.markerStyle == .ring {
            Circle()
                .strokeBorder(worktree.color, lineWidth: 1.7)
        } else {
            Circle()
                .fill(worktree.color)
                .overlay(
                    Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                )
        }
    }

    /// Tint used for the running arc and the running plate fill. Orange
    /// for MCP-controlled root rows so the running cue rhymes with the
    /// rest of the MCP indicators; default accent everywhere else.
    private var runningAccentColor: Color {
        isMCPControlledRoot ? Self.mcpAccentColor : Color.accentColor
    }

    /// Background tint that encodes the row's effective run state. Kept
    /// at low alpha so the plate reads as a tint, not a loud chip.
    private var plateFillColor: Color {
        switch effectiveStatusState {
        case .running:
            // No disc behind the running arc — the rotating arc reads cleanly
            // on its own and the faint accent fill clashed with the centered
            // dot. Keep the plate transparent so only the arc + glyph show.
            .clear
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            Color.green.opacity(isUnseenAttention ? 0.22 : 0.15)
        case .completed:
            isUnseenAttention ? Color.green.opacity(0.18) : .clear
        case .failed:
            Color.red.opacity(isUnseenAttention ? 0.18 : 0.12)
        case .cancelled, .idle:
            .clear
        }
    }

    /// True only for unseen-attention waiting states — the one case where
    /// we still want a crisp stroke ring, because the user needs to
    /// notice that a backgrounded session is waiting on them.
    private var showsWaitingHalo: Bool {
        guard isUnseenAttention else { return false }
        switch effectiveStatusState {
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            return true
        default:
            return false
        }
    }

    /// Foreground glyph inside the plate. Attention states (unseen
    /// completed / unseen failed) get a dedicated state glyph; everything
    /// else falls back to the row's identity glyph (chevron / arrow /
    /// anchor dot).
    @ViewBuilder
    private var plateGlyph: some View {
        let state = effectiveStatusState

        if isUnseenAttention, state == .completed {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.green)
                .accessibilityLabel("Completed in background")
        } else if isUnseenAttention, state == .failed {
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.red)
                .accessibilityLabel("Failed in background")
        } else if showsDisclosureChevron, let onToggleThreadCollapse {
            // Expandable thread identity glyph — tappable disclosure affordance.
            // Nested expandable rows reuse this status slot instead of drawing
            // a second leading sub-agent arrow; leaf children keep the arrow.
            // MCP-controlled roots tint the chevron orange when idle so the
            // row still signals "opened by an MCP client" without needing a
            // dedicated leading rail.
            let chevronColor: Color = {
                if isDisclosureHovered {
                    return .accentColor
                }
                return isMCPControlledRoot ? Self.mcpAccentColor : .secondary
            }()
            Button {
                onToggleThreadCollapse()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(chevronColor)
                    .rotationEffect(.degrees(isThreadCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.15), value: isThreadCollapsed)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isDisclosureHovered = $0 }
            .hoverTooltip(disclosureAccessibilityLabel)
            .accessibilityLabel(disclosureAccessibilityLabel)
        } else if threadDepth > 0 {
            // Leaf sub-agent identity glyph.
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.55))
                .accessibilityHidden(true)
        } else if isMCPControlledRoot {
            // MCP-controlled leaf root — keeps the existing anchor-dot
            // design but recolors it orange and bumps the size a hair so
            // it reads as a deliberate "this chat came from an MCP client"
            // marker instead of a generic idle dot.
            Circle()
                .fill(Self.mcpAccentColor.opacity((isHovered || isActive) ? 0.95 : 0.8))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        } else {
            // Leaf root anchor dot — reacts with hover/active to rhyme
            // with the row's outline highlight. While the row is running the
            // dot also adopts the running accent (blue / MCP-orange) at full
            // opacity so the spinner reads with contrast against the arc.
            let isRunningRow = runState == .running
            let dotColor: Color = isRunningRow
                ? runningAccentColor
                : Color.secondary
            let dotOpacity: Double = {
                if isRunningRow {
                    return 1.0
                }
                return (isHovered || isActive) ? 0.55 : 0.22
            }()
            Circle()
                .fill(dotColor.opacity(dotOpacity))
                .frame(width: 3, height: 3)
                .accessibilityHidden(true)
        }
    }

    /// Tooltip for the plate. Combines the run-state / MCP status portion
    /// (`statusPlateTooltip`) with the bound-worktree identity line so a
    /// single hover surfaces both. Either portion may be absent.
    private var plateTooltip: String? {
        let status = statusPlateTooltip
        guard let worktreeTooltip = worktree?.tooltipText else { return status }
        guard let status else { return worktreeTooltip }
        return status + "\n" + worktreeTooltip
    }

    /// Run-state / MCP portion of the plate tooltip, before worktree identity
    /// is folded in. Expandable roots rely on the chevron button's own
    /// tooltip, so this stays nil there to avoid two competing bubbles.
    private var statusPlateTooltip: String? {
        if showsDisclosureChevron {
            return nil
        }

        let state = effectiveStatusState
        let stateTooltip: String? = switch state {
        case .running:
            "Running"
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            waitingTooltip(for: state, unseen: isUnseenAttention)
        case .completed:
            isUnseenAttention
                ? "Completed in background — select or dismiss to clear"
                : nil
        case .failed:
            isUnseenAttention
                ? "Failed in background — select or dismiss to clear"
                : "Last run failed"
        case .cancelled, .idle:
            nil
        }

        switch (stateTooltip, isMCPControlledRoot) {
        case (let tip?, true):
            return tip + " — MCP Controlled"
        case (nil, true):
            return "MCP Controlled"
        case (let tip, false):
            return tip
        }
    }

    /// Accessibility companion to `plateTooltip`. Always returns a
    /// non-empty label for MCP-controlled roots so VoiceOver still
    /// announces the affordance after the rail was removed.
    private var plateAccessibilityLabel: String {
        if let tip = plateTooltip {
            return tip
        }
        return isMCPControlledRoot ? "MCP controlled" : ""
    }

    private func commandProgressIndicator(
        for kind: AgentSidebarBulkActionKind
    ) -> some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
            .allowsHitTesting(false)
            .accessibilityLabel(kind.rowProgressAccessibilityLabel)
    }

    private func waitingTooltip(
        for state: AgentSessionRunState,
        unseen: Bool
    ) -> String {
        let base = switch state {
        case .waitingForApproval:
            "Waiting for approval"
        case .waitingForQuestion:
            "Waiting for your answer"
        default:
            "Waiting for your input"
        }
        return unseen ? base + " — select or dismiss to clear" : base
    }
}

// MARK: - Agent Row Activity Arc

/// A compact, calm rotating arc used in place of the native `ProgressView`
/// inside the Agent Mode sidebar row's status slot.
///
/// Design goals:
/// - Match the 14pt status slot so titles stay aligned whether the row shows
///   a spinner, a waiting dot, a failed dot, or nothing at all.
/// - Rhyme with the circle-based waiting/failed dots (they all share the same
///   geometric vocabulary).
/// - Read as "actively processing" without competing with the green waiting
///   dot — running is informational, waiting is actionable, so running
///   should not out-shout it.
struct AgentRowActivityArc: View {
    var tint: Color = .accentColor

    @Environment(\.windowIsPresentationVisible) private var isWindowPresentationVisible

    var body: some View {
        // Spun by the render server (see `AgentRowActivityArcLayerView`): a SwiftUI `repeatForever`
        // rotation here re-rendered the row's whole window on the main thread every frame.
        AgentRowAnimatedActivityArc(tint: tint, isPresentationVisible: isWindowPresentationVisible)
            .frame(width: AgentRowActivityArcLayerView.diameter, height: AgentRowActivityArcLayerView.diameter)
            // An AppKit view is not an accessibility element on its own; this keeps the arc one
            // element carrying the "Running" label.
            .accessibilityElement()
            .accessibilityLabel("Running")
    }
}

// MARK: - Agent Kind Extensions

extension AgentProviderKind {
    // displayName is defined in AgentRuntimeProviderService.swift

    var iconName: String {
        switch self {
        case .codexExec: "terminal"
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible: "cpu"
        case .openCode, .antigravity: "curlybraces.square"
        case .cursor: "cursorarrow"
        case .grokBuild: "bolt.circle.fill"
        case .devin: "terminal.fill"
        }
    }
}
