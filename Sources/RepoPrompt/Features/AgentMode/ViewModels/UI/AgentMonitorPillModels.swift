import Foundation
import RepoPromptDomainRuntime

// MARK: - Identifier formatting

/// Short display form for an Agent session ID.
///
/// The full canonical UUID remains available through the row's tooltip, accessibility value, and
/// Copy Session ID actions. The compact form is retained for fallback task names, previews, inbound
/// labels, notices, and attribution.
enum AgentMonitorSessionIDFormatter {
    private static let baseTokenLength = 4

    static func short(_ sessionID: UUID) -> String {
        token(sessionID, endLength: baseTokenLength)
    }

    private static func token(_ sessionID: UUID, endLength: Int) -> String {
        let raw = sessionID.uuidString
        guard raw.count > endLength * 2 else { return raw }
        return "\(raw.prefix(endLength))…\(raw.suffix(endLength))"
    }
}

// MARK: - Status

/// Safe, agent-neutral status projection for one overseen endpoint.
///
/// Status is conveyed by text and symbol as well as color so it survives color-blind and
/// high-contrast presentation.
enum AgentMonitorLinkStatus: String, Equatable {
    case idle
    case running
    case awaitingUser
    /// The bridge has no current published snapshot for this target yet.
    case unavailable

    init(
        status: DomainAgentSessionLinkStatus,
        pendingInteraction: DomainAgentSessionLinkPendingInteractionKind?
    ) {
        if pendingInteraction != nil {
            self = .awaitingUser
            return
        }
        switch status {
        case .idle:
            self = .idle
        case .running:
            self = .running
        case .awaitingUser:
            self = .awaitingUser
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .awaitingUser: "Waiting for input"
        case .unavailable: "Unavailable"
        }
    }

    /// Canonical dashboard partition. Status subtypes do not rank within either partition.
    var isActiveForDashboardOrdering: Bool {
        switch self {
        case .running, .awaitingUser: true
        case .idle, .unavailable: false
        }
    }

    /// Spoken status keeps the target-window qualification that the compact visible label omits.
    var accessibilityLabel: String {
        switch self {
        case .awaitingUser: "Waiting for input in its window"
        case .idle, .running, .unavailable: label
        }
    }

    /// Hover detail. It explains what the state means for the user rather than repeating the label,
    /// and names the one thing the compact label cannot: where a waiting session is waiting.
    var tooltip: String {
        switch self {
        case .idle: "This session is loaded and not working."
        case .running: "This session is working right now."
        case .awaitingUser: "This session is waiting for input in its own window."
        case .unavailable: "RepoPrompt has no current status for this session."
        }
    }

    /// Model-only description of the mark rendered beside the status word.
    ///
    /// Deliberately replaces the former transport symbols: a `play.circle`/`pause.circle` pair reads
    /// as a control the user can press, and Idle is not “paused”. Shape and tone are named
    /// semantically so the vocabulary stays testable and SwiftUI colours stay in the view layer.
    var indicator: AgentMonitorStatusIndicatorDescriptor {
        switch self {
        case .idle:
            AgentMonitorStatusIndicatorDescriptor(shape: .hollowRing, tone: .neutral, pulses: false)
        case .running:
            AgentMonitorStatusIndicatorDescriptor(shape: .haloedDot, tone: .live, pulses: true)
        case .awaitingUser:
            AgentMonitorStatusIndicatorDescriptor(shape: .attentionDot, tone: .attention, pulses: false)
        case .unavailable:
            AgentMonitorStatusIndicatorDescriptor(shape: .slashedRing, tone: .dimmed, pulses: false)
        }
    }
}

/// Shape, tone, and motion intent for one status mark.
///
/// Colour is never the only cue: the adjacent status word stays the primary semantic label, and the
/// shape distinguishes every state on its own for grayscale, high-contrast, and colour-blind
/// presentation.
struct AgentMonitorStatusIndicatorDescriptor: Equatable {
    enum Shape: String, Equatable {
        /// Filled dot inside a thin halo ring. The halo is permanent geometry, not the pulse.
        case haloedDot
        /// Hollow ring: present, not working.
        case hollowRing
        /// Filled attention dot.
        case attentionDot
        /// Diagonally slashed hollow ring: nothing is currently observable.
        case slashedRing
    }

    enum Tone: String, Equatable {
        case live
        case neutral
        case attention
        case dimmed
    }

    /// One drawn element of a mark.
    ///
    /// The composition lives here rather than in the view so "Running still looks different from
    /// Waiting with motion off" is a fact a test can assert, instead of a claim about a `body` that
    /// only a running app evaluates.
    enum Mark: String, Hashable {
        /// The expanding ring. The only element Reduce Motion removes.
        case pulse
        /// The static ring around a live dot.
        case halo
        case dot
        case ring
        case dashedRing
        case slash
    }

    let shape: Shape
    let tone: Tone
    /// Running is the only state worth animating, and the view still suppresses the pulse under
    /// Reduce Motion. This flag is the intent, not the animation itself.
    let pulses: Bool

    /// The elements this mark draws, back to front, for one motion setting.
    ///
    /// Reduce Motion removes the pulse and nothing else. Running keeps its halo, so it stays a dot
    /// inside a ring while Waiting stays a bare dot: the shape-redundant contract holds for users who
    /// suppress animation, not only for users who allow it.
    func marks(reduceMotion: Bool) -> [Mark] {
        switch shape {
        case .haloedDot: (pulses && !reduceMotion ? [.pulse] : []) + [.halo, .dot]
        case .hollowRing: [.ring]
        case .attentionDot: [.dot]
        case .slashedRing: [.dashedRing, .slash]
        }
    }
}

// MARK: - Activity acknowledgement

/// Result of acknowledging one generation-qualified row's newest activity.
enum AgentMonitorSeenOutcome: Equatable {
    case marked
    case alreadySeen
    case failed(message: String)

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

/// Result of changing one exact observer endpoint's passive status-notice preference.
///
/// Observer-level rather than row-level: the preference is one process-memory switch covering every
/// direct outbound link that endpoint holds, so it reports the resulting state and the link count it
/// now applies to instead of a row identity. Both the dashboard toggle and the overseer's own tool
/// render this value rather than assuming their request succeeded.
enum AgentMonitorPassiveNoticeOutcome: Equatable {
    case changed(enabled: Bool, activeLinkCount: Int)
    case alreadyInRequestedState(enabled: Bool, activeLinkCount: Int)
    case failed(message: String)

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }

    /// The authoritative preference after the request, or `nil` when nothing was changed because the
    /// request failed.
    var enabled: Bool? {
        switch self {
        case let .changed(enabled, _), let .alreadyInRequestedState(enabled, _): enabled
        case .failed: nil
        }
    }

    /// Direct outbound links the preference currently applies to.
    var activeLinkCount: Int? {
        switch self {
        case let .changed(_, count), let .alreadyInRequestedState(_, count): count
        case .failed: nil
        }
    }
}

/// Copy for the observer-session **Auto-wake on updates** switch.
///
/// Separate from `AgentMonitorRowActionCopy` because the control is not a row action: it is one
/// setting for this observer session, saved with it, covering every direct outbound link it holds.
///
/// The tooltip states the whole contract in the order that matters: that updates arrive either way,
/// what this switch adds, and — load-bearing — the bound on what it can create. A user who reads
/// "auto-wake" and imagines an autonomous background agent has been mis-sold the feature.
enum AgentMonitorAutoWakeCopy {
    static let label = "Auto-wake on all updates"
    static let laneLabel = "Auto-wake"
    static let selectAll = "Select all"
    static let deselectAll = "Deselect all"
    /// Says what the switch does *and* what it can lead to.
    ///
    /// It used to promise that “automatic turns never chain”. That was a transport guarantee, and it
    /// no longer exists: a follow-up turn may act on the user’s standing instruction and produce
    /// activity that is itself an update, so a chain — including two sessions the user pointed at each
    /// other — is a real outcome of turning this on. Leaving the old sentence in place would be the
    /// worst version of this control: a bounded-sounding promise next to unbounded behaviour. The
    /// routine-selection controls and the hard unlink boundary are named instead of adding a new
    /// setting.
    static let tooltip = """
    Status updates for these sessions are always attached to this agent’s next turn. Turning this on \
    additionally lets RepoPrompt start one follow-up turn for a routine status update or overflow \
    summary: a busy agent finishes its current and already-accepted work first. A follow-up turn can \
    create another update or attention request, so follow-ups can continue; one oversight link can \
    sustain a feedback loop, and sessions that oversee each other can keep waking one another. An \
    explicit attention request from an exactly linked session can bypass this master switch, its own \
    lane toggle, and that lane’s status Auto-wake snooze without changing any of them. Admission for \
    routine status and overflow remains governed by selection and snooze. To stop those routine wakes, \
    switch off and deselect or snooze the lane. To prevent purposeful attention from that link, \
    unlink it; revocation and all other safety and admission gates still apply. The setting applies \
    to this session rather than to individual links. Off by default, and saved with this session even \
    when it oversees nothing.
    """
    static let accessibilityLabel = "Auto-wake on all updates"
    static let accessibilityHint = """
    Controls follow-up turns for selected linked sessions’ routine status and overflow updates. \
    Explicit attention requests can bypass this master switch, their lane toggle, and their exact \
    lane’s snooze without changing them; status updates are attached to your own next turn either \
    way. Unlink revokes attention, and all other safety and admission gates still apply
    """
    static let unavailableMessage = "That Agent session is no longer active."
    /// Shown with zero links, where the setting is saved but has nothing to act on yet.
    static let noLinksNote = "Saved with this session. It takes effect once you oversee something."
    static let loadingReason = "This Agent session is still loading."
    static let closingReason = "This Agent session is closing."
    static let missingReason = "That Agent session is no longer active."
}

/// Copy for the inline row controls and the unread affordance.
///
/// Tooltips explain behaviour or reveal detail the row cannot show; they never merely repeat the
/// visible label.
enum AgentMonitorRowActionCopy {
    static let unreadBadge = "New"
    static let unreadTooltip = """
    New activity since you last acknowledged this session. Click to mark it seen — opening this \
    dashboard or viewing the agent does not.
    """
    static let viewTooltip = "Open this Agent session"
    static let viewDisabledTooltip = "This Agent session can’t be opened right now."
    static let viewFailureMessage = "That Agent session can’t be opened right now."
    static let unlinkTooltip = """
    Removes oversight immediately. Undo is offered briefly and creates a new link rather than \
    restoring the old one.
    """
}

/// One outbound lane's active Auto-wake snooze, exactly as the dashboard renders it.
///
/// Deliberately carries the wall-clock expiry rather than a countdown: admission is decided on a
/// monotonic deadline the UI never sees, and a stored "seconds left" would be wrong the moment the
/// popover stopped repainting. Everything visible is derived from this instant against an explicit
/// `now`, so one popover-scoped minute tick renders every row from the same reference.
struct AgentMonitorAutoWakeSnoozeState: Equatable {
    let expiresAt: Date
    let origin: AgentSessionLinkAutoWakeSnoozeOrigin

    /// Rounded **up**, so a snooze with any time left never reads as `0 min left`.
    func remainingMinutes(now: Date) -> Int {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return max(1, Int(ceil(remaining / 60)))
    }

    /// Local expiry, which can be reached before the authoritative removal repaints this row.
    func hasExpired(now: Date) -> Bool {
        expiresAt <= now
    }
}

/// Copy for the subordinate Auto-wake status, its Clear control, and the snooze/extend menu.
///
/// Lives on the model rather than inline in the view for the same reason the row action copy does:
/// the wording, the minute rounding, and the extension filtering are all things a test can assert
/// here and cannot assert about a SwiftUI `body`.
///
/// The filtering is presentation only. The server applies `max(current deadline, now + duration)`,
/// so offering a choice that would not move the deadline is not unsafe — it is just a control that
/// silently does nothing, which is what this hides.
enum AgentMonitorAutoWakeSnoozeCopy {
    static let menuLabel = "Snooze status Auto-wake\u{2026}"
    static let clearLabel = "Clear"

    /// Shown between local expiry and the authoritative repaint that removes the row.
    ///
    /// Deliberately not "delivering", "sending", or "waking": expiry promises exactly one ordinary
    /// re-evaluation, and the usual readiness, authority, routine-selection, and suppression gates
    /// decide whether anything happens at all.
    static let expired = "Status Auto-wake snooze expired \u{00B7} Re-evaluating eligibility\u{2026}"

    /// The one informational — not failed — outcome a set or extension can report.
    static let currentDispatchAlreadyStarted = """
    Current Auto-wake already started. This snooze applies only to later routine status and overflow \
    wakes; explicit attention requests can bypass this snooze and routine selection without changing \
    either.
    """

    static let unavailableMessage = "That oversight link is no longer active."

    /// Row-local wording for each typed routing failure.
    ///
    /// A stale generation reads as "no longer active" rather than naming the generation: the row the
    /// user clicked really is gone, and the replacement is a different lane.
    static func failureMessage(_ failure: AgentSessionLinkAutoWakeSnoozeFailure) -> String {
        switch failure {
        case .observerUnavailable, .staleReference:
            unavailableMessage
        case .laneNotEffectivelySelected:
            "Routine status Auto-wake isn\u{2019}t on for this session, so there is nothing to snooze."
        case .shuttingDown:
            "RepoPrompt is shutting down, so the Auto-wake snooze wasn\u{2019}t changed."
        }
    }

    /// Deliberately says “coalesced” rather than “collected”.
    ///
    /// What survives a snooze is the queue's ordinary first-to-final summary per lane, not a replay
    /// of every intermediate change — and a lane that ends where it started leaves nothing at all.
    /// “Collected” reads as an exhaustive history the reducer has never kept.
    static let menuTooltip = """
    Stops this session\u{2019}s routine status and overflow updates from starting an automatic \
    follow-up turn for a while. Status stays coalesced into the pending summary and still rides along \
    with your next turn. An explicit attention request can bypass this snooze, the master switch, and \
    this lane\u{2019}s toggle without changing any of them. Admission for routine status and overflow \
    remains governed by selection and snooze. To prevent further attention from this link, unlink it. \
    Clearing or expiry only lets RepoPrompt re-evaluate \u{2014} it never forces a turn.
    """

    static let accessibilityHint = """
    Pauses routine status and overflow wakes only. An explicit attention request can bypass this \
    snooze, the master switch, and this lane\u{2019}s toggle without changing them. Admission for \
    routine status and overflow remains governed by selection and snooze. Unlink prevents further \
    attention from this link; all other safety and admission gates still apply.
    """

    /// Who set the current deadline, phrased for the row rather than for the wire.
    static func originPhrase(_ origin: AgentSessionLinkAutoWakeSnoozeOrigin) -> String {
        switch origin {
        case .user: "you"
        case .agent: "this agent"
        }
    }

    /// `Status Auto-wake snoozed by you \u{00B7} 9 min left`, or the expiring state once local time passes it.
    static func subrow(_ state: AgentMonitorAutoWakeSnoozeState, now: Date) -> String {
        guard !state.hasExpired(now: now) else { return expired }
        return "Status Auto-wake snoozed by \(originPhrase(state.origin)) \u{00B7} "
            + "\(state.remainingMinutes(now: now)) min left"
    }

    /// Spoken form: who set it, how much is left, and the absolute instant a listener cannot glance
    /// back at the row to resolve.
    static func accessibilityValue(
        _ state: AgentMonitorAutoWakeSnoozeState,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard !state.hasExpired(now: now) else { return expired }
        let minutes = state.remainingMinutes(now: now)
        let origin = state.origin == .user ? "Set by you." : "Set by this agent."
        let expiry = expiryPhrase(state.expiresAt, now: now, calendar: calendar, locale: locale)
        return "\(origin) \(minutes) \(minutes == 1 ? "minute" : "minutes") remaining. \(expiry)"
    }

    /// `Expires today at 4:20 PM.` — the day word is dropped only when the expiry is not today,
    /// where the date itself is the unambiguous form.
    static func expiryPhrase(
        _ expiresAt: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = expiresAt.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
        guard calendar.isDate(expiresAt, inSameDayAs: now) else {
            let day = expiresAt.formatted(
                Date.FormatStyle(
                    date: .abbreviated,
                    time: .omitted,
                    locale: locale,
                    calendar: calendar,
                    timeZone: calendar.timeZone
                )
            )
            return "Expires \(day) at \(time)."
        }
        return "Expires today at \(time)."
    }

    static func minutes(forSeconds seconds: Int) -> Int {
        max(1, seconds / 60)
    }

    static func setOptionLabel(seconds: Int) -> String {
        "Snooze for \(minutes(forSeconds: seconds)) minutes"
    }

    /// `at least`, because the server keeps the later of the two deadlines: the horizon the user
    /// picks is a floor, never a replacement.
    static func extendOptionLabel(seconds: Int) -> String {
        "Extend to at least \(minutes(forSeconds: seconds)) minutes from now"
    }

    /// The offers worth showing: everything when nothing is snoozed, and only the horizons that
    /// would actually move an active deadline otherwise.
    static func availableDurationSeconds(
        activeExpiry: Date?,
        now: Date
    ) -> [Int] {
        let offers = AgentSessionLinkAutoWakeSnooze.uiDurationSeconds
        guard let activeExpiry, activeExpiry > now else { return offers }
        return offers.filter { now.addingTimeInterval(TimeInterval($0)) > activeExpiry }
    }

    static func actionLabel(
        displayName: String,
        seconds: Int,
        isExtension: Bool
    ) -> String {
        isExtension
            ? "Extend status Auto-wake snooze for \(displayName) to at least "
            + "\(minutes(forSeconds: seconds)) minutes from now"
            : "Snooze status Auto-wake for \(displayName) for \(minutes(forSeconds: seconds)) minutes"
    }

    static func menuAccessibilityLabel(displayName: String) -> String {
        "Snooze status Auto-wake for \(displayName)"
    }

    static func clearActionLabel(displayName: String) -> String {
        "Clear status Auto-wake snooze for \(displayName)"
    }
}

/// One row's persistent local feedback.
///
/// Widened from a bare string only far enough to tell an operation that **failed** apart from the
/// approved informational notice that a set succeeded too late to affect the call already running.
/// Both are row-local presentation: neither is authority, and neither survives the row.
enum AgentMonitorRowFeedback: Equatable {
    case failure(String)
    case notice(String)

    var message: String {
        switch self {
        case let .failure(message), let .notice(message): message
        }
    }

    /// Whether this row-local message reports that something went wrong.
    ///
    /// The distinction has to be read somewhere or the two cases are the same type: it selects the
    /// VoiceOver announcement priority, so a successful “too late to cancel” notice does not
    /// interrupt like a failure does.
    var isFailure: Bool {
        switch self {
        case .failure: true
        case .notice: false
        }
    }
}

/// Freshness copy in the three deterministic forms the dashboard needs: compact calendar-aware
/// visible text, expanded accessibility wording, and a full absolute timestamp for hover detail.
///
/// Every operation takes an explicit reference date and calendar, so bucket selection is testable
/// and one popover-scoped minute tick can render every row from the same instant.
enum AgentMonitorActivityFormatter {
    /// Rendered inside a `·`-joined line, so it deliberately carries no sentence punctuation.
    static let unavailable = "Activity unavailable"
    static let accessibilityUnavailable = "Last activity unavailable"
    static let justNow = "just now"
    static let yesterday = "Yesterday"

    /// Compact visible freshness, first match wins from the top:
    ///
    /// | Age | Text |
    /// |---|---|
    /// | under a minute, or a future clock | `just now` |
    /// | 1–59 minutes | `Nm ago` |
    /// | earlier on the same local day | localized short time |
    /// | the previous local day | `Yesterday` |
    /// | older | compact localized date, with the year only when it is not the current one |
    /// | missing | `Activity unavailable` |
    ///
    /// Minutes deliberately outrank the calendar buckets, so activity twenty minutes before local
    /// midnight reads `20m ago` rather than jumping straight to `Yesterday`.
    static func compact(
        _ date: Date?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let date else { return unavailable }
        let elapsed = now.timeIntervalSince(date)
        // Negative elapsed time is a target clock running slightly ahead of this one, which is a
        // skew artefact rather than a scheduled future event: it reads as current, never as a date.
        if elapsed < 60 { return justNow }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if calendar.isDate(date, inSameDayAs: now) {
            return time(date, calendar: calendar, locale: locale)
        }
        if let previousDay = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: now)
        ), calendar.isDate(date, inSameDayAs: previousDay) {
            return yesterday
        }
        return day(date, now: now, calendar: calendar, locale: locale)
    }

    /// Full localized absolute date and time, for hover detail and accessibility.
    static func absolute(
        _ date: Date?,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let date else { return unavailable }
        return date.formatted(
            Date.FormatStyle(
                date: .complete,
                time: .standard,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }

    /// Spoken freshness. VoiceOver gets the absolute instant rather than the compact ladder: a
    /// listener cannot glance back at the row to resolve `15:07` into a day.
    static func accessibility(
        _ date: Date?,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard date != nil else { return accessibilityUnavailable }
        return "Last activity \(absolute(date, calendar: calendar, locale: locale))"
    }

    private static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }

    private static func day(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated)
            .day()
        guard calendar.component(.year, from: date) == calendar.component(.year, from: now) else {
            return date.formatted(style.year())
        }
        return date.formatted(style)
    }
}

// MARK: - Location and detail line

/// Resolves the **UI-only** execution-location label carried by one oversight row.
///
/// A session bound to a worktree on its primary root names that worktree. A session with no
/// primary-root worktree binding — including one bound only to a secondary root — produces no
/// indicator at all, and an empty slot in the detail line is indistinguishable from "location
/// unknown" — which is the exact question this popover exists to answer for a user working across
/// many windows. It therefore falls back to the workspace name
/// qualified with `(main)`: the workspace name is what distinguishes rows across windows and
/// workspaces, and the qualifier keeps it from reading as a worktree that does not exist.
///
/// Resolved in the endpoint's **own** window, so a row describing another window names that window's
/// workspace rather than the viewer's. Like every other location value on this surface it is UI only
/// and never enters an agent-facing snapshot, inventory, or prompt.
enum AgentMonitorLocationLabelFormatter {
    static func label(worktreeLabel: String?, workspaceName: String?) -> String {
        if let worktree = worktreeLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !worktree.isEmpty
        {
            return worktree
        }
        guard let workspace = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspace.isEmpty
        else {
            return "main"
        }
        return "\(workspace) (main)"
    }
}

/// Builds supporting preview, inbound, and non-layout detail lines.
///
/// The outbound dashboard now promotes location to its primary line and uses
/// `taskMetadataLine(now:calendar:locale:)` for its secondary line; these remaining consumers still
/// share separator and omission behavior here.
enum AgentMonitorDetailLineFormatter {
    static func line(
        location: String?,
        provider: String?,
        status: AgentMonitorLinkStatus?,
        activity: String? = nil
    ) -> String {
        [location, provider, activity].compactMap(\.self).joined(separator: " · ")
    }
}

/// Spoken form of the location slot, e.g. `" in feature-219"`.
///
/// Location is the primary visual discriminator on these rows, so a VoiceOver user who hears only a
/// full UUID is materially worse off than a sighted one. Shared by every accessible surface that
/// names a session so the phrasing cannot drift between them.
enum AgentMonitorAccessibilityLocationPhrase {
    static func clause(_ location: String?) -> String {
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty
        else {
            return ""
        }
        return " in \(location)"
    }
}

// MARK: - Pill props

/// Equatable rendering contract for the Oversee pill and its management popover.
///
/// Workspace/worktree labels here are **UI only**; they are never placed in agent-facing snapshots,
/// inventories, or prompts.
struct AgentMonitorPillProps: Equatable {
    struct Outbound: Equatable, Identifiable {
        let linkID: UUID
        let generation: UInt64
        let targetSessionID: UUID
        /// Exact target incarnation recorded by the authority for this generation-qualified row.
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let displayName: String
        let providerDisplayName: String?
        let locationLabel: String?
        let status: AgentMonitorLinkStatus
        let lastActivityAt: Date?
        /// True when this exact link has activity strictly newer than the watermark the user
        /// acknowledged.
        let hasUnreadActivity: Bool
        let targetRoute: AgentSessionDeepLinkRoute?
        /// This lane's active Auto-wake snooze, or `nil` when it is not snoozed.
        ///
        /// State only: the row's controls act through the runtime bridge and render whatever the next
        /// authoritative projection says, so nothing here is a closure, a busy flag, or a result the
        /// view could set optimistically.
        let autoWakeSnooze: AgentMonitorAutoWakeSnoozeState?
        /// Whether this lane could currently admit a routine status/overflow wake — the observer's
        /// master setting, or this target's own granular selection. Exact purposeful attention does
        /// not consult this policy value.
        ///
        /// It gates the set/extend offers and nothing else: a deselected lane that is still snoozed
        /// must remain clearable, which is why Clear is not gated on it.
        let isAutoWakeEffectivelySelected: Bool

        init(
            linkID: UUID,
            generation: UInt64,
            targetSessionID: UUID,
            targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
            displayName: String,
            providerDisplayName: String?,
            locationLabel: String?,
            status: AgentMonitorLinkStatus,
            lastActivityAt: Date? = nil,
            hasUnreadActivity: Bool = false,
            targetRoute: AgentSessionDeepLinkRoute? = nil,
            autoWakeSnooze: AgentMonitorAutoWakeSnoozeState? = nil,
            isAutoWakeEffectivelySelected: Bool = false
        ) {
            self.linkID = linkID
            self.generation = generation
            self.targetSessionID = targetSessionID
            self.targetEndpoint = targetEndpoint
            self.displayName = displayName
            self.providerDisplayName = providerDisplayName
            self.locationLabel = locationLabel
            self.status = status
            self.lastActivityAt = lastActivityAt
            self.hasUnreadActivity = hasUnreadActivity
            self.targetRoute = targetRoute
            self.autoWakeSnooze = autoWakeSnooze
            self.isAutoWakeEffectivelySelected = isAutoWakeEffectivelySelected
        }

        /// The same row carrying observer-local Auto-wake policy.
        ///
        /// Applied where the authoritative link projection is received rather than built into it: the
        /// policy lives on the exact observer session, not in the link authority, and the two are
        /// deliberately refreshed on different schedules.
        func withAutoWakeState(
            snooze: AgentMonitorAutoWakeSnoozeState?,
            isEffectivelySelected: Bool
        ) -> Outbound {
            guard snooze != autoWakeSnooze
                || isEffectivelySelected != isAutoWakeEffectivelySelected
            else {
                return self
            }
            return Outbound(
                linkID: linkID,
                generation: generation,
                targetSessionID: targetSessionID,
                targetEndpoint: targetEndpoint,
                displayName: displayName,
                providerDisplayName: providerDisplayName,
                locationLabel: locationLabel,
                status: status,
                lastActivityAt: lastActivityAt,
                hasUnreadActivity: hasUnreadActivity,
                targetRoute: targetRoute,
                autoWakeSnooze: snooze,
                isAutoWakeEffectivelySelected: isEffectivelySelected
            )
        }

        var id: UUID {
            linkID
        }

        /// Generation-qualified row identity, used only to expire row-local view state: a relink
        /// reuses the link ID under a new generation and must not inherit the retired row's busy
        /// marker or feedback.
        var rowKey: String {
            "\(linkID.uuidString)-\(generation)"
        }

        var fullID: String {
            targetSessionID.uuidString
        }

        /// Identity hover detail for the truncatable task metadata line.
        var identityTooltip: String {
            "\(displayName)\n\(fullID)"
        }

        /// Complete secondary detail retained for tooltips and non-layout consumers.
        ///
        /// Carries the *absolute* timestamp rather than the compact ladder, so it needs no reference
        /// date and stays stable for consumers that are not driven by the popover's minute tick.
        var detailLine: String {
            AgentMonitorDetailLineFormatter.line(
                location: locationLabel,
                provider: providerDisplayName,
                status: nil,
                activity: AgentMonitorActivityFormatter.absolute(lastActivityAt)
            )
        }

        /// Primary visible location. Missing raw locations remain missing for sorting, while the row
        /// renders an action-oriented fallback because this label is also the View affordance.
        var locationDisplayLabel: String {
            guard let trimmed = locationLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else {
                return "Open session"
            }
            return trimmed
        }

        /// Compact freshness text rendered as the final task-metadata segment.
        func activityLine(
            now: Date = Date(),
            calendar: Calendar = .current,
            locale: Locale = .current
        ) -> String {
            AgentMonitorActivityFormatter.compact(
                lastActivityAt,
                now: now,
                calendar: calendar,
                locale: locale
            )
        }

        /// Secondary task metadata: task name, optional provider, then compact freshness.
        func taskMetadataLine(
            now: Date = Date(),
            calendar: Calendar = .current,
            locale: Locale = .current
        ) -> String {
            var segments: [String] = []
            let task = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !task.isEmpty {
                segments.append(task)
            }
            if let provider = providerDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !provider.isEmpty
            {
                segments.append(provider)
            }
            segments.append(activityLine(now: now, calendar: calendar, locale: locale))
            return segments.joined(separator: " · ")
        }

        /// Absolute instant behind the compact relative text, revealed on hover.
        var activityTooltip: String {
            AgentMonitorActivityFormatter.absolute(lastActivityAt)
        }

        var activityAccessibilityLabel: String {
            AgentMonitorActivityFormatter.accessibility(lastActivityAt)
        }

        var accessibilityDescription: String {
            let location = AgentMonitorAccessibilityLocationPhrase.clause(locationLabel)
            let unread = hasUnreadActivity ? ", New activity" : ""
            return "Overseeing \(displayName)\(location), session \(fullID), "
                + "\(status.accessibilityLabel), \(activityAccessibilityLabel)\(unread)"
        }

        /// VoiceOver labels for this row's inline controls.
        ///
        /// They live on the model rather than inline in the view so the wording stays under test and
        /// cannot drift from `accessibilityDescription`; repeated compact controls
        /// per row are indistinguishable in the rotor without the session name.
        var viewActionLabel: String {
            guard let location = locationLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !location.isEmpty
            else {
                return "Open session: View \(displayName)"
            }
            return "View \(displayName) in \(location)"
        }

        var markSeenActionLabel: String {
            "Mark \(displayName) activity as seen"
        }

        var unlinkActionLabel: String {
            "Unlink oversight of \(displayName)"
        }

        var snoozeMenuAccessibilityLabel: String {
            AgentMonitorAutoWakeSnoozeCopy.menuAccessibilityLabel(displayName: displayName)
        }

        var clearSnoozeActionLabel: String {
            AgentMonitorAutoWakeSnoozeCopy.clearActionLabel(displayName: displayName)
        }

        /// An elapsed record is not an active snooze here either: the row's expiring state is a
        /// presentation of the same monotonic deadline admission already treats as inactive.
        func hasActiveAutoWakeSnooze(now: Date) -> Bool {
            autoWakeSnooze.map { !$0.hasExpired(now: now) } ?? false
        }

        /// The horizons worth offering right now: everything when nothing is snoozed, and only the
        /// ones that would actually move an active deadline otherwise.
        func availableSnoozeDurationSeconds(now: Date) -> [Int] {
            AgentMonitorAutoWakeSnoozeCopy.availableDurationSeconds(
                activeExpiry: autoWakeSnooze?.expiresAt,
                now: now
            )
        }

        func snoozeOptionLabel(seconds: Int, now: Date) -> String {
            hasActiveAutoWakeSnooze(now: now)
                ? AgentMonitorAutoWakeSnoozeCopy.extendOptionLabel(seconds: seconds)
                : AgentMonitorAutoWakeSnoozeCopy.setOptionLabel(seconds: seconds)
        }

        func snoozeActionLabel(seconds: Int, now: Date) -> String {
            AgentMonitorAutoWakeSnoozeCopy.actionLabel(
                displayName: displayName,
                seconds: seconds,
                isExtension: hasActiveAutoWakeSnooze(now: now)
            )
        }
    }

    struct Inbound: Equatable, Identifiable {
        let linkID: UUID
        let generation: UInt64
        let observerSessionID: UUID
        /// Exact observer incarnation recorded by the authority for this generation-qualified row.
        let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
        let displayName: String
        let providerDisplayName: String?

        var id: UUID {
            linkID
        }

        /// Generation-qualified row identity, for the same reason `Outbound` carries one: row-local
        /// view state must expire with the exact row it was created for, and a relink reuses the
        /// link ID under a new generation.
        var rowKey: String {
            "\(linkID.uuidString)-\(generation)"
        }

        var shortID: String {
            AgentMonitorSessionIDFormatter.short(observerSessionID)
        }

        var fullID: String {
            observerSessionID.uuidString
        }

        var rowLabel: String {
            "← \(displayName) (\(shortID))"
        }

        /// Exact route to the observer incarnation recorded on this relationship.
        ///
        /// It is derived rather than refreshed from the live candidate list: a disappeared observer
        /// must remain unlinkable, and attempting this route lets the shared router report that the
        /// exact window, workspace, tab, or session is no longer available.
        var observerRoute: AgentSessionDeepLinkRoute {
            AgentSessionDeepLinkRoute(
                windowID: observerEndpoint.windowID,
                workspaceID: observerEndpoint.workspaceID,
                tabID: observerEndpoint.tabID,
                sessionID: observerEndpoint.sessionID
            )
        }

        /// VoiceOver label for the primary observer navigation affordance.
        var viewActionLabel: String {
            "View \(displayName), session \(shortID)"
        }

        /// Secondary line for this row.
        ///
        /// Carries neither status nor location. Nothing installs an observation on an *observer's*
        /// session — observations are installed per overseen target — so no observer-side change
        /// schedules a refresh of this projection, and both values would freeze at whatever the last
        /// link event happened to record.
        ///
        /// Status is obviously live. Location is too: `commitWorktreeBindings` is the only mutation
        /// point for `worktreeBindings`, and it neither bumps `bindingTransitionGeneration` (so the
        /// endpoint identity does not drift and the link is not revoked or rebound) nor feeds
        /// `monitorObservationSignal`. An observer can therefore change execution location while this
        /// link is live and leave a location rendered here permanently wrong. Provider is different in
        /// kind rather than in refresh: it is locked once a session has sent its first message, which
        /// is a precondition of having the durable binding oversight requires.
        var detailLine: String {
            AgentMonitorDetailLineFormatter.line(
                location: nil,
                provider: providerDisplayName,
                status: nil
            )
        }

        var accessibilityDescription: String {
            "Overseen by \(displayName), session \(fullID)"
        }

        /// VoiceOver label for this row's Unlink control, phrased from the overseen session's side.
        var unlinkActionLabel: String {
            "Unlink \(displayName) from overseeing this session"
        }
    }

    struct Notice: Equatable, Identifiable {
        let linkID: UUID
        let generation: UInt64
        let message: String

        var id: String {
            "\(linkID.uuidString)-\(generation)"
        }
    }

    /// The observing session this projection belongs to, or `nil` while the tab has no durable
    /// top-level binding.
    let sessionID: UUID?
    /// The exact incarnation this projection was published to, or `nil` for a locally synthesized
    /// placeholder that carries no authority state.
    ///
    /// Notices are recorded per incarnation, so dismissing them needs the identity rather than the
    /// session UUID: a duplicate live incarnation of the same UUID must not clear another's notices.
    var endpoint: DomainAgentSessionLinkEndpointIdentity?
    /// Target-centric relationship choices for this exact endpoint.
    ///
    /// `nil` means the endpoint is not currently an eligible target (or this is a synthesized local
    /// placeholder). A non-nil empty value means there is neither an eligible observer to add nor an
    /// existing relationship to unlink, so the sidebar renders no management surface.
    let sidebarOversightMenu: AgentSidebarOversightMenuProps?
    let outbound: [Outbound]
    let inbound: [Inbound]
    let recentNotices: [Notice]
    /// Non-nil when Add must stay disabled, carrying the exact user-facing reason.
    let canAddReason: String?
    /// This observer session's persisted **Auto-wake on updates** setting.
    ///
    /// Session-level and durable, unlike the process-memory preference it replaces: it survives
    /// relaunch, stays editable and saved with zero links, and is read straight from the exact live
    /// session rather than mirrored into the bridge. Authoritative — the dashboard requests a change
    /// and renders whatever the republished props say, so nothing here is optimistic.
    ///
    /// It gates only whether routine status/overflow content may reserve one system-origin follow-up.
    /// Exact purposeful attention may bypass it without changing it. Collection and natural-turn
    /// delivery are always on for a live, eligible direct link.
    var autoWakeOnUpdatesEnabled: Bool
    /// Saved granular selections, including UUIDs whose links are currently hidden or absent.
    var autoWakeTargetSessionIDs: Set<UUID>
    /// Why the setting cannot be changed right now, or `nil` when it can.
    ///
    /// Reserved for states where the exact session cannot take a write at all — missing, still
    /// hydrating, closing, or shutting down. Deliberately *not* set for an observer that is merely
    /// unlinked or temporarily prompt-ineligible: the setting is saved with the session and stays
    /// editable there, it is simply inert until it has something to act on.
    var autoWakeUnavailableReason: String?
    /// Process-wide durable-oversight state, overlaid by the owning window rather than published by
    /// the bridge's per-endpoint projection.
    ///
    /// It is deliberately not part of the authority projection: a tab with no links at all never
    /// receives one, and that is exactly the tab whose Add button has to explain why saving is
    /// unavailable.
    var persistence: AgentSessionOversightPersistencePresentation

    init(
        sessionID: UUID?,
        endpoint: DomainAgentSessionLinkEndpointIdentity? = nil,
        sidebarOversightMenu: AgentSidebarOversightMenuProps?,
        outbound: [Outbound],
        inbound: [Inbound],
        recentNotices: [Notice],
        canAddReason: String?,
        autoWakeOnUpdatesEnabled: Bool = false,
        autoWakeTargetSessionIDs: Set<UUID> = [],
        autoWakeUnavailableReason: String? = nil,
        persistence: AgentSessionOversightPersistencePresentation = AgentSessionOversightPersistencePresentation.noDurableLayer
    ) {
        self.sessionID = sessionID
        self.endpoint = endpoint
        self.sidebarOversightMenu = sidebarOversightMenu
        self.outbound = outbound
        self.inbound = inbound
        self.recentNotices = recentNotices
        self.canAddReason = canAddReason
        self.autoWakeOnUpdatesEnabled = autoWakeOnUpdatesEnabled
        self.autoWakeTargetSessionIDs = autoWakeTargetSessionIDs
        self.autoWakeUnavailableReason = autoWakeUnavailableReason
        self.persistence = persistence
    }

    static let empty = AgentMonitorPillProps(
        sessionID: nil,
        sidebarOversightMenu: nil,
        outbound: [],
        inbound: [],
        recentNotices: [],
        canAddReason: "Send a first message to start this session, then add sessions to oversee."
    )

    /// Overlays a freshly recomputed Add-eligibility reason onto an authoritative link projection.
    ///
    /// Link membership and notices come from the authority and change only on an authority event;
    /// eligibility depends on live session state that produces no such event, so the two are
    /// deliberately refreshed on different schedules.
    func withCanAddReason(_ reason: String?) -> AgentMonitorPillProps {
        guard reason != canAddReason else { return self }
        return AgentMonitorPillProps(
            sessionID: sessionID,
            endpoint: endpoint,
            sidebarOversightMenu: sidebarOversightMenu,
            outbound: outbound,
            inbound: inbound,
            recentNotices: recentNotices,
            canAddReason: reason,
            autoWakeOnUpdatesEnabled: autoWakeOnUpdatesEnabled,
            autoWakeTargetSessionIDs: autoWakeTargetSessionIDs,
            autoWakeUnavailableReason: autoWakeUnavailableReason,
            persistence: persistence
        )
    }

    /// Overlays the process-wide persistence level onto an authoritative or synthesized projection.
    ///
    /// The persistence blocker wins over the live eligibility reason: an eligible session still
    /// cannot be granted oversight while the durable record refuses to change, and telling the user
    /// to “load this thread” in that state sends them to fix the wrong thing.
    func withPersistence(
        _ presentation: AgentSessionOversightPersistencePresentation,
        eligibilityReason: String?
    ) -> AgentMonitorPillProps {
        let reason = presentation.addBlockerMessage ?? eligibilityReason
        guard reason != canAddReason || presentation != persistence else { return self }
        return AgentMonitorPillProps(
            sessionID: sessionID,
            endpoint: endpoint,
            sidebarOversightMenu: sidebarOversightMenu,
            outbound: outbound,
            inbound: inbound,
            recentNotices: recentNotices,
            canAddReason: reason,
            autoWakeOnUpdatesEnabled: autoWakeOnUpdatesEnabled,
            autoWakeTargetSessionIDs: autoWakeTargetSessionIDs,
            autoWakeUnavailableReason: autoWakeUnavailableReason,
            persistence: presentation
        )
    }

    /// Exact current observer role: outbound membership only.
    ///
    /// Inbound links, durable intents, and eligibility to create a future link do not make this
    /// projection an overseer.
    var isOverseer: Bool {
        !outbound.isEmpty
    }

    var hasInbound: Bool {
        !inbound.isEmpty
    }

    /// Directional counts shown in the compact dashboard pill. A missing value means the pill
    /// omits that numeric badge rather than rendering a visually ambiguous zero.
    var dashboardOutboundCount: Int? {
        outbound.isEmpty ? nil : outbound.count
    }

    var dashboardInboundCount: Int? {
        inbound.isEmpty ? nil : inbound.count
    }

    var canAdd: Bool {
        canAddReason == nil
    }

    /// VoiceOver value, e.g. "Overseeing 2 sessions; overseen by 1."
    var accessibilityValue: String {
        var parts: [String] = []
        if outbound.isEmpty {
            parts.append("Not overseeing any sessions")
        } else {
            parts.append("Overseeing \(outbound.count) \(outbound.count == 1 ? "session" : "sessions")")
        }
        if !inbound.isEmpty {
            parts.append("overseen by \(inbound.count)")
        }
        return parts.joined(separator: "; ") + "."
    }
}

// MARK: - Revocation notices

/// Renders bounded, endpoint-relative revocation notices such as
/// "Oversight of Build API ended: the window closed."
///
/// Notices are explanatory UI only: they are never persisted and never reach an agent-facing
/// payload, so they may safely name the local display names of both endpoints.
enum AgentMonitorNoticeFormatter {
    static func reasonPhrase(_ reason: DomainAgentSessionLinkRevocationReason) -> String {
        switch reason {
        case .userRequested:
            "the relationship was unlinked"
        case .observerEndpointInvalidated, .targetEndpointInvalidated:
            "the session ended"
        case .observerIdentityDrift, .targetIdentityDrift:
            "the session changed"
        case .observerNoLongerEligible:
            "this session can no longer oversee other sessions"
        case .tabClosed:
            "the chat closed"
        case .windowClosed:
            "the window closed"
        case .workspaceSwitched:
            "the workspace changed"
        case .bindingChanged:
            "the session was rebound"
        case .sessionDeleted:
            "the session was deleted"
        case .activationSeedFailed:
            "the session could not be observed"
        case .runtimeShutdown, .appTerminating:
            "RepoPrompt is shutting down"
        }
    }

    /// - Parameter endpointSessionID: the session this notice is being rendered *for*. The same
    ///   revocation reads differently at each end of the link.
    static func message(
        for notice: DomainAgentSessionLinkRevocationNotice,
        endpointSessionID: UUID,
        observerDisplayName: String?,
        targetDisplayName: String?
    ) -> String {
        let phrase = reasonPhrase(notice.reason)
        if endpointSessionID == notice.observerSessionID {
            let name = targetDisplayName
                ?? notice.targetDisplayName
                ?? AgentMonitorSessionIDFormatter.short(notice.targetSessionID)
            return "Oversight of \(name) ended: \(phrase)."
        }
        let name = observerDisplayName
            ?? notice.observerDisplayName
            ?? AgentMonitorSessionIDFormatter.short(notice.observerSessionID)
        return "\(name) no longer oversees this session: \(phrase)."
    }
}

// MARK: - Resolved preview

/// Preview shown after a UUID resolves but before the user authorizes the link.
///
/// Building this never focuses, activates, or switches the target window.
struct AgentMonitorResolvedPreview: Equatable {
    let sessionID: UUID
    let displayName: String
    let providerDisplayName: String?
    let locationLabel: String?
    let status: AgentMonitorLinkStatus

    var shortID: String {
        AgentMonitorSessionIDFormatter.short(sessionID)
    }

    var fullID: String {
        sessionID.uuidString
    }

    /// Secondary line for the preview row.
    var detailLine: String {
        AgentMonitorDetailLineFormatter.line(
            location: locationLabel,
            provider: providerDisplayName,
            status: status
        )
    }

    /// VoiceOver label for the combined preview element.
    ///
    /// Reads the full canonical UUID because the visible short form is ambiguous by construction,
    /// and this is the value the user is about to authorize. It also names the location, which is the
    /// row's primary visual discriminator and the one thing a UUID alone cannot convey.
    var accessibilityLabel: String {
        let location = AgentMonitorAccessibilityLocationPhrase.clause(locationLabel)
        return "Resolved \(displayName)\(location), session \(fullID), \(status.accessibilityLabel)"
    }
}

// MARK: - Durable persistence copy

/// User-facing copy for durable oversight persistence.
///
/// Deliberately free of session names, UUIDs, backup paths, and internal reasons: these strings are
/// rendered next to a control the user just used, and the only actionable content is what they can
/// do about it.
enum AgentSessionOversightPersistenceCopy {
    static let loading = "Saved oversight links are still loading."
    static let suppressedLaunch = "Saved oversight links are unavailable in this launch mode."
    static let autoRestoreDisabled = "Saved oversight links will remain dormant while window restoration is turned off."
    static let futureSchema = "Saved oversight links were created by a newer RepoPrompt version. The file was preserved, so oversight can’t be changed in this version."
    static let unreadable = "RepoPrompt couldn’t read or back up saved oversight links. The file was preserved, so oversight can’t be changed."
    static let quarantined = "RepoPrompt couldn’t read saved oversight links. It backed up the file and started with no saved links."
    static let terminalRestorationSummary = "Some saved oversight links couldn’t be restored and were removed."
    static let addWriteFailed = "Oversight couldn’t be saved, so it wasn’t started. Check disk space and Application Support permissions, then try again."
    static let addCompensationFailed = "Oversight didn’t start, and RepoPrompt couldn’t clear its saved request. It won’t retry again this launch; check disk space and permissions before relaunching."
    static let stopWriteFailed = "Oversight couldn’t be removed from saved state, so the link is still active. Check disk space and Application Support permissions, then try again."
    static let automaticCleanupFailed = "Oversight ended, but RepoPrompt couldn’t update saved oversight links. It may be restored after relaunch."
    static let shutdownBeforeInsert = "RepoPrompt is shutting down, so oversight wasn’t changed."
    static let shutdownAfterInsert = "RepoPrompt is shutting down. Oversight wasn’t started, but its saved request can be reconsidered next launch."

    static func message(for reason: AgentSessionOversightPersistenceBlockReason) -> String {
        switch reason {
        case .unsupportedFutureSchema:
            futureSchema
        // A preserved oversized or over-long file reads to the user exactly like an unreadable one:
        // RepoPrompt kept the file and refuses to change it. Naming the limit would be diagnostics,
        // not something they can act on.
        case .unreadable, .fileTooLarge, .tooManyRows:
            unreadable
        }
    }
}

// MARK: - Persistence presentation

/// One bounded, dismissible app-level warning about durable oversight state.
///
/// Identifiers are runtime-stable strings derived from the *kind* of warning, never from a session
/// name or UUID: these strings are rendered in every window, and the whole point of the aggregate
/// surface is that it says nothing about which sessions were involved.
struct AgentSessionOversightWarning: Equatable, Identifiable {
    let id: String
    let message: String
}

/// Process-wide durable-oversight state, overlaid onto every window's Oversee props.
///
/// The bridge owns exactly one of these and broadcasts it; a tab with no links at all still has to
/// render it, because "saved oversight links can’t be changed" is precisely the state in which the
/// user is about to try to create their first one.
struct AgentSessionOversightPersistencePresentation: Equatable {
    enum Availability: Equatable {
        /// The launch load has not settled yet.
        case loading
        /// The store is readable and writable, and automatic restore ran.
        case ready
        /// Readable and writable, but window restoration is off so saved intent stays dormant.
        case dormant
        /// Deterministic or persistence-suppressed launch: no production file I/O at all.
        case suppressed
        /// The file was preserved and mutation is refused. Carries the exact user-facing reason.
        case blocked(String)
    }

    /// Cap and dedupe are both deliberate: a repeated disk failure must not turn the popover into a
    /// log, and five is already more than a user can act on at once.
    static let maxWarnings = 5

    var availability: Availability
    var warnings: [AgentSessionOversightWarning]
    /// A token-qualified cleanup that failed to write. Surfaces **Retry saving**, which is one of the
    /// few permitted retry triggers — ordinary topology events never retry disk cleanup.
    var hasPendingCleanupRetry: Bool

    init(
        availability: Availability = .loading,
        warnings: [AgentSessionOversightWarning] = [],
        hasPendingCleanupRetry: Bool = false
    ) {
        self.availability = availability
        self.warnings = warnings
        self.hasPendingCleanupRetry = hasPendingCleanupRetry
    }

    /// Neutral value for a process with no durable layer installed (focused tests, headless runs).
    ///
    /// Deliberately `.ready` rather than `.loading`: with no store there is nothing to wait for, and
    /// reporting “still loading” forever would disable Add in every context that never wanted
    /// persistence in the first place.
    static let noDurableLayer = AgentSessionOversightPersistencePresentation(availability: .ready)

    /// Why Add must stay disabled for persistence reasons, or `nil`.
    ///
    /// Composed ahead of live endpoint eligibility: a session that is perfectly eligible still cannot
    /// be granted oversight while the durable record cannot be written.
    var addBlockerMessage: String? {
        switch availability {
        case .loading:
            AgentSessionOversightPersistenceCopy.loading
        case .ready, .dormant:
            nil
        case .suppressed:
            AgentSessionOversightPersistenceCopy.suppressedLaunch
        case let .blocked(message):
            message
        }
    }

    /// Informational line rendered even when Add is permitted.
    var noticeMessage: String? {
        guard case .dormant = availability else { return nil }
        return AgentSessionOversightPersistenceCopy.autoRestoreDisabled
    }

    /// Appends a warning under the cap, collapsing an existing entry with the same identity.
    ///
    /// Returns `false` when nothing changed, so a caller can skip a broadcast that would repaint
    /// every window for an identical value.
    @discardableResult
    mutating func appendWarning(id: String, message: String) -> Bool {
        if let existing = warnings.first(where: { $0.id == id }), existing.message == message {
            return false
        }
        warnings.removeAll { $0.id == id }
        warnings.append(AgentSessionOversightWarning(id: id, message: message))
        if warnings.count > Self.maxWarnings {
            // Oldest first: the newest failure is the one the user is currently reacting to.
            warnings.removeFirst(warnings.count - Self.maxWarnings)
        }
        return true
    }

    @discardableResult
    mutating func dismissWarnings(ids: Set<String>) -> Bool {
        guard warnings.contains(where: { ids.contains($0.id) }) else { return false }
        warnings.removeAll { ids.contains($0.id) }
        return true
    }
}

/// Stable warning identities. Kept as an enum so the dedupe key can never drift from the copy.
enum AgentSessionOversightWarningID {
    static let quarantined = "oversight.persistence.quarantined"
    static let terminalRestoration = "oversight.persistence.terminalRestoration"
    static let cleanupFailed = "oversight.persistence.cleanupFailed"
    static let compensationFailed = "oversight.persistence.compensationFailed"
}

/// Outcome of stopping one oversight row.
///
/// Distinguishes "the link is gone" from "it was already gone" from "nothing changed, and here is
/// why": a Stop that could not commit its durable removal must never render as success, because the
/// link is still live and will still be restored next launch.
enum AgentMonitorStopOutcome: Equatable {
    case stopped
    case alreadyStopped
    case failed(message: String)

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

/// Copy and timing for the one-slot, time-bounded recovery offered after a successful Unlink.
///
/// Revocation is immediate and final: Undo runs the ordinary Add transaction and creates a *fresh*
/// link, so the copy never claims the removed grant came back.
enum AgentMonitorUnlinkUndo {
    /// Measured from successful Stop completion rather than from the click, so a slow durable
    /// removal cannot silently consume the user's recovery window.
    static let window: Duration = .seconds(8)

    enum Direction: Equatable {
        case outbound
        case inbound
    }

    static func message(direction: Direction, displayName: String) -> String {
        switch direction {
        case .outbound: "Oversight of \(displayName) was unlinked."
        case .inbound: "\(displayName) no longer oversees this session."
        }
    }

    static func undoAccessibilityLabel(direction: Direction, displayName: String) -> String {
        switch direction {
        case .outbound: "Undo unlinking oversight of \(displayName)"
        case .inbound: "Undo unlinking \(displayName) from overseeing this session"
        }
    }

    static let undoTooltip = """
    Creates a new oversight link between the same two sessions. Unread, cursor, delivery, and \
    Auto-wake lane state from the removed link do not come back.
    """
}

/// Outcome of the popover's resolve/add flow.
enum AgentMonitorAddOutcome: Equatable {
    case added(linkID: UUID, targetSessionID: UUID)
    /// The exact endpoint pair already has an active link; no second generation is created.
    case alreadyLinked(linkID: UUID, targetSessionID: UUID)
    case failed(AgentSessionLinkResolveFailure)
    /// The authority refused the reservation or activation for a non-resolution reason.
    case rejected(message: String)

    var failureMessage: String? {
        switch self {
        case .added, .alreadyLinked:
            nil
        case let .failed(failure):
            failure.uiMessage
        case let .rejected(message):
            message
        }
    }
}
