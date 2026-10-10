import Foundation
import RepoPromptDomainRuntime

/// A request belongs to one live endpoint incarnation and one originating run attempt.
/// Persisting this identity is evidence for recovery, never authority to dispatch after restore.
struct AgentSelfCompactOwner: Codable, Equatable {
    let windowID: Int
    let workspaceID: UUID
    let tabID: UUID
    let sessionID: UUID
    let persistentBindingGeneration: UUID
    let bindingTransitionGeneration: UInt64
    let runID: UUID
    let runAttemptID: UUID

    @MainActor
    func matchesLocalBinding(_ session: AgentTabSession) -> Bool {
        session.tabID == tabID
            && session.persistentSessionBindingIdentity?.sessionID == sessionID
            && session.persistentSessionBindingIdentity?.generation == persistentBindingGeneration
            && session.bindingTransitionGeneration == bindingTransitionGeneration
            && !session.bindingTransitionInProgress
    }
}

struct AgentSelfCompactAttempt: Codable, Equatable {
    enum Phase: String, CaseIterable, Codable {
        case scheduled
        case compactDispatchPending
        case dispatchingCompact
        case awaitingCompactTurn
        case acpSettling
        case awaitingNoteBoundary
        case noteDispatchPending
        case dispatchingNote
        case parked
    }

    let id: UUID
    let idempotencyKey: String
    let noteDigest: String
    let note: String
    let owner: AgentSelfCompactOwner?
    let acceptedAt: Date
    var phase: Phase
    var compactDispatchStarted = false
    var admittedSupport: AgentSessionLinkCompactSupport?
    var compactProviderConversation: String?
    var noteDispatchStarted = false
    var noteWasPrepended: Bool?
    var compactRunID: UUID?
    var compactRunAttemptID: UUID?
    var compactTurnSucceeded: Bool?
    /// Vouched occupancy captured before the compact command withdrew it. Runtime evidence for an
    /// ACP drop check; a restored attempt never dispatches from this figure.
    var usedTokensBeforeCompact: Int?
    /// Set when compaction completion could not be verified: an ACP command turn that ended without
    /// a vouched drop, a native command that outlived its deadline, or runtime teardown before the
    /// command turn settled. The note stays parked until its live request confirms completion or
    /// ordinary input carries it. The persisted key predates the native cases.
    var acpCompletionUnverified: Bool?

    init(
        id: UUID = UUID(),
        idempotencyKey: String,
        note: String,
        owner: AgentSelfCompactOwner? = nil,
        acceptedAt: Date = Date(),
        phase: Phase = .scheduled
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        noteDigest = AgentSessionSelfCompactNotePolicy.digest(of: note)
        self.note = note
        self.owner = owner
        self.acceptedAt = acceptedAt
        self.phase = phase
    }

    /// A timeout releases the hold, not the request's ability to accept correlated confirmation.
    /// The live completion coordinator separately fences parked requests by its runtime binding.
    var canAcceptCompactConfirmation: Bool {
        guard !noteDispatchStarted else { return false }
        switch phase {
        case .dispatchingCompact, .awaitingCompactTurn:
            return true
        case .parked:
            return acpCompletionUnverified == true
        default:
            return false
        }
    }

    var isValid: Bool {
        guard case .valid = AgentSessionSelfCompactNotePolicy.validation(of: note) else { return false }
        return AgentSessionSelfCompactNotePolicy.idempotencyKeyIsValid(idempotencyKey)
            && noteDigest == AgentSessionSelfCompactNotePolicy.digest(of: note)
    }
}

struct AgentSelfCompactSettlement: Codable, Equatable {
    enum Outcome: String, Codable {
        case noteAccepted
        case cancelled
        case failed
        case completionUnverified
        case deliveryUnknown
        case recoveryRequired
    }

    enum NoteDelivery: String, Codable {
        case accepted
        case deliveryUnknown
        case notSent
        case parked
        case prepended
    }

    let requestID: UUID?
    let idempotencyKey: String?
    let noteDigest: String?
    let outcome: Outcome
    let noteDelivery: NoteDelivery
    let completionVerified: Bool
    let settledAt: Date
    /// Present when explicit recovery is needed; never stored in a system-row text.
    let recoveryNote: String?

    static func recoveryRequired(from attempt: AgentSelfCompactAttempt, at date: Date = Date()) -> Self {
        // The dispatching phase is durably saved before transport, but the later attempted
        // marker is debounced. A crash after provider acceptance can restore that older record.
        let delivery: NoteDelivery = if attempt.noteDispatchStarted
            || attempt.phase == .dispatchingNote || attempt.phase == .parked
        {
            // An ordinary send can accept a parked note before its debounced attempt marker
            // or settlement is saved. The old parked snapshot cannot prove non-delivery.
            .deliveryUnknown
        } else {
            .notSent
        }
        return Self(
            requestID: attempt.id,
            idempotencyKey: attempt.idempotencyKey,
            noteDigest: attempt.noteDigest,
            outcome: .recoveryRequired,
            noteDelivery: delivery,
            completionVerified: false,
            settledAt: date,
            recoveryNote: attempt.note
        )
    }

    static func malformedRecovery(at date: Date = Date()) -> Self {
        Self(
            requestID: nil,
            idempotencyKey: nil,
            noteDigest: nil,
            outcome: .recoveryRequired,
            noteDelivery: .notSent,
            completionVerified: false,
            settledAt: date,
            recoveryNote: nil
        )
    }

    var isValid: Bool {
        if let idempotencyKey {
            guard requestID != nil,
                  AgentSessionSelfCompactNotePolicy.idempotencyKeyIsValid(idempotencyKey),
                  let noteDigest, noteDigest.count == 64
            else { return false }
        }
        guard let recoveryNote else { return true }
        guard case .valid = AgentSessionSelfCompactNotePolicy.validation(of: recoveryNote) else { return false }
        return noteDigest == nil || noteDigest == AgentSessionSelfCompactNotePolicy.digest(of: recoveryNote)
    }
}

/// At most one active request and one latest settlement. Older keys may be reused by design.
struct AgentSelfCompactState: Codable, Equatable {
    static let currentVersion = 1
    private var version = currentVersion

    enum Reservation: Equatable {
        case scheduled(AgentSelfCompactAttempt)
        case duplicate(UUID)
        case conflict
        case alreadyPending
        case invalidNote(AgentSessionSelfCompactNotePolicy.Validation)
        case invalidIdempotencyKey
    }

    var active: AgentSelfCompactAttempt?
    var latest: AgentSelfCompactSettlement?

    init(active: AgentSelfCompactAttempt? = nil, latest: AgentSelfCompactSettlement? = nil) {
        self.active = active
        self.latest = latest
    }

    enum CodingKeys: String, CodingKey {
        case version
        case active
        case latest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unknown self-compaction state version"
            )
        }
        active = try container.decodeIfPresent(AgentSelfCompactAttempt.self, forKey: .active)
        latest = try container.decodeIfPresent(AgentSelfCompactSettlement.self, forKey: .latest)
        guard active != nil || latest != nil,
              active?.isValid != false,
              latest?.isValid != false
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid self-compaction record")
            )
        }
    }

    mutating func reserve(
        note: String,
        idempotencyKey: String,
        owner: AgentSelfCompactOwner? = nil,
        at date: Date = Date()
    ) -> Reservation {
        let validation = AgentSessionSelfCompactNotePolicy.validation(of: note)
        guard case .valid = validation else { return .invalidNote(validation) }
        guard AgentSessionSelfCompactNotePolicy.idempotencyKeyIsValid(idempotencyKey) else {
            return .invalidIdempotencyKey
        }
        let digest = AgentSessionSelfCompactNotePolicy.digest(of: note)
        if let active {
            if active.idempotencyKey == idempotencyKey {
                return active.noteDigest == digest ? .duplicate(active.id) : .conflict
            }
            return .alreadyPending
        }
        if let latest, latest.idempotencyKey == idempotencyKey {
            guard latest.noteDigest == digest, let requestID = latest.requestID else { return .conflict }
            return .duplicate(requestID)
        }
        let attempt = AgentSelfCompactAttempt(
            idempotencyKey: idempotencyKey,
            note: note,
            owner: owner,
            acceptedAt: date
        )
        active = attempt
        return .scheduled(attempt)
    }

    /// Binds the command before its provider RPC. A completion may arrive before the RPC returns.
    mutating func bindCompactRun(_ dispatchID: AgentSelfCompactionDispatchID, runID: UUID?, attemptID: UUID?) -> Bool {
        guard dispatchID.stage == .compact,
              active?.id == dispatchID.requestID,
              active?.phase == .dispatchingCompact || active?.phase == .awaitingCompactTurn,
              let runID, let attemptID
        else { return false }
        active?.compactRunID = runID
        active?.compactRunAttemptID = attemptID
        return true
    }

    mutating func noteWillAttempt(_ dispatchID: AgentSelfCompactionDispatchID) -> Bool {
        guard dispatchID.stage == .note,
              active?.id == dispatchID.requestID,
              active?.phase == .dispatchingNote || active?.phase == .parked,
              active?.noteDispatchStarted == false
        else { return false }
        let wasParked = active?.phase == .parked
        active?.phase = .dispatchingNote
        active?.noteDispatchStarted = true
        active?.noteWasPrepended = wasParked
        return true
    }

    mutating func noteAccepted(_ dispatchID: AgentSelfCompactionDispatchID) -> Bool {
        guard dispatchID.stage == .note,
              active?.id == dispatchID.requestID,
              active?.phase == .dispatchingNote,
              active?.noteDispatchStarted == true
        else { return false }
        let unverified = active?.acpCompletionUnverified == true
        settle(
            unverified ? .completionUnverified : .noteAccepted,
            noteDelivery: active?.noteWasPrepended == true ? .prepended : .accepted,
            completionVerified: unverified ? false : active?.compactTurnSucceeded == true
        )
        return true
    }

    mutating func noteDefinitivelyNotAttempted(_ dispatchID: AgentSelfCompactionDispatchID) -> Bool {
        guard dispatchID.stage == .note,
              active?.id == dispatchID.requestID,
              active?.phase == .dispatchingNote
        else { return false }
        active?.phase = .parked
        active?.noteDispatchStarted = false
        return true
    }

    mutating func noteTransportFailed(_ dispatchID: AgentSelfCompactionDispatchID) -> Bool {
        guard dispatchID.stage == .note,
              active?.id == dispatchID.requestID,
              active?.phase == .dispatchingNote
        else { return false }
        if active?.noteDispatchStarted == true {
            settle(
                .deliveryUnknown, noteDelivery: .deliveryUnknown,
                completionVerified: active?.acpCompletionUnverified != true && active?.compactTurnSucceeded == true
            )
        } else {
            active?.phase = .parked
        }
        return true
    }

    mutating func settle(
        _ outcome: AgentSelfCompactSettlement.Outcome,
        noteDelivery: AgentSelfCompactSettlement.NoteDelivery,
        completionVerified: Bool,
        at date: Date = Date()
    ) {
        guard let active else { return }
        latest = AgentSelfCompactSettlement(
            requestID: active.id,
            idempotencyKey: active.idempotencyKey,
            noteDigest: active.noteDigest,
            outcome: outcome,
            noteDelivery: noteDelivery,
            completionVerified: completionVerified,
            settledAt: date,
            recoveryNote: outcome == .noteAccepted ? nil : active.note
        )
        self.active = nil
    }

    /// Every persisted phase, including parked, is inert once decoded. This runs on every decode of
    /// a session record, including an in-process reload, not only on a cold launch: a decoded record
    /// has no live worker, so it is never authority to resume dispatch.
    @discardableResult
    mutating func reconcileDecodedRecord(at date: Date = Date()) -> Bool {
        guard let active else { return false }
        latest = .recoveryRequired(from: active, at: date)
        self.active = nil
        return true
    }

    /// A parked note belongs to its old incarnation, never to a rebound replacement tab.
    @MainActor
    mutating func cancelStaleParkedNote(for session: AgentTabSession) -> Bool {
        guard let attempt = active, attempt.phase == .parked,
              let owner = attempt.owner, !owner.matchesLocalBinding(session)
        else { return false }
        settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
        return true
    }

    /// Runtime teardown drops the completion worker. Release every hold that only that worker could
    /// settle: a request that never reached the provider is cancelled, and an unsent note after a
    /// started compact command is parked for the next ordinary send (unverified unless the command
    /// turn was already proven). A note whose physical send already started is left to its sender,
    /// which always settles it on acceptance or transport failure.
    @discardableResult
    mutating func releaseForRuntimeTeardown() -> Bool {
        guard let attempt = active, !attempt.noteDispatchStarted else { return false }
        switch attempt.phase {
        case .parked:
            return false
        case .scheduled, .compactDispatchPending:
            settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
        case .dispatchingCompact, .awaitingCompactTurn, .acpSettling,
             .awaitingNoteBoundary, .noteDispatchPending, .dispatchingNote:
            if attempt.compactTurnSucceeded != true || attempt.acpCompletionUnverified == true {
                active?.acpCompletionUnverified = true
            }
            active?.phase = .parked
        }
        return true
    }

    /// Managed Stop yields to the self-compaction hold only while RepoPrompt itself owns an unsent
    /// provider dispatch. The originating turn (`scheduled`) is the caller's own work, and a stop
    /// ending it non-completed already cancels the request; a parked note or a note whose send has
    /// started is ordinary provider work that Stop must be able to end.
    var blocksManagedStop: Bool {
        guard let active else { return false }
        switch active.phase {
        case .scheduled, .parked:
            return false
        case .dispatchingNote:
            return !active.noteDispatchStarted
        case .compactDispatchPending, .dispatchingCompact, .awaitingCompactTurn, .acpSettling,
             .awaitingNoteBoundary, .noteDispatchPending:
            return true
        }
    }

    /// Overseer delivery stays blocked while compaction or its settle hold owns the next input.
    /// A parked note does not: the next ordinary send carries it.
    var blocksOverseerDelivery: Bool {
        guard let phase = active?.phase else { return false }
        return phase != .parked
    }

    /// Periodic wakes stay blocked for every live attempt. Notification wakes may carry a verified,
    /// unattempted parked note after the app-side owner fence has been checked.
    var blocksAutomaticWake: Bool {
        active != nil
    }

    /// Runtime evidence only: decoded attempts are reconciled to inert recovery before admission.
    var verifiedParkedNoteOwner: AgentSelfCompactOwner? {
        guard let attempt = active, attempt.phase == .parked,
              attempt.compactTurnSucceeded == true, attempt.acpCompletionUnverified != true,
              !attempt.noteDispatchStarted
        else { return nil }
        return attempt.owner
    }

    /// Reading the frame does not consume it; only final provider acknowledgment can do that.
    var parkedNote: (dispatchID: AgentSelfCompactionDispatchID, frame: String)? {
        guard let attempt = active, attempt.phase == .parked, !attempt.noteDispatchStarted else { return nil }
        return (.init(requestID: attempt.id, stage: .note), AgentSelfCompactNoteEnvelope.frame(attempt.note))
    }

    var status: AgentSelfCompactStatus? {
        if let active {
            let unverified = active.acpCompletionUnverified == true && active.phase == .parked
            return AgentSelfCompactStatus(
                requestID: active.id,
                phase: active.phase.rawValue,
                outcome: unverified ? .completionUnverified : nil,
                completionVerified: unverified ? false : nil,
                noteDelivery: active.phase == .parked ? .parked : nil,
                recoveryNote: unverified ? active.note : nil
            )
        }
        guard let latest else { return nil }
        return AgentSelfCompactStatus(
            requestID: latest.requestID,
            phase: nil,
            outcome: latest.outcome,
            completionVerified: latest.completionVerified,
            noteDelivery: latest.noteDelivery,
            recoveryNote: latest.recoveryNote
        )
    }
}

/// A stable context response model; the load itself remains the existing poll value.
struct AgentSelfContextSnapshot {
    let context: DomainAgentSessionContextLoad?
    let selfCompact: AgentSelfCompactStatus?
}

struct AgentSelfCompactStatus: Equatable {
    let requestID: UUID?
    let phase: String?
    let outcome: AgentSelfCompactSettlement.Outcome?
    let completionVerified: Bool?
    let noteDelivery: AgentSelfCompactSettlement.NoteDelivery?
    let recoveryNote: String?
}
