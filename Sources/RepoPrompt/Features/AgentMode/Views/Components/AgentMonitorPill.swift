import AppKit
import RepoPromptDomainRuntime
import SwiftUI

/// Compact oversight pill, placed between Workflow and Interview.
///
/// It opens a management popover rather than acting as a one-shot toggle: oversight is
/// session-scoped and survives until explicit or lifecycle revocation, so the user needs a surface
/// that lists both directions and offers Unlink at either end.
struct AgentMonitorPill: View {
    @ObservedObject var statusPillsUI: AgentStatusPillsUIStore
    @State private var showPopover = false

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var props: AgentMonitorPillProps {
        statusPillsUI.snapshot.monitor
    }

    var body: some View {
        #if DEBUG
            let _ = AgentModePerfDiagnostics.increment("ui.body.statusPills.monitor")
        #endif
        let cornerRadius = AgentPillMetrics.cornerRadius()
        let height = AgentPillMetrics.height()
        let horizontalPadding = AgentPillMetrics.horizontalPadding()
        let capsule = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                // Status is carried by the glyph and the count text, never by colour alone.
                Image(systemName: props.isOverseer ? "eye.fill" : "eye")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                if let outboundCount = props.dashboardOutboundCount {
                    Text("\(outboundCount)")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        .monospacedDigit()
                        .fixedSize()
                }
                if let inboundCount = props.dashboardInboundCount {
                    // Distinct directional inbound indicator: another session is observing this one.
                    HStack(spacing: 1) {
                        Image(systemName: "arrow.down.left")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .bold))
                        Text("\(inboundCount)")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
            }
            .fixedSize(horizontal: true, vertical: false)
            .lineLimit(1)
            .foregroundStyle(props.isOverseer ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(.ultraThinMaterial)
            .clipShape(capsule)
            .overlay(
                capsule
                    .stroke(
                        props.isOverseer || props.hasInbound
                            ? Color.accentColor.opacity(0.4)
                            : Color.secondary.opacity(0.15),
                        lineWidth: props.isOverseer || props.hasInbound ? 1 : 0.5
                    )
                    .allowsHitTesting(false)
            )
            .contentShape(capsule)
        }
        .buttonStyle(.plain)
        .hoverTooltip("Oversee other Agent sessions in any window", .top)
        .accessibilityLabel("Oversee")
        .accessibilityValue(props.accessibilityValue)
        .accessibilityHint("Opens cross-window session oversight")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            AgentMonitorPopoverView(props: props)
        }
    }
}

// MARK: - Popover

struct AgentMonitorPopoverView: View {
    let props: AgentMonitorPillProps

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @State private var identifierText = ""
    @State private var preview: AgentMonitorResolvedPreview?
    /// Persistent validation text. Errors are never conveyed by transient colour alone.
    @State private var validationMessage: String?
    @State private var isWorking = false
    /// One busy gate per generation-qualified row. Navigation, acknowledgement, durable Unlink, and
    /// Auto-wake changes must not race from the same stale projection.
    ///
    /// Keyed by `rowKey` rather than by link ID, and that is the whole point: a relink reuses the
    /// link ID under a new generation, so an action that completes late must write the *retired*
    /// row's key — which nothing renders any more — instead of clearing the replacement's busy
    /// marker or stamping it with a failure that belongs to the row the user already lost.
    @State private var busyRowKeys: Set<String> = []
    /// Persistent per-row feedback for routing, acknowledgement, durable Unlink, and Auto-wake
    /// snooze outcomes. Same generation-qualified keying, for the same reason.
    ///
    /// Widened from a bare string only far enough to tell a failure apart from the one informational
    /// notice a *successful* snooze can carry; the dictionary remains the single row-local message
    /// surface, and none of it is authority.
    @State private var rowFeedbackByRowKey: [String: AgentMonitorRowFeedback] = [:]
    @State private var isRetryingSave = false
    /// Observer-level, deliberately not part of `busyRowKeys`: the passive preference covers every
    /// outbound link at once, so gating it on a row would disable an unrelated row's actions.
    @State private var isChangingAutoWake = false
    @State private var autoWakeFailureMessage: String?
    /// The most recent successful Unlink, recoverable for a bounded window. One slot per open
    /// popover: a second Unlink replaces it, and closing the popover drops it.
    @State private var undoSlot: UndoSlot?
    /// Failure text from a rejected recovery attempt. The banner stays until the retry window ends.
    @State private var undoFailureMessage: String?
    @State private var isUndoing = false
    @State private var undoExpiryTask: Task<Void, Never>?
    /// Anchored once per open popover rather than recomputed in `body`, so an unrelated repaint
    /// cannot keep restarting the minute schedule and starve the tick it exists to deliver.
    @State private var freshnessTickAnchor = Date()

    private enum Layout {
        /// Wide enough for identity plus the inline action strip; the plan's starting value for live
        /// visual QA.
        static let baseWidth: CGFloat = 500
        static let baseHeight: CGFloat = 430

        /// A lane is one compact two-line block: identity and primary actions above, then task
        /// metadata and its subordinate Auto-wake control sharing the secondary line. Complete lane
        /// blocks use the widest gap so the grouping is legible before the separator is noticed.
        static let laneLineSpacing: CGFloat = 2
        static let laneBlockSpacing: CGFloat = 8
    }

    private var popoverWidth: CGFloat {
        fontPreset.scaledClamped(Layout.baseWidth, max: 660)
    }

    private var popoverHeight: CGFloat {
        fontPreset.scaledClamped(Layout.baseHeight, max: 580)
    }

    private var existingOutboundTargetIDs: Set<UUID> {
        Set(props.outbound.map(\.targetSessionID))
    }

    private var sortedOutbound: [AgentMonitorPillProps.Outbound] {
        AgentMonitorDashboardSortPolicy.sorted(props.outbound)
    }

    /// Generation-qualified identity of every visible row, watched so retired rows can drop their
    /// local presentation state.
    private var visibleRowKeys: [String] {
        props.outbound.map(\.rowKey) + props.inbound.map(\.rowKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !props.outbound.isEmpty {
                        outboundSection
                        Divider()
                    }
                    addSection
                    // Unconditional and available with zero links: the setting is saved with this
                    // observer session rather than with any individual oversight relationship.
                    Divider()
                    observerControlsSection
                    if hasPersistenceContent {
                        Divider()
                        persistenceSection
                    }
                    if !props.inbound.isEmpty {
                        Divider()
                        inboundSection
                    }
                    if !props.recentNotices.isEmpty {
                        Divider()
                        noticesSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Pinned below the scroll area: the row it belongs to is already gone, so the recovery
            // must not depend on where the user happens to be scrolled.
            if let undoSlot {
                Divider()
                undoBanner(undoSlot)
            }
        }
        .frame(width: popoverWidth, height: popoverHeight)
        .accessibilityElement(children: .contain)
        // A relink reuses the link ID under a new generation, so row-local busy and feedback state
        // has to expire with the exact row it was created for rather than following the identifier.
        .onChange(of: visibleRowKeys) { _, _ in
            pruneRetiredRowState()
        }
        .onDisappear {
            // Presentation only. The revocation itself already committed and stays committed.
            undoExpiryTask?.cancel()
            undoExpiryTask = nil
        }
    }

    // MARK: Add

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Oversee a session")

            TextField("Session ID", text: $identifierText)
                .textFieldStyle(.roundedBorder)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .accessibilityLabel("Session ID to oversee")
                .onChange(of: identifierText) { _, _ in refreshPreview() }
                .onSubmit { submit() }

            HStack(spacing: 6) {
                Button("Paste from Clipboard") { pasteFromClipboard() }
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .accessibilityHint("Pastes a copied session ID")

                Spacer(minLength: 0)

                Button("Oversee session") { submit() }
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .disabled(!props.canAdd || preview == nil || isWorking)
            }

            if let reason = props.canAddReason {
                messageText(reason)
            } else if let validationMessage {
                messageText(validationMessage)
            }

            if let preview {
                previewRow(preview)
            }
        }
    }

    private func previewRow(_ preview: AgentMonitorResolvedPreview) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AgentMonitorStatusIndicator(status: preview.status, fontPreset: fontPreset)
                Text(preview.displayName)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .lineLimit(1)
                Text(preview.shortID)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Text(preview.detailLine)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .hoverTooltip(preview.fullID, .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preview.accessibilityLabel)
    }

    // MARK: Lists

    private var outboundSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Overseeing")
            // One popover-scoped minute tick drives every row's relative timestamp from the same
            // instant. It exists only while the popover is open and performs no authority work.
            TimelineView(.periodic(from: freshnessTickAnchor, by: 60)) { timeline in
                outboundList(now: timeline.date)
            }
        }
    }

    /// The lane blocks, with a rule wherever one complete block ends and the next begins.
    ///
    /// The rule is a sibling of the blocks rather than a trailing decoration carried by each one, so
    /// the stack's own spacing falls on both sides of it and every block is bounded the same way
    /// above and below.
    private func outboundList(now: Date) -> some View {
        let rows = sortedOutbound
        return VStack(alignment: .leading, spacing: Layout.laneBlockSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                outboundRow(row, now: now)
                if AgentMonitorLaneGrouping.drawsSeparator(afterLaneAt: index, of: rows.count) {
                    laneBlockSeparator
                }
            }
        }
    }

    /// Deliberately lighter than the `Divider()` this popover draws between sections: Overseeing is
    /// one section, and a full-weight rule inside it would read as several.
    private var laneBlockSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.5))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private func outboundRow(_ row: AgentMonitorPillProps.Outbound, now: Date) -> some View {
        let isBusy = busyRowKeys.contains(row.rowKey)
        return VStack(alignment: .leading, spacing: Layout.laneLineSpacing) {
            HStack(spacing: 6) {
                AgentMonitorStatusIndicator(status: row.status, fontPreset: fontPreset)
                    .hoverTooltip(row.status.tooltip, .top)
                Button {
                    viewAgent(row)
                } label: {
                    Text(row.locationDisplayLabel)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
                .disabled(isBusy || row.targetRoute == nil)
                .hoverTooltip(
                    row.targetRoute == nil
                        ? AgentMonitorRowActionCopy.viewDisabledTooltip
                        : AgentMonitorRowActionCopy.viewTooltip,
                    .top
                )
                .accessibilityLabel(row.viewActionLabel)
                if row.hasUnreadActivity {
                    unreadBadge(row, isBusy: isBusy)
                }
                Spacer(minLength: 6)
                if !props.autoWakeOnUpdatesEnabled {
                    laneAutoWakeToggle(row, isBusy: isBusy)
                }
                unlinkActionButton(row, isBusy: isBusy)
            }
            // Task metadata and Auto-wake are one secondary line: this keeps the control visibly
            // attached to its lane and balances it beneath the primary actions.
            HStack(spacing: 6) {
                Text(row.taskMetadataLine(now: now))
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .hoverTooltip("\(row.identityTooltip)\n\(row.activityTooltip)", .top)
                Spacer(minLength: 6)
                snoozeRow(row, now: now, isBusy: isBusy)
                    .layoutPriority(1)
            }
            if let feedback = rowFeedbackByRowKey[row.rowKey] {
                messageText(feedback.message)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(row.accessibilityDescription)
    }

    /// The subordinate Auto-wake controls: current snooze state with its Clear, plus the compact
    /// snooze/extend menu rendered on the lane's secondary line.
    ///
    /// Rendered only when there is something to say — an active snooze, or a lane that could be
    /// snoozed — so an unselected, unsnoozed row keeps the two-line shape it has today.
    @ViewBuilder
    private func snoozeRow(
        _ row: AgentMonitorPillProps.Outbound,
        now: Date,
        isBusy: Bool
    ) -> some View {
        let durations = row.availableSnoozeDurationSeconds(now: now)
        let offersMenu = row.isAutoWakeEffectivelySelected && !durations.isEmpty
        if row.autoWakeSnooze != nil || offersMenu {
            HStack(spacing: 6) {
                if let snooze = row.autoWakeSnooze {
                    Text(AgentMonitorAutoWakeSnoozeCopy.subrow(snooze, now: now))
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel("Status Auto-wake snooze")
                        // Spoken from the same instant the text is drawn from, and deliberately not a
                        // live region: a minute tick is not news, and announcing every countdown step
                        // would make the row unusable with VoiceOver.
                        .accessibilityValue(
                            AgentMonitorAutoWakeSnoozeCopy.accessibilityValue(snooze, now: now)
                        )
                        .accessibilityHint(AgentMonitorAutoWakeSnoozeCopy.accessibilityHint)
                    Button(AgentMonitorAutoWakeSnoozeCopy.clearLabel) {
                        mutateAutoWakeSnooze(row, command: .clear)
                    }
                    .buttonStyle(.plain)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(Color.accentColor)
                    .disabled(isBusy)
                    .accessibilityLabel(row.clearSnoozeActionLabel)
                }
                if offersMenu {
                    snoozeMenu(row, now: now, durations: durations, isBusy: isBusy)
                }
            }
        }
    }

    /// One compact menu for both the first snooze and every extension.
    ///
    /// While a snooze is active it offers only horizons that would actually move the deadline. That
    /// filtering is presentation: the authority is always the server-side
    /// `max(current deadline, now + duration)`, which never shortens an active snooze.
    private func snoozeMenu(
        _ row: AgentMonitorPillProps.Outbound,
        now: Date,
        durations: [Int],
        isBusy: Bool
    ) -> some View {
        Menu {
            ForEach(durations, id: \.self) { seconds in
                Button(row.snoozeOptionLabel(seconds: seconds, now: now)) {
                    mutateAutoWakeSnooze(row, command: .set(durationSeconds: seconds))
                }
                .accessibilityLabel(row.snoozeActionLabel(seconds: seconds, now: now))
            }
        } label: {
            Label(AgentMonitorAutoWakeSnoozeCopy.menuLabel, systemImage: "moon.zzz")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.mini)
        .fixedSize()
        .disabled(isBusy)
        .hoverTooltip(AgentMonitorAutoWakeSnoozeCopy.menuTooltip, .top)
        .accessibilityLabel(row.snoozeMenuAccessibilityLabel)
        .accessibilityHint(AgentMonitorAutoWakeSnoozeCopy.accessibilityHint)
    }

    /// Unlink remains independent from the location-only View affordance and the New control.
    /// All three share `busyRowKeys`, so they cannot act concurrently against one stale row.
    private func unlinkActionButton(_ row: AgentMonitorPillProps.Outbound, isBusy: Bool) -> some View {
        inlineActionButton(
            title: "Unlink",
            systemImage: "link.badge.minus",
            accessibilityLabel: row.unlinkActionLabel,
            tooltip: AgentMonitorRowActionCopy.unlinkTooltip,
            isDisabled: isBusy
        ) {
            unlinkOutbound(row)
        }
        .fixedSize()
    }

    /// Explicit acknowledgement of new activity.
    ///
    /// Deliberately the only way unread clears: opening, hovering, or scrolling this dashboard proves
    /// nothing was reviewed, and View Agent proves only that the target opened.
    private func unreadBadge(_ row: AgentMonitorPillProps.Outbound, isBusy: Bool) -> some View {
        Button {
            markSeen(row)
        } label: {
            Text(AgentMonitorRowActionCopy.unreadBadge)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.18))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .hoverTooltip(AgentMonitorRowActionCopy.unreadTooltip, .top)
        .accessibilityLabel(row.markSeenActionLabel)
    }

    private func inlineActionButton(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        tooltip: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .labelStyle(.titleAndIcon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isDisabled)
        .hoverTooltip(tooltip, .top)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The observer-level passive status-update switch.
    ///
    /// Observer-session controls, rendered whether or not anything is overseen.
    private var observerControlsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                autoWakeToggle
                if !props.autoWakeOnUpdatesEnabled, !props.outbound.isEmpty {
                    Button(
                        currentOutboundTargetsAreAllSelected
                            ? AgentMonitorAutoWakeCopy.deselectAll
                            : AgentMonitorAutoWakeCopy.selectAll
                    ) {
                        setAllCurrentAutoWakeTargets(selected: !currentOutboundTargetsAreAllSelected)
                    }
                    .buttonStyle(.plain)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(Color.accentColor)
                    .disabled(isChangingAutoWake || props.autoWakeUnavailableReason != nil)
                }
            }
            if let reason = props.autoWakeUnavailableReason {
                messageText(reason)
            } else if props.outbound.isEmpty {
                messageText(AgentMonitorAutoWakeCopy.noLinksNote)
            }
            if let autoWakeFailureMessage {
                messageText(autoWakeFailureMessage)
            }
        }
    }

    /// The binding reads `props`, never local state: the setting lives on the session and is
    /// republished after it settles. A checkbox that flipped optimistically would show the user a
    /// value the session had refused to take.
    private var currentOutboundTargetsAreAllSelected: Bool {
        props.outbound.allSatisfy { props.autoWakeTargetSessionIDs.contains($0.targetSessionID) }
    }

    private func laneAutoWakeToggle(
        _ row: AgentMonitorPillProps.Outbound,
        isBusy: Bool
    ) -> some View {
        Toggle(AgentMonitorAutoWakeCopy.laneLabel, isOn: Binding(
            get: { props.autoWakeTargetSessionIDs.contains(row.targetSessionID) },
            set: { setLaneAutoWake(row, enabled: $0) }
        ))
        .toggleStyle(.checkbox)
        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
        .fixedSize()
        .disabled(isBusy || isChangingAutoWake || props.autoWakeUnavailableReason != nil)
        .accessibilityLabel("Auto-wake for \(row.displayName)")
    }

    private var autoWakeToggle: some View {
        Toggle(AgentMonitorAutoWakeCopy.label, isOn: Binding(
            get: { props.autoWakeOnUpdatesEnabled },
            set: { setAutoWakeOnUpdates($0) }
        ))
        .toggleStyle(.checkbox)
        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
        // Disabled only while a write is in flight, or while the exact session cannot take one at
        // all. A merely ineligible or unlinked observer keeps an editable, saved setting.
        .disabled(isChangingAutoWake || props.autoWakeUnavailableReason != nil)
        .fixedSize()
        .hoverTooltip(AgentMonitorAutoWakeCopy.tooltip, .top)
        .accessibilityLabel(AgentMonitorAutoWakeCopy.accessibilityLabel)
        .accessibilityValue(props.autoWakeOnUpdatesEnabled ? "On" : "Off")
        .accessibilityHint(
            props.autoWakeUnavailableReason ?? AgentMonitorAutoWakeCopy.accessibilityHint
        )
    }

    private var inboundSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Overseen by")
            ForEach(props.inbound) { row in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.left")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Button {
                            viewObserver(row)
                        } label: {
                            Text(row.rowLabel)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                        .disabled(busyRowKeys.contains(row.rowKey))
                        .hoverTooltip(AgentMonitorRowActionCopy.viewTooltip, .top)
                        .accessibilityLabel(row.viewActionLabel)

                        Text(row.detailLine)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // Either endpoint may revoke; both windows update from one authority transition.
                    // On an inbound row this projection's session is the *target*, so the pair is
                    // built the other way around.
                    unlinkButton(
                        label: row.unlinkActionLabel,
                        rowKey: row.rowKey,
                        // Inbound recovery re-establishes the direct grant on behalf of the other
                        // session through the same user-level authority that just removed it. It
                        // grants nothing beyond the relationship the user themselves ended.
                        undo: props.sessionID.map { targetSessionID in
                            UndoSlot(
                                direction: .inbound,
                                observerSessionID: row.observerSessionID,
                                targetSessionID: targetSessionID,
                                displayName: row.displayName,
                                // Captured before Stop runs, and read from the observer above this
                                // row rather than from `props`: these are the overseen session's
                                // own selections, which never include its observer's.
                                restoreAutoWakeSelection: AgentSessionLinkRuntimeBridge.shared
                                    .autoWakeTargetSelection(observerSessionID: row.observerSessionID)
                                    .contains(targetSessionID)
                            )
                        }
                    ) {
                        guard let targetEndpoint = props.endpoint else { return .alreadyStopped }
                        return await AgentSessionLinkRuntimeBridge.shared.stopMonitorLink(
                            observerEndpoint: row.observerEndpoint,
                            targetEndpoint: targetEndpoint,
                            expectedReference: DomainAgentSessionLinkReference(
                                linkID: row.linkID,
                                generation: row.generation
                            )
                        )
                    }
                }
                .hoverTooltip(row.fullID, .top)
                .accessibilityElement(children: .contain)
                .accessibilityValue(row.accessibilityDescription)
                if let feedback = rowFeedbackByRowKey[row.rowKey] {
                    messageText(feedback.message)
                }
            }
        }
    }

    private var noticesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                sectionHeader("Recent endings")
                Spacer(minLength: 0)
                // Addressed by exact incarnation: notices belong to the endpoint they were recorded
                // for, so a duplicate live incarnation of this UUID must not dismiss another's.
                dismissButton(label: "Dismiss recent oversight endings")
            }
            ForEach(props.recentNotices) { notice in
                Text(notice.message)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func messageText(_ message: String) -> some View {
        Text(message)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isStaticText)
    }

    private func unlinkButton(
        label: String,
        rowKey: String,
        undo: UndoSlot?,
        action: @escaping () async -> AgentMonitorStopOutcome
    ) -> some View {
        Button("Unlink") {
            performUnlink(rowKey: rowKey, undo: undo, action: action)
        }
        .buttonStyle(.plain)
        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .disabled(busyRowKeys.contains(rowKey))
        .accessibilityLabel(label)
    }

    // MARK: Persistence

    private var hasPersistenceContent: Bool {
        props.persistence.noticeMessage != nil
            || !props.persistence.warnings.isEmpty
            || props.persistence.hasPendingCleanupRetry
    }

    /// Aggregate durable-oversight state. Deliberately names no session and shows no identifier:
    /// this text is broadcast to every window, and the only actionable content is what the user can
    /// do about it.
    private var persistenceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                sectionHeader("Saved oversight")
                Spacer(minLength: 0)
                if !props.persistence.warnings.isEmpty {
                    dismissButton(label: "Dismiss saved oversight warnings")
                }
            }
            if let notice = props.persistence.noticeMessage {
                messageText(notice)
            }
            ForEach(props.persistence.warnings) { warning in
                messageText(warning.message)
            }
            if props.persistence.hasPendingCleanupRetry {
                Button("Retry saving") {
                    guard !isRetryingSave else { return }
                    isRetryingSave = true
                    Task {
                        await AgentSessionLinkRuntimeBridge.shared.retryPendingIntentCleanup()
                        isRetryingSave = false
                    }
                }
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .disabled(isRetryingSave)
                .accessibilityHint("Retries updating saved oversight links")
            }
        }
    }

    /// Clears this endpoint's authority notices **and** the app warnings currently on screen.
    ///
    /// It deliberately does not discard pending cleanup: the disk work is still owed, and **Retry
    /// saving** is how the user asks for it. Clearing the message must not clear the obligation.
    private func dismissButton(label: String) -> some View {
        let endpoint = props.endpoint
        let warningIDs = Set(props.persistence.warnings.map(\.id))
        return Button("Dismiss") {
            AgentSessionLinkRuntimeBridge.shared.dismissPersistenceWarnings(ids: warningIDs)
            guard let endpoint else { return }
            // Addressed by exact incarnation: notices belong to the endpoint they were recorded for,
            // so a duplicate live incarnation of this UUID must not dismiss another's.
            Task { await AgentSessionLinkRuntimeBridge.shared.dismissNotices(forEndpoint: endpoint) }
        }
        .buttonStyle(.plain)
        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }

    // MARK: Unlink recovery

    /// UI-only capture of the relationship a successful Unlink just removed.
    ///
    /// It deliberately carries the canonical session pair and nothing else. The old link ID and
    /// generation are inputs to Stop only: recovery runs the ordinary Add transaction and mints a
    /// *fresh* link, so naming the retired reference here would imply a resurrection that never
    /// happens.
    private struct UndoSlot: Identifiable, Equatable {
        let id = UUID()
        let direction: AgentMonitorUnlinkUndo.Direction
        let observerSessionID: UUID
        let targetSessionID: UUID
        let displayName: String
        let restoreAutoWakeSelection: Bool

        var message: String {
            AgentMonitorUnlinkUndo.message(direction: direction, displayName: displayName)
        }

        var undoAccessibilityLabel: String {
            AgentMonitorUnlinkUndo.undoAccessibilityLabel(direction: direction, displayName: displayName)
        }
    }

    private func undoBanner(_ slot: UndoSlot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.message)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .fixedSize(horizontal: false, vertical: true)
                if let undoFailureMessage {
                    messageText(undoFailureMessage)
                }
            }
            Spacer(minLength: 0)
            if isUndoing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Re-linking")
            }
            Button("Undo") {
                performUndo(slot)
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
            .disabled(isUndoing)
            .hoverTooltip(AgentMonitorUnlinkUndo.undoTooltip, .top)
            .accessibilityLabel(slot.undoAccessibilityLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
    }

    /// Offers one bounded recovery window, replacing any earlier one.
    ///
    /// The clock starts when Stop *completed*, not when the user clicked: a slow durable removal
    /// must not silently consume the window it earned.
    private func presentUndo(_ slot: UndoSlot) {
        undoExpiryTask?.cancel()
        undoFailureMessage = nil
        isUndoing = false
        undoSlot = slot
        startUndoExpiry(for: slot.id)
    }

    private func startUndoExpiry(for slotID: UUID) {
        undoExpiryTask?.cancel()
        undoExpiryTask = Task {
            // Monotonic by construction: a wall-clock change cannot shorten or extend the window.
            try? await Task.sleep(for: AgentMonitorUnlinkUndo.window)
            guard !Task.isCancelled, undoSlot?.id == slotID else { return }
            undoSlot = nil
            undoFailureMessage = nil
            undoExpiryTask = nil
        }
    }

    /// Recovers by creating a new link through the ordinary Add entry point.
    ///
    /// Nothing about the retired grant is restored: it has a new reference and generation, and
    /// unread, cursors, delivery, and Auto-wake lane state all start fresh. `.alreadyLinked` counts
    /// as recovered because the user's goal — the relationship exists again — is satisfied.
    private func performUndo(_ slot: UndoSlot) {
        guard !isUndoing else { return }
        isUndoing = true
        undoFailureMessage = nil
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        Task {
            let outcome = await AgentSessionLinkRuntimeBridge.shared.addMonitorLink(
                observerSessionID: slot.observerSessionID,
                rawTargetSessionID: slot.targetSessionID.uuidString
            )
            isUndoing = false
            guard undoSlot?.id == slot.id else { return }
            switch outcome {
            case .added, .alreadyLinked:
                if slot.restoreAutoWakeSelection {
                    _ = await AgentSessionLinkRuntimeBridge.shared.restoreAutoWakeTargetSelection(
                        targetSessionID: slot.targetSessionID,
                        observerSessionID: slot.observerSessionID
                    )
                }
                undoSlot = nil
                undoFailureMessage = nil
            case .failed, .rejected:
                // The endpoint may have closed or become ineligible in the meantime. Report it
                // honestly and give the user one more bounded window to retry.
                undoFailureMessage = outcome.failureMessage
                startUndoExpiry(for: slot.id)
            }
        }
    }

    // MARK: Actions

    private func pasteFromClipboard() {
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        identifierText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolution is pure and read-only: it scans live windows without focusing, activating, or
    /// switching the target. Knowing or pasting a UUID still grants nothing.
    private func refreshPreview() {
        let trimmed = identifierText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            preview = nil
            validationMessage = nil
            return
        }
        switch AgentSessionLinkRuntimeBridge.shared.resolvePreview(
            observerSessionID: props.sessionID,
            rawTargetSessionID: trimmed,
            existingOutboundTargetIDs: existingOutboundTargetIDs
        ) {
        case let .success(resolved):
            preview = resolved
            validationMessage = nil
        case let .failure(failure):
            preview = nil
            validationMessage = failure.uiMessage
        }
    }

    /// Marks one exact row busy and clears whatever it was last saying.
    ///
    /// Callers capture the returned key and use it for the completion, so an action that outlives its
    /// row settles against the identity it started on and never the replacement's.
    @discardableResult
    private func beginRowAction(_ rowKey: String) -> String {
        busyRowKeys.insert(rowKey)
        setRowFeedback(rowKey, nil)
        return rowKey
    }

    /// Replaces one row's persistent feedback, announcing it exactly once when it is new.
    ///
    /// The announcement lives here rather than in `body` on purpose: a timeline tick, a scroll, or
    /// any other recomputation must not repeat it, and replacing or clearing the value is what resets
    /// the announcement identity.
    private func setRowFeedback(_ rowKey: String, _ feedback: AgentMonitorRowFeedback?) {
        guard rowFeedbackByRowKey[rowKey] != feedback else { return }
        guard let feedback else {
            rowFeedbackByRowKey.removeValue(forKey: rowKey)
            return
        }
        rowFeedbackByRowKey[rowKey] = feedback
        announce(feedback)
    }

    /// Speaks one row-local outcome once.
    ///
    /// A failure interrupts, because the action the user just took did not happen. An informational
    /// notice does not: “the current wake already started” reports a *successful* snooze and has no
    /// business preempting whatever VoiceOver is saying.
    private func announce(_ feedback: AgentMonitorRowFeedback) {
        let element: Any = if let window = NSApplication.shared.keyWindow {
            window
        } else {
            NSApplication.shared
        }
        let priority: NSAccessibilityPriorityLevel = feedback.isFailure ? .high : .medium
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: feedback.message,
                .priority: priority.rawValue
            ]
        )
    }

    /// Drops busy markers and feedback for rows whose exact generation is gone.
    ///
    /// This is also what collects the state a late completion wrote against a retired key, so the
    /// two dictionaries stay bounded by what is actually on screen.
    private func pruneRetiredRowState() {
        let live = Set(visibleRowKeys)
        busyRowKeys.formIntersection(live)
        rowFeedbackByRowKey = rowFeedbackByRowKey.filter { live.contains($0.key) }
    }

    private func viewAgent(_ row: AgentMonitorPillProps.Outbound) {
        routeToAgent(rowKey: row.rowKey, route: row.targetRoute)
    }

    private func viewObserver(_ row: AgentMonitorPillProps.Inbound) {
        routeToAgent(rowKey: row.rowKey, route: row.observerRoute)
    }

    /// Routes one exact generation-qualified row and keeps navigation mutually exclusive with every
    /// other action on that row. Outbound and inbound navigation therefore share identical failure
    /// feedback without making either complete row a hit target.
    private func routeToAgent(rowKey: String, route: AgentSessionDeepLinkRoute?) {
        guard !busyRowKeys.contains(rowKey) else { return }
        guard let route else {
            setRowFeedback(rowKey, .failure(AgentMonitorRowActionCopy.viewFailureMessage))
            return
        }
        let rowKey = beginRowAction(rowKey)
        Task {
            let result = await AppDeepLinkRouter.shared.route(agentSession: route)
            busyRowKeys.remove(rowKey)
            switch result {
            case .routed:
                setRowFeedback(rowKey, nil)
            case let .workspaceSwitchBlocked(message):
                let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason: String = if let trimmed, !trimmed.isEmpty {
                    trimmed
                } else {
                    "RepoPrompt couldn\u{2019}t switch to that Agent session\u{2019}s workspace."
                }
                setRowFeedback(rowKey, .failure(reason))
            case .blockedByActiveDifferentSession:
                setRowFeedback(rowKey, .failure(
                    "That tab is actively running another Agent session. Try again after it finishes."
                ))
            case .workspaceUnavailable, .tabUnavailable, .sessionUnavailable, .sessionMismatch:
                setRowFeedback(rowKey, .failure("That Agent session is no longer available."))
            }
        }
    }

    /// Requests one exact lane's Auto-wake snooze change and renders whatever the runtime settles on.
    ///
    /// Addressed with the row's own generation-qualified reference, so a stale row cannot authorize a
    /// mutation against the lane that replaced it. Nothing is applied optimistically: the authoritative
    /// repaint supplies the new state, and the only thing this records locally is the outcome the row
    /// has to explain.
    private func mutateAutoWakeSnooze(
        _ row: AgentMonitorPillProps.Outbound,
        command: AgentSessionLinkAutoWakeSnoozeCommand
    ) {
        guard !busyRowKeys.contains(row.rowKey) else { return }
        guard let observerEndpoint = props.endpoint else {
            setRowFeedback(
                row.rowKey,
                .failure(AgentMonitorAutoWakeSnoozeCopy.unavailableMessage)
            )
            return
        }
        let rowKey = beginRowAction(row.rowKey)
        let reference = DomainAgentSessionLinkReference(
            linkID: row.linkID,
            generation: row.generation
        )
        Task {
            let result = await AgentSessionLinkRuntimeBridge.shared.mutateAutoWakeSnooze(
                observerEndpoint: observerEndpoint,
                targetSessionID: row.targetSessionID,
                expectedReference: reference,
                command: command,
                origin: .user
            )
            busyRowKeys.remove(rowKey)
            switch result {
            case let .success(outcome):
                // Reported only for a set or extension. A clear that arrives too late removed the
                // snooze it was asked to remove, so telling the user the current call could not be
                // retracted would describe a failure that did not happen.
                let appliesToLaterUpdatesOnly = outcome.currentDispatchAlreadyStarted
                    && command != .clear
                setRowFeedback(
                    rowKey,
                    appliesToLaterUpdatesOnly
                        ? .notice(AgentMonitorAutoWakeSnoozeCopy.currentDispatchAlreadyStarted)
                        : nil
                )
            case let .failure(failure):
                setRowFeedback(
                    rowKey,
                    .failure(AgentMonitorAutoWakeSnoozeCopy.failureMessage(failure))
                )
            }
        }
    }

    /// Acknowledges new activity without touching status or authority.
    private func markSeen(_ row: AgentMonitorPillProps.Outbound) {
        guard !busyRowKeys.contains(row.rowKey) else { return }
        guard let observerEndpoint = props.endpoint else {
            setRowFeedback(row.rowKey, .failure("That oversight link is no longer active."))
            return
        }
        let rowKey = beginRowAction(row.rowKey)
        let reference = DomainAgentSessionLinkReference(
            linkID: row.linkID,
            generation: row.generation
        )
        Task {
            let outcome = await AgentSessionLinkRuntimeBridge.shared.markMonitorActivitySeen(
                observerEndpoint: observerEndpoint,
                targetSessionID: row.targetSessionID,
                expectedReference: reference
            )
            busyRowKeys.remove(rowKey)
            setRowFeedback(rowKey, outcome.failureMessage.map(AgentMonitorRowFeedback.failure))
        }
    }

    /// Requests an auto-wake change and renders whatever the session settles on.
    ///
    /// Addressed to the exact incarnation this projection was published to: a duplicate live
    /// incarnation of the same session UUID must not have its setting changed from another window's
    /// dashboard. Nothing here touches link authority, and turning it *on* starts nothing by itself —
    /// it only permits the coordinator to reserve one follow-up when actionable content is pending.
    private func setAutoWakeOnUpdates(_ enabled: Bool) {
        guard !isChangingAutoWake else { return }
        guard let observerEndpoint = props.endpoint else {
            autoWakeFailureMessage = AgentMonitorAutoWakeCopy.unavailableMessage
            return
        }
        isChangingAutoWake = true
        autoWakeFailureMessage = nil
        Task {
            let outcome = await AgentSessionLinkRuntimeBridge.shared.setAutoWakeOnOversightUpdates(
                enabled,
                observerEndpoint: observerEndpoint
            )
            isChangingAutoWake = false
            autoWakeFailureMessage = outcome.failureMessage
        }
    }

    private func setLaneAutoWake(_ row: AgentMonitorPillProps.Outbound, enabled: Bool) {
        var selected = props.autoWakeTargetSessionIDs
        if enabled {
            selected.insert(row.targetSessionID)
        } else {
            selected.remove(row.targetSessionID)
        }
        setAutoWakeTargets(selected)
    }

    private func setAllCurrentAutoWakeTargets(selected: Bool) {
        var targetIDs = props.autoWakeTargetSessionIDs
        let current = Set(props.outbound.map(\.targetSessionID))
        if selected {
            targetIDs.formUnion(current)
        } else {
            targetIDs.subtract(current)
        }
        setAutoWakeTargets(targetIDs)
    }

    private func setAutoWakeTargets(_ targetSessionIDs: Set<UUID>) {
        guard !isChangingAutoWake else { return }
        guard let observerEndpoint = props.endpoint else {
            autoWakeFailureMessage = AgentMonitorAutoWakeCopy.unavailableMessage
            return
        }
        isChangingAutoWake = true
        autoWakeFailureMessage = nil
        Task {
            let outcome = await AgentSessionLinkRuntimeBridge.shared.setAutoWakeTargetSelection(
                targetSessionIDs: targetSessionIDs,
                observerEndpoint: observerEndpoint
            )
            isChangingAutoWake = false
            autoWakeFailureMessage = outcome.failureMessage
        }
    }

    private func unlinkOutbound(_ row: AgentMonitorPillProps.Outbound) {
        performUnlink(
            rowKey: row.rowKey,
            undo: props.sessionID.map { observerSessionID in
                UndoSlot(
                    direction: .outbound,
                    observerSessionID: observerSessionID,
                    targetSessionID: row.targetSessionID,
                    displayName: row.displayName,
                    restoreAutoWakeSelection: props.autoWakeTargetSessionIDs.contains(row.targetSessionID)
                )
            }
        ) {
            guard let observerEndpoint = props.endpoint else { return .alreadyStopped }
            return await AgentSessionLinkRuntimeBridge.shared.stopMonitorLink(
                observerEndpoint: observerEndpoint,
                targetEndpoint: row.targetEndpoint,
                expectedReference: DomainAgentSessionLinkReference(
                    linkID: row.linkID,
                    generation: row.generation
                )
            )
        }
    }

    /// Revokes immediately, then offers recovery only for the outcome that proves this action
    /// performed the removal.
    ///
    /// `.failed` keeps the relationship, so there is nothing to undo; `.alreadyStopped` means some
    /// other path removed it, and offering to recreate a link this click did not end would be a
    /// different decision than the one the user made.
    private func performUnlink(
        rowKey: String,
        undo: UndoSlot?,
        action: @escaping () async -> AgentMonitorStopOutcome
    ) {
        guard !busyRowKeys.contains(rowKey) else { return }
        beginRowAction(rowKey)
        Task {
            let outcome = await action()
            busyRowKeys.remove(rowKey)
            // A failed durable removal is still live and still saved, so it must remain visible.
            setRowFeedback(rowKey, outcome.failureMessage.map(AgentMonitorRowFeedback.failure))
            if outcome == .stopped, let undo {
                presentUndo(undo)
            }
        }
    }

    private func submit() {
        guard props.canAdd, preview != nil, !isWorking, let observerSessionID = props.sessionID else { return }
        let raw = identifierText.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        Task {
            let outcome = await AgentSessionLinkRuntimeBridge.shared.addMonitorLink(
                observerSessionID: observerSessionID,
                rawTargetSessionID: raw
            )
            isWorking = false
            if let message = outcome.failureMessage {
                validationMessage = message
                preview = nil
            } else {
                identifierText = ""
                preview = nil
                validationMessage = nil
            }
        }
    }
}

// MARK: - Lane grouping

/// Where the Overseeing list is allowed to draw a rule.
///
/// The rule carries one claim: a complete lane block ended and the next begins. A lane block is the
/// identity line plus the shared metadata and Auto-wake line, so a rule may never fall inside one —
/// a rule above a lane's own snooze control would present that control as an entry with no lane. It
/// also never follows the last lane, because the popover already draws a `Divider()` where
/// the section ends and a second rule immediately above it reads as an empty lane.
enum AgentMonitorLaneGrouping {
    static func drawsSeparator(afterLaneAt index: Int, of count: Int) -> Bool {
        index >= 0 && index < count - 1
    }
}

// MARK: - Status indicator

/// The status mark shared by the resolved preview and every outbound row.
///
/// It is a *status* vocabulary, not a transport control: the former `play.circle`/`pause.circle`
/// pair read as buttons the user could press, and Idle is not “paused”. Shape distinguishes all four
/// states without colour, the adjacent status word remains the primary semantic label, and the mark
/// itself is decorative for VoiceOver so the state is spoken once through the row value.
///
/// Composition is the descriptor's (`marks(reduceMotion:)`); only geometry and colour are the view's.
/// Reduce Motion therefore drops one element — the pulse — and cannot flatten Running into the same
/// bare dot as Waiting.
private struct AgentMonitorStatusIndicator: View {
    let status: AgentMonitorLinkStatus
    let fontPreset: FontScalePreset

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var descriptor: AgentMonitorStatusIndicatorDescriptor {
        status.indicator
    }

    /// Stable layout box, so rows never shift as a target changes state.
    private var frameSize: CGFloat {
        fontPreset.scaledClamped(14, max: 20)
    }

    private var tint: Color {
        switch descriptor.tone {
        case .live: .green
        case .neutral: .secondary
        case .attention: .orange
        case .dimmed: Color.secondary.opacity(0.55)
        }
    }

    /// The static ring Running always wears. Sized so the pulse can start from it rather than cross
    /// it, and so the whole animation stays inside the layout box.
    private var haloDiameter: CGFloat {
        frameSize * 0.78
    }

    var body: some View {
        ZStack {
            ForEach(descriptor.marks(reduceMotion: reduceMotion), id: \.self) { mark in
                markBody(mark)
            }
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func markBody(_ mark: AgentMonitorStatusIndicatorDescriptor.Mark) -> some View {
        switch mark {
        case .pulse:
            // Absent from the mark list rather than hidden while running, so nothing retains a
            // repeating animation once the target stops running, the row disappears, or Reduce
            // Motion is on.
            AgentMonitorStatusPulse(tint: tint, diameter: haloDiameter)
        case .halo:
            Circle()
                .stroke(tint.opacity(0.5), lineWidth: 1)
                .frame(width: haloDiameter, height: haloDiameter)
        case .dot:
            Circle()
                .fill(tint)
                .frame(width: frameSize * 0.46, height: frameSize * 0.46)
        case .ring:
            Circle()
                .stroke(tint, lineWidth: 1.5)
                .frame(width: frameSize * 0.5, height: frameSize * 0.5)
        case .dashedRing:
            Circle()
                .stroke(tint, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: frameSize * 0.55, height: frameSize * 0.55)
        case .slash:
            Rectangle()
                .fill(tint)
                .frame(width: frameSize * 0.62, height: 1)
                .rotationEffect(.degrees(-45))
        }
    }
}

/// The running halo. Its own view so appearing/disappearing starts and ends the animation, with no
/// timer, task, or bridge state involved.
private struct AgentMonitorStatusPulse: View {
    let tint: Color
    let diameter: CGFloat

    @State private var isExpanded = false

    var body: some View {
        Circle()
            .stroke(tint, lineWidth: 1)
            .frame(width: diameter, height: diameter)
            .scaleEffect(isExpanded ? 1.25 : 1)
            .opacity(isExpanded ? 0 : 0.35)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: isExpanded)
            .onAppear { isExpanded = true }
            .onDisappear { isExpanded = false }
    }
}
