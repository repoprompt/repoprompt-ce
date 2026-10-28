import Foundation
import RepoPromptInstrumentation
import RepoPromptPersistence

// Durable oversight intents: directed relationships and, for derived exact-target links, the
// user-consent scope they depend on. This reference can restrict restoration, never invent authority.
//
// Owns the Codable document, the persistence mode, the runtime token that fences one load/mutate
// attempt, and the load/mutation contracts. `AgentSessionOversightLaunchCoordinator` replays these
// intents into live links once both endpoints are restoration-ready; `AgentSessionLinkRuntimeBridge`
// writes them on link creation and removal. Invariants: the durable payload carries no link IDs,
// generations, endpoint incarnations, or Auto-wake/snooze state — those are process-local and are
// re-derived on restore — and every mutation is token-fenced so a stale attempt cannot overwrite a
// newer document. Legacy delegation fields are ignored; live grants derive their capabilities from
// current authority defaults, never from UUID-keyed saved data.

// MARK: - Durable model

/// One directed overseer → overseen relationship the user explicitly created.
///
/// Together with the document version, this is the **entire** durable
/// payload. Link IDs, generations, endpoint incarnations, binding generations, reservations,
/// observations, cursors, waiters, prompt inventories, and delivery state stay process-local in
/// `DomainAgentSessionLinkAuthority` and are never written to disk.
struct AgentSessionOversightIntent: Codable, Hashable {
    let observerSessionID: UUID
    let targetSessionID: UUID
    let sourceScopeID: UUID?

    init(observerSessionID: UUID, targetSessionID: UUID, sourceScopeID: UUID? = nil) {
        self.observerSessionID = observerSessionID
        self.targetSessionID = targetSessionID
        self.sourceScopeID = sourceScopeID
    }

    /// The relationship is the row key. Consent provenance is immutable payload, not another pair.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.observerSessionID == rhs.observerSessionID && lhs.targetSessionID == rhs.targetSessionID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(observerSessionID)
        hasher.combine(targetSessionID)
    }

    /// A session can never oversee itself, so such a row is invalid by construction rather than
    /// merely unsatisfiable. Filtered on load and refused on insert.
    var isSelfPair: Bool {
        observerSessionID == targetSessionID
    }

    /// Canonical ordering for normalized writes: observer UUID, then target UUID.
    static func canonicallyOrdered(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.observerSessionID != rhs.observerSessionID {
            return lhs.observerSessionID.uuidString < rhs.observerSessionID.uuidString
        }
        return lhs.targetSessionID.uuidString < rhs.targetSessionID.uuidString
    }

    func touches(sessionID: UUID) -> Bool {
        observerSessionID == sessionID || targetSessionID == sessionID
    }
}

/// Versioned on-disk envelope. Swift's synthesized decoder ignores the legacy `delegations`
/// key while retaining the directed `links`, and every subsequent write omits that key.
struct AgentSessionOversightIntentDocument: Codable {
    static let currentVersion = 1

    let version: Int
    let links: [AgentSessionOversightIntent]

    init(version: Int = AgentSessionOversightIntentDocument.currentVersion, links: [AgentSessionOversightIntent]) {
        self.version = version
        self.links = links
    }
}

/// Just enough of the envelope to decide compatibility before decoding the body.
private struct AgentSessionOversightIntentDocumentHeader: Decodable {
    let version: Int
}

// MARK: - Launch policy

/// How this launch is allowed to interact with the durable oversight file.
///
/// Derived once in `AppLaunchConfiguration` so no call site infers it independently from a mix of
/// suppression flags and the auto-restore preference.
enum AgentSessionOversightPersistenceMode: Equatable {
    /// Read/write the production file and run a bounded automatic launch restore epoch.
    case enabled
    /// Read/write the production file, but start no automatic restore epoch. Saved intents stay
    /// dormant; explicit Add/Stop still work and still persist.
    case dormant
    /// Perform **no** production file I/O at all: no read, existence check, write, move, or
    /// quarantine. Deterministic UI-test and persistence-suppressed launches.
    case suppressed

    var performsProductionFileIO: Bool {
        self != .suppressed
    }

    var allowsAutomaticRestore: Bool {
        self == .enabled
    }
}

// MARK: - Runtime token

/// Process-local identity of one durable pair's current membership.
///
/// Never encoded. Loaded rows receive fresh tokens, and a remove/re-add cycle allocates a new one.
/// An idempotent re-add of an existing row deliberately reuses its token and advances the separate
/// assertion generation, so both stale-token and stale-same-token cleanup compare out safely.
struct AgentSessionOversightIntentToken: Hashable {
    /// Identifies the store instance that minted this token. A token from a previous store (or from
    /// a test's temporary store) can never match a current one.
    let storeProcessGeneration: UUID
    let pair: AgentSessionOversightIntent
    /// Monotonic per-store revision at mint time. Distinguishes token A from token B for the same
    /// pair after a remove/re-add cycle.
    let pairRevision: UInt64
}

// MARK: - Load contract

/// Why durable oversight state cannot currently be read or mutated.
///
/// Every case preserves the file on disk untouched. RepoPrompt never salvages part of a document,
/// truncates it, or evicts rows to fit a limit.
enum AgentSessionOversightPersistenceBlockReason: Equatable {
    /// The file was written by a newer RepoPrompt version.
    case unsupportedFutureSchema(onDiskVersion: Int, supportedVersion: Int)
    /// The file could not be read, or could not be backed up after failing to decode.
    case unreadable
    /// The file exceeds the defensive byte cap.
    case fileTooLarge(byteCount: Int)
    /// The document decoded but declares more rows than the defensive row cap.
    case tooManyRows(rowCount: Int)

    /// Enum-like label for diagnostics. Deliberately carries no byte counts, paths, or row contents.
    var diagnosticLabel: String {
        switch self {
        case .unsupportedFutureSchema: "future_schema"
        case .unreadable: "unreadable"
        case .fileTooLarge: "file_too_large"
        case .tooManyRows: "too_many_rows"
        }
    }
}

struct AgentSessionOversightIntentReadyLoad: Equatable {
    enum Source: String, Equatable {
        /// No file existed. The store starts empty and writable.
        case missing
        /// A supported document was read.
        case loaded
        /// A malformed supported-schema document was moved to `Backups/` intact; the store starts
        /// empty and writable.
        case quarantined
    }

    let source: Source
    let storeRevision: UInt64
    let tokenByPair: [AgentSessionOversightIntent: AgentSessionOversightIntentToken]

    var pairs: Set<AgentSessionOversightIntent> {
        Set(tokenByPair.keys)
    }
}

enum AgentSessionOversightIntentLoadResult: Equatable {
    case ready(AgentSessionOversightIntentReadyLoad)
    case blocked(AgentSessionOversightPersistenceBlockReason)
    case suppressed
}

// MARK: - Mutation contract

struct AgentSessionOversightIntentTokenTransition: Equatable {
    let pair: AgentSessionOversightIntent
    let before: AgentSessionOversightIntentToken?
    let after: AgentSessionOversightIntentToken?
}

/// One current row included in an atomic bulk-removal attempt.
///
/// Failed committed-deletion cleanup needs both values: the token qualifies the retry, while the
/// assertion generation prevents an older same-token owner from deleting a later explicit reassertion.
struct AgentSessionOversightIntentCurrentAttempt: Equatable {
    let token: AgentSessionOversightIntentToken
    let assertionGeneration: UInt64
}

/// Exact before/after report for one attempted mutation.
///
/// `outcome` describes the live intent decision; `saveState` describes continuity separately.
/// Only an acknowledged SQLite commit is durable, never the mere existence of a live token.
struct AgentSessionOversightIntentMutationReceipt: Equatable {
    enum Outcome: String, Equatable {
        /// The live intent changed; inspect saveState for its separate continuity result.
        case applied
        /// The requested state was already true. No write, no revision change, token preserved.
        case unchanged
        /// The pair is not present, so there was nothing to remove.
        case absent
        /// The pair is present under a **different** token. Nothing was removed.
        case tokenMismatch
        /// Persistence is unavailable in this launch, or the file is preserved/blocked.
        case blocked
        /// Encoding or atomic replacement failed. Old disk and memory state survive.
        case writeFailed
    }

    let outcome: Outcome
    let storeRevisionBefore: UInt64
    let storeRevisionAfter: UInt64
    let transitions: [AgentSessionOversightIntentTokenTransition]
    let wroteFile: Bool
    /// The pair's assertion generation after this mutation, for the single-pair operations that have
    /// one. Callers capture it and hand it back to `remove(_:ifCurrent:assertedAt:)`.
    var assertionGeneration: UInt64?
    /// Atomic snapshot of every current row a bulk removal attempted.
    ///
    /// Populated only when the bulk write is blocked or fails; `transitions` remains reserved for
    /// committed before/after changes.
    var attemptedCurrentByPair: [AgentSessionOversightIntent: AgentSessionOversightIntentCurrentAttempt] = [:]

    var operationID: UUID?
    var saveState: String = "saved"
    var saveError: String?

    var isDurable: Bool {
        (outcome == .applied || outcome == .unchanged) && saveState == "saved"
    }

    /// The token this pair holds after the mutation, when the mutation left one.
    func token(for pair: AgentSessionOversightIntent) -> AgentSessionOversightIntentToken? {
        transitions.first { $0.pair == pair }?.after
    }
}

// MARK: - Store

/// Process-local intent tokens and an asynchronous transactional continuity outbox.
/// Live user changes install before saving. A pending/failed save never masquerades as a durable
/// receipt; exact tokens and assertion generations still fence stale cleanup and reassertion.
actor AgentSessionOversightIntentStore {
    static let filename = "agentSessionOversightLinks.json"
    static let backupsDirectoryName = "Backups"
    static let maxFileByteCount = 16 * 1024 * 1024
    static let maxDecodedRowCount = 65536
    private let mode: AgentSessionOversightPersistenceMode
    private let repository: OverseerContinuityRepository
    private let beforeCommit: @Sendable () throws -> Void
    private let processGeneration: UUID
    private var tokenByPair: [AgentSessionOversightIntent: AgentSessionOversightIntentToken] = [:]
    private var assertions: [AgentSessionOversightIntent: UInt64] = [:]
    private var savedRevisions: [AgentSessionOversightIntent: Int64] = [:]
    private var localDecisions: Set<AgentSessionOversightIntent> = []
    private var storeRevision: UInt64 = 0
    private var didLoad = false
    private var lastFailure: String?
    private var recoveryWarning: String?
    private var rejectedOperations: [UUID: String] = [:]
    private struct Pending {
        let id: UUID
        let transitions: [AgentSessionOversightIntentTokenTransition]
        var mutations: [OverseerContinuityMutation]?
        var needsBaseline = false
    }

    private var pending: [Pending] = []
    private var saving: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var retryDelay: UInt64 = 1

    init(
        fileURL: URL,
        backupsDirectoryURL _: URL,
        mode: AgentSessionOversightPersistenceMode,
        fileManager _: FileManager = .default,
        beforeCommit: @escaping @Sendable () throws -> Void = {},
        now _: @escaping @Sendable () -> Date = { Date() },
        makeUUID _: @escaping @Sendable () -> UUID = { UUID() },
        storeProcessGeneration: UUID = UUID(),
        maxFileByteCount _: Int = maxFileByteCount,
        maxDecodedRowCount _: Int = maxDecodedRowCount,
        restorePerfRecorder _: any WorkspaceRestorePerfRecording = NoopWorkspaceRestorePerfRecorder(),
        databaseURL: URL? = nil,
        profile: String = "temporary-overseer",
        legacyPolicy: OverseerLegacyPolicy = .sameProfile
    ) {
        self.mode = mode
        self.beforeCommit = beforeCommit
        processGeneration = storeProcessGeneration
        repository = OverseerContinuityRepository(databaseURL: databaseURL ?? fileURL.deletingLastPathComponent().appendingPathComponent("Overseer/continuity.sqlite"), profile: profile, legacyURL: fileURL, kind: .link, mode: mode, legacyPolicy: legacyPolicy)
    }

    static func production(
        mode: AgentSessionOversightPersistenceMode,
        fileManager: FileManager = .default,
        restorePerfRecorder: any WorkspaceRestorePerfRecording = NoopWorkspaceRestorePerfRecorder()
    ) -> AgentSessionOversightIntentStore {
        let locations = OverseerContinuityRepository.production(fileManager: fileManager)
        return .init(
            fileURL: locations.legacyDirectory.appendingPathComponent(filename),
            backupsDirectoryURL: locations.legacyDirectory,
            mode: mode,
            restorePerfRecorder: restorePerfRecorder,
            databaseURL: locations.databaseURL,
            profile: locations.profile,
            legacyPolicy: locations.legacyFactsPolicy
        )
    }

    var persistenceMode: AgentSessionOversightPersistenceMode {
        mode
    }

    var diagnostic: String? {
        lastFailure ?? rejectedOperations.values.sorted().first ?? recoveryWarning ?? repository.diagnostic
    }

    var saveState: String {
        guard mode.performsProductionFileIO else { return "not_persisted" }
        return lastFailure != nil || !rejectedOperations.isEmpty ? "failed" : !pending.isEmpty ? "pending" : "saved"
    }

    func loadForLaunch() async -> AgentSessionOversightIntentLoadResult {
        guard mode.performsProductionFileIO else { return .suppressed }
        if !didLoad {
            do {
                let repository = repository
                let rows = try await Task.detached { try repository.load() }.value
                var invalidIDs: [String] = []
                let validated = rows.compactMap { row -> (OverseerContinuityRow, AgentSessionOversightIntent)? in
                    do {
                        let pair = try JSONDecoder().decode(AgentSessionOversightIntent.self, from: row.payload)
                        guard row.id == pair.continuityID, !pair.isSelfPair,
                              row.ownerID == pair.observerSessionID.uuidString, row.anchorID == pair.targetSessionID.uuidString else { throw OverseerContinuityError.invalidRecord }
                        return (row, pair)
                    } catch {
                        invalidIDs.append(row.id)
                        return nil
                    }
                }
                recoveryWarning = invalidIDs.isEmpty ? nil : "Invalid link entries remain preserved and inactive for recovery: \(invalidIDs.joined(separator: ", ")). Other valid rows restore normally."
                for (row, pair) in validated {
                    savedRevisions[pair] = max(savedRevisions[pair] ?? 0, row.revision)
                    if !localDecisions.contains(pair) {
                        if !row.terminal { tokenByPair[pair] = mint(pair) }
                    }
                }
                didLoad = true
                lastFailure = nil
            } catch {
                lastFailure = "Link continuity could not open (\(error)). Current explicit links remain usable in this process; saved links were preserved and saving will retry."
                scheduleRetry()
                return .blocked(.unreadable)
            }
        }
        return .ready(.init(source: tokenByPair.isEmpty ? .missing : .loaded, storeRevision: storeRevision, tokenByPair: tokenByPair))
    }

    func insert(_ pair: AgentSessionOversightIntent) async -> AgentSessionOversightIntentMutationReceipt {
        guard !pair.isSelfPair else { return receipt(.blocked, before: storeRevision, transitions: []) }
        let before = storeRevision
        let old = tokenByPair[pair]
        let sourceChanged = old.map { $0.pair.sourceScopeID != pair.sourceScopeID } ?? false
        storeRevision &+= 1
        let token = sourceChanged ? mint(pair) : old ?? mint(pair)
        if sourceChanged { tokenByPair.removeValue(forKey: pair) }
        tokenByPair[pair] = token
        localDecisions.insert(pair)
        assertions[pair, default: 0] &+= 1
        let transitions = [AgentSessionOversightIntentTokenTransition(pair: pair, before: old, after: token)]
        // A same-token reassertion changes only the process-local assertion fence. It must not
        // rewrite a saved row or generate save notifications on every reconciliation pass.
        let operation = old == nil || sourceChanged ? UUID() : nil
        if let operation {
            pending.append(.init(id: operation, transitions: transitions))
            startSaving()
        }
        var value = receipt(operation != nil ? .applied : .unchanged, before: before, transitions: transitions)
        value.assertionGeneration = assertions[pair]
        value.operationID = operation
        return value
    }

    func remove(
        _ pair: AgentSessionOversightIntent,
        ifCurrent token: AgentSessionOversightIntentToken,
        assertedAt generation: UInt64? = nil
    ) async -> AgentSessionOversightIntentMutationReceipt {
        let before = storeRevision
        guard let current = tokenByPair[pair] else { return receipt(.absent, before: before, transitions: []) }
        guard current == token, generation.map({ $0 == assertions[pair, default: 0] }) ?? true else {
            return receipt(.tokenMismatch, before: before, transitions: [.init(pair: pair, before: current, after: current)])
        }
        tokenByPair.removeValue(forKey: pair)
        localDecisions.insert(pair)
        storeRevision &+= 1
        let transitions = [AgentSessionOversightIntentTokenTransition(pair: pair, before: current, after: nil)]
        let operation = UUID()
        pending.append(.init(id: operation, transitions: transitions))
        startSaving()
        var value = receipt(.applied, before: before, transitions: transitions)
        value.operationID = operation
        return value
    }

    func removeAll(containing sessionID: UUID) async -> AgentSessionOversightIntentMutationReceipt {
        let before = storeRevision
        let transitions = tokenByPair.filter { $0.key.touches(sessionID: sessionID) }.map { AgentSessionOversightIntentTokenTransition(pair: $0.key, before: $0.value, after: nil) }
        guard !transitions.isEmpty else { return receipt(.unchanged, before: before, transitions: []) }
        for transition in transitions {
            tokenByPair.removeValue(forKey: transition.pair)
            localDecisions.insert(transition.pair)
        }
        storeRevision &+= 1
        let operation = UUID()
        pending.append(.init(id: operation, transitions: transitions))
        startSaving()
        var value = receipt(.applied, before: before, transitions: transitions)
        value.operationID = operation
        return value
    }

    private func receipt(
        _ outcome: AgentSessionOversightIntentMutationReceipt.Outcome,
        before: UInt64,
        transitions: [AgentSessionOversightIntentTokenTransition]
    ) -> AgentSessionOversightIntentMutationReceipt {
        var receipt = AgentSessionOversightIntentMutationReceipt(
            outcome: outcome,
            storeRevisionBefore: before,
            storeRevisionAfter: storeRevision,
            transitions: transitions,
            wroteFile: false
        )
        receipt.saveState = saveState
        receipt.saveError = diagnostic
        return receipt
    }

    private func startSaving() {
        guard mode.performsProductionFileIO, saving == nil, !pending.isEmpty else { return }
        postContinuityChange()
        saving = Task { [weak self] in
            guard let self else { return }
            await drain()
        }
    }

    private func flushAttempt() async {
        startSaving()
        await saving?.value
    }

    private func postContinuityChange() {
        Task { @MainActor in NotificationCenter.default.post(name: .agentOverseerContinuityDidChange, object: nil) }
    }

    private func drain() async {
        // Load/reconcile continuity off the live Add path, before capturing row revisions.
        if !didLoad { _ = await loadForLaunch() }
        defer { saving = nil
            postContinuityChange()
        }
        while !pending.isEmpty {
            do {
                if pending[0].needsBaseline, didLoad {
                    let operation = pending[0].id, database = repository.database
                    let prior = try await Task.detached { try database.receipt(operationID: operation) }.value
                    // A failed first open had no base revision. Reconcile only after proving that
                    // this operation did not commit; a lost acknowledgement must replay verbatim.
                    if prior == nil { pending[0].mutations = nil }
                    pending[0].needsBaseline = false
                }
                let mutations: [OverseerContinuityMutation]
                if let captured = pending[0].mutations { mutations = captured }
                else {
                    mutations = try pending[0].transitions.map { transition in
                        let pair = transition.pair
                        let expected = savedRevisions[pair]
                        if transition.after != nil {
                            return try .put(.init(
                                kind: .link,
                                id: pair.continuityID,
                                ownerID: pair.observerSessionID.uuidString,
                                anchorID: pair.targetSessionID.uuidString,
                                payload: JSONEncoder().encode(pair)
                            ), expectedRevision: expected)
                        }
                        if let expected { return .remove(kind: .link, id: pair.continuityID, expectedRevision: expected) }
                        // A remove before any successful save still records a terminal row.
                        return try .put(.init(
                            kind: .link,
                            id: pair.continuityID,
                            ownerID: pair.observerSessionID.uuidString,
                            anchorID: pair.targetSessionID.uuidString,
                            payload: JSONEncoder().encode(pair),
                            terminal: true
                        ), expectedRevision: nil)
                    }
                    pending[0].mutations = mutations
                    pending[0].needsBaseline = !didLoad
                }
                let operation = pending[0].id, repository = repository, hook = beforeCommit
                let committed = try await Task.detached {
                    try hook()
                    return try repository.commit(operationID: operation, mutations: mutations, origin: "live-link-owner")
                }.value
                for transition in pending[0].transitions {
                    savedRevisions[transition.pair] = max(savedRevisions[transition.pair] ?? 0, committed.revision)
                }
                pending.removeFirst()
                lastFailure = nil
                retryDelay = 1
            } catch {
                if let transition = error as? OverseerContinuityError, transition.isPermanentTransitionFailure {
                    let failed = pending.removeFirst()
                    rejectedOperations[failed.id] = "Link continuity operation \(failed.id) was rejected (\(transition)); it was not saved and will not be retried automatically. Inspect the conflicting/deleted saved identity before making a fresh link decision. Other saves continue."
                    lastFailure = nil
                    continue
                }
                lastFailure = "Link continuity save failed (\(error)). The live link decision still applies; it is not durably saved or shared. Saving will retry."
                scheduleRetry()
                break
            }
        }
    }

    private func scheduleRetry() {
        guard retry == nil, mode.performsProductionFileIO else { return }
        let delay = retryDelay
        retryDelay = min(30, delay * 2)
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            await self?.retrySaving()
        }
    }

    func retrySaving() async {
        retry = nil
        if !didLoad { _ = await loadForLaunch() }
        await flushAttempt()
    }

    private func mint(_ pair: AgentSessionOversightIntent) -> AgentSessionOversightIntentToken {
        .init(storeProcessGeneration: processGeneration, pair: pair, pairRevision: storeRevision)
    }

    func assertionGeneration(for pair: AgentSessionOversightIntent) -> UInt64 {
        assertions[pair, default: 0]
    }

    func allIntents() -> [AgentSessionOversightIntent] {
        tokenByPair.keys.sorted(by: AgentSessionOversightIntent.canonicallyOrdered)
    }

    func isCurrent(_ token: AgentSessionOversightIntentToken) -> Bool {
        tokenByPair[token.pair] == token
    }

    func token(for pair: AgentSessionOversightIntent) -> AgentSessionOversightIntentToken? {
        tokenByPair[pair]
    }

    var currentRevision: UInt64 {
        storeRevision
    }

    func serializationBarrier() async {
        await saving?.value
    }

    #if DEBUG
        /// Read-only test observation seam: the store's own task currently responsible for queued
        /// operations — the in-flight drain, or, while operations remain queued after a retryable
        /// failure, the scheduled retry. `nil` when nothing is queued or no attempt is scheduled.
        /// Starts, retries, and mutates nothing; `serializationBarrier` semantics are unchanged.
        var test_outboxProgressTask: Task<Void, Never>? {
            saving ?? (pending.isEmpty ? nil : retry)
        }
    #endif
}
