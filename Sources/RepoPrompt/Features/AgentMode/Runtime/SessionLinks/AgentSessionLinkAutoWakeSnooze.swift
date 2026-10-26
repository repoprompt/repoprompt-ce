import Foundation
import RepoPromptDomainRuntime

// The per-lane Auto-wake snooze vocabulary: constants, exact lane identity, records, projections,
// mutation outcomes, typed failures, the injected monotonic clock, and the pure retention rule.
//
// Everything here is a value; the records themselves live on `AgentTabSession.oversight` and are
// mutated only by `AgentModeViewModel+SessionLinkAutoWake`, which also owns the one deadline task.
// `AgentMonitorPillModels` and `AgentSessionLinkMCPToolService` render and accept these values
// without interpreting them. Invariants: a snooze is observer-local admission policy for routine
// status and overflow and nothing more — it never filters, receipts, or baselines the canonical
// queue, never touches link authority or durable selection, and never reads or notifies the target;
// an elapsed record is inactive whether or not bookkeeping has removed it; and every accepted
// set/extend leaves at most `maximumDurationSeconds` on the clock while never shortening a deadline.

// MARK: - Constants

/// Temporary, observer-local admission suppression for one exact Auto-wake lane.
///
/// A snooze is *policy*, never queue state: it decides only whether one concrete lane may
/// independently admit an automatic main-model call. Collection, first-to-final coalescing, natural
/// delivery, receipts, and link authority are untouched by everything in this file.
///
/// Nothing here is persisted. The records live beside the exact observer incarnation that created
/// them and die with it, so a rebind, relink, or relaunch always starts unsnoozed.
enum AgentSessionLinkAutoWakeSnooze {
    /// What a caller gets when it names no duration.
    static let defaultDurationSeconds = 600
    static let minimumDurationSeconds = 60
    /// The maximum *remaining horizon* one accepted operation may create, not a lifetime cap.
    ///
    /// Each accepted set/extend resolves to `max(activeDeadline, now + duration)`, so repeated
    /// operations may keep moving the deadline forward indefinitely while no single one of them ever
    /// leaves more than an hour on the clock.
    static let maximumDurationSeconds = 3600
    /// The fixed local menu offers, in ascending order. Presentation only; the authority is always
    /// the server-side `max(existingDeadline, now + duration)`.
    static let uiDurationSeconds = [600, 1200, 2400, 3600]

    /// Clamps any requested duration into the accepted range.
    ///
    /// Total rather than failable on purpose: wire-level range validation belongs to the MCP surface,
    /// and the monitor menu only ever offers `uiDurationSeconds`. Clamping here is what guarantees
    /// the per-operation horizon invariant for *every* caller, including a future one.
    static func clampedDurationSeconds(_ requested: Int) -> Int {
        min(maximumDurationSeconds, max(minimumDurationSeconds, requested))
    }

    /// The records one observer incarnation should keep: its own endpoint's, still active at `now`,
    /// and still naming a lane the current snapshot carries.
    ///
    /// Pure and non-mutating. It is the single retention rule behind every cleanup boundary —
    /// explicit mutation, deadline expiry, and membership pruning — so a stale or elapsed record can
    /// never survive one path and not another. `currentReferences == nil` means no snapshot is
    /// available, in which case membership is not a reason to drop anything.
    static func retainedRecords(
        _ records: [AgentSessionLinkAutoWakeSnoozeKey: AgentSessionLinkAutoWakeSnoozeRecord],
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        currentReferences: Set<DomainAgentSessionLinkReference>?,
        now: ContinuousClock.Instant
    ) -> [AgentSessionLinkAutoWakeSnoozeKey: AgentSessionLinkAutoWakeSnoozeRecord] {
        records.filter { key, record in
            key.observerEndpoint == observerEndpoint
                && record.isActive(at: now)
                && (currentReferences?.contains(key.reference) ?? true)
        }
    }
}

// MARK: - Identity

/// One exact snoozable lane: the observer incarnation that owns the policy plus the link generation
/// it applies to.
///
/// Both halves are load-bearing. A target session UUID alone is reused by unlink/relink, and an
/// in-place observer rebind keeps the `TabSession` while advancing the endpoint's generations — so
/// either half alone would let a replacement inherit a predecessor's suppression.
struct AgentSessionLinkAutoWakeSnoozeKey: Hashable {
    let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    let reference: DomainAgentSessionLinkReference
}

/// Who is responsible for the *current effective deadline*, which is not necessarily who created the
/// record: only an operation that moves the deadline later replaces the origin.
enum AgentSessionLinkAutoWakeSnoozeOrigin: String, Hashable, CaseIterable {
    case user
    case agent
}

enum AgentSessionLinkAutoWakeSnoozeCommand: Equatable {
    case set(durationSeconds: Int)
    case clear
}

/// One live suppression, held only in process memory and only on its owning session.
struct AgentSessionLinkAutoWakeSnoozeRecord: Equatable {
    let key: AgentSessionLinkAutoWakeSnoozeKey
    /// Monotonic by construction: a wall-clock adjustment can move the displayed expiry but can never
    /// change which lanes may admit a turn.
    var deadline: ContinuousClock.Instant
    var origin: AgentSessionLinkAutoWakeSnoozeOrigin

    /// An elapsed record is **inactive**, whether or not the deadline task has removed it yet.
    ///
    /// This is the whole answer to the expiry race: scheduling, readiness, final physical
    /// acquisition, overflow eligibility, and pure projection reads all ask this question rather than
    /// asking whether the dictionary still contains an entry.
    func isActive(at now: ContinuousClock.Instant) -> Bool {
        deadline > now
    }
}

// MARK: - Projection

/// A pure, observational rendering of one active record.
struct AgentSessionLinkAutoWakeSnoozeProjection: Equatable {
    /// Derived from wall time plus the *monotonic* remaining duration, so it is a display value
    /// rather than a stored deadline.
    let expiresAt: Date
    /// Rounded up to a whole second, and always within `1...maximumDurationSeconds`.
    let remainingSeconds: Int
    let origin: AgentSessionLinkAutoWakeSnoozeOrigin
}

/// The five outcomes a mutation can report. Raw values are the wire vocabulary, single-sourced here
/// so the MCP surface and the monitor cannot drift from the coordinator.
enum AgentSessionLinkAutoWakeSnoozeChange: String, Equatable, CaseIterable {
    case snoozed
    case extended
    case alreadySnoozed = "already_snoozed"
    case cleared
    case alreadyClear = "already_clear"
}

struct AgentSessionLinkAutoWakeSnoozeMutationOutcome: Equatable {
    let change: AgentSessionLinkAutoWakeSnoozeChange
    /// `nil` for `.cleared` and `.alreadyClear`.
    let projection: AgentSessionLinkAutoWakeSnoozeProjection?
    /// The current attempt already crossed the provider transport boundary.
    ///
    /// The mutation still succeeded: a set/extend applies to later automatic admission, and a clear
    /// cannot retract a call that may already be running.
    let currentDispatchAlreadyStarted: Bool
}

/// Typed failures, so callers never match on bridge strings.
enum AgentSessionLinkAutoWakeSnoozeFailure: String, Equatable, Error {
    case observerUnavailable = "observer_unavailable"
    case staleReference = "stale_reference"
    case laneNotEffectivelySelected = "lane_not_effectively_selected"
    case shuttingDown = "shutting_down"
}

// MARK: - Clock seam

/// The one monotonic seam every snooze decision reads.
///
/// Injected rather than called directly so the deadline task, the active predicate, and the
/// projection can all be driven deterministically in tests without a wall-clock sleep. Production
/// uses `ContinuousClock`, which cannot be moved backwards by a system clock adjustment.
struct AgentSessionLinkAutoWakeSnoozeClock {
    typealias Instant = ContinuousClock.Instant

    let now: @Sendable () -> Instant
    let wallNow: @Sendable () -> Date
    let sleepUntil: @Sendable (Instant) async throws -> Void

    static let continuous = AgentSessionLinkAutoWakeSnoozeClock(
        now: { ContinuousClock.now },
        wallNow: { Date() },
        sleepUntil: { try await Task.sleep(until: $0, clock: ContinuousClock()) }
    )
}

// MARK: - Pure derivation

extension AgentSessionLinkAutoWakeSnoozeProjection {
    /// Renders one record, or `nil` when it has already elapsed.
    ///
    /// Deliberately non-mutating: an elapsed record answers "no active snooze" here and is removed
    /// later by the deadline task or the next explicit cleanup boundary, never by a read.
    static func make(
        record: AgentSessionLinkAutoWakeSnoozeRecord?,
        now: ContinuousClock.Instant,
        wallNow: Date
    ) -> AgentSessionLinkAutoWakeSnoozeProjection? {
        guard let record, record.isActive(at: now) else { return nil }
        let remaining = now.duration(to: record.deadline)
        let components = remaining.components
        var seconds = Int(clamping: components.seconds)
        if components.attoseconds > 0 { seconds += 1 }
        seconds = min(
            AgentSessionLinkAutoWakeSnooze.maximumDurationSeconds,
            max(1, seconds)
        )
        return AgentSessionLinkAutoWakeSnoozeProjection(
            expiresAt: wallNow.addingTimeInterval(
                Double(components.seconds) + Double(components.attoseconds) / 1e18
            ),
            remainingSeconds: seconds,
            origin: record.origin
        )
    }
}
