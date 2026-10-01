import Foundation

/// Per-window lifetime of accepted session-restore entries.
///
/// Every acceptance carries two independent obligations, and they must not be collapsed:
/// - **Execution** — a not-yet-dispatched entry plus the completion owed to its caller. It ends
///   exactly once: by dispatch (the completion then belongs to the dispatch task), by retirement
///   (explicit intent or close), or by displacement through a newer acceptance.
/// - **Protection** — the entry session capture preserves instead of a nil/System fallback. It is
///   armed at acceptance and released only by a real selection *published after* that acceptance,
///   by a newer acceptance, or by its own dispatch resolving to a System workspace. Retiring
///   execution never releases it: explicit intent wins over dispatch, not over the preserved
///   session identity.
///
/// Mutators return completions instead of invoking them so the owner installs the new state
/// before any reentrant caller observes it. Global persistence gating and explicit-close
/// exclusion stay with `WindowStatesManager`.
struct WindowRestoreLifetime {
    /// Acceptance sequence observed when a selection was published. Captured at publication,
    /// before any deferred delivery, so a late-delivered event cannot claim a newer acceptance.
    struct SelectionWitness {
        fileprivate let acceptanceSequence: UInt64
    }

    struct Dispatch {
        let entry: WindowSessionEntry
        let completion: (() -> Void)?
        let acceptanceSequence: UInt64
    }

    /// Classification of the window's authoritative live selection at capture time.
    enum LiveSelection {
        case none
        case ephemeral
        case system
        case persistent
    }

    enum CaptureDisposition {
        /// Leave the window out of the persisted session.
        case omit
        /// Persist the protected restore entry instead of the live fallback.
        case preserve(WindowSessionEntry)
        /// Persist the live selection.
        case captureLive
    }

    private struct Pending {
        let entry: WindowSessionEntry
        let completion: (() -> Void)?
        let acceptanceSequence: UInt64
    }

    private struct Protection {
        let entry: WindowSessionEntry
        let acceptanceSequence: UInt64
    }

    private var acceptanceSequence: UInt64 = 0
    private var pending: Pending?
    private var protection: Protection?

    var hasPendingEntry: Bool {
        pending != nil
    }

    var protectedEntry: WindowSessionEntry? {
        protection?.entry
    }

    var selectionWitness: SelectionWitness {
        SelectionWitness(acceptanceSequence: acceptanceSequence)
    }

    /// Accepts a non-ephemeral entry for execution and protection. Returns the displaced pending
    /// completion, which the caller must invoke after this returns; it is never dropped.
    mutating func accept(_ entry: WindowSessionEntry, completion: (() -> Void)?) -> (() -> Void)? {
        assert(!entry.isEphemeral, "Ephemeral entries are completed by the owner, never accepted")
        acceptanceSequence &+= 1
        let displaced = pending?.completion
        pending = Pending(entry: entry, completion: completion, acceptanceSequence: acceptanceSequence)
        // A System-intended entry needs no protection: its fallback and intended state coincide.
        protection = entry.isSystemWorkspace
            ? nil
            : Protection(entry: entry, acceptanceSequence: acceptanceSequence)
        return displaced
    }

    /// Ends execution without dispatch (explicit intent or close). Protection is unchanged.
    /// Returns the retired completion for the caller to invoke after this returns.
    mutating func retirePending() -> (() -> Void)? {
        guard let retired = pending else { return nil }
        pending = nil
        return retired.completion
    }

    /// Hands the pending entry and its completion to a dispatch. Protection is unchanged.
    mutating func takePendingForDispatch() -> Dispatch? {
        guard let taken = pending else { return nil }
        pending = nil
        return Dispatch(
            entry: taken.entry,
            completion: taken.completion,
            acceptanceSequence: taken.acceptanceSequence
        )
    }

    /// A real (non-System) selection was published. Releases protection only for acceptances
    /// that the selection's publication followed.
    mutating func noteRealSelectionPublished(_ witness: SelectionWitness) {
        guard let protection, protection.acceptanceSequence <= witness.acceptanceSequence else { return }
        self.protection = nil
    }

    /// The dispatched acceptance resolved to a System workspace, so there is nothing to protect.
    /// Never releases a newer acceptance's protection.
    mutating func releaseProtection(forDispatchedAcceptance sequence: UInt64) {
        guard protection?.acceptanceSequence == sequence else { return }
        protection = nil
    }

    /// Session capture policy. Ephemeral exclusion wins over protection; protection overrides
    /// only a missing or System live selection; a real persistent selection always captures live.
    func captureDisposition(for selection: LiveSelection) -> CaptureDisposition {
        switch selection {
        case .none:
            protection.map { .preserve($0.entry) } ?? .omit
        case .ephemeral:
            .omit
        case .system:
            protection.map { .preserve($0.entry) } ?? .captureLive
        case .persistent:
            .captureLive
        }
    }
}
