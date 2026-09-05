import Foundation

// Durable oversight intents: the user's directed overseer → overseen relationships and nothing else.
//
// Owns the Codable document, the persistence mode, the runtime token that fences one load/mutate
// attempt, and the load/mutation contracts. `AgentSessionOversightLaunchCoordinator` replays these
// intents into live links once both endpoints are restoration-ready; `AgentSessionLinkRuntimeBridge`
// writes them on link creation and removal. Invariants: the durable payload carries no link IDs,
// generations, endpoint incarnations, or Auto-wake/snooze state — those are process-local and are
// re-derived on restore — and every mutation is token-fenced so a stale attempt cannot overwrite a
// newer document.

// MARK: - Durable model

/// One directed overseer → overseen relationship the user explicitly created.
///
/// This is the **entire** durable payload. Link IDs, generations, endpoint incarnations, binding
/// generations, capabilities, reservations, observations, cursors, waiters, prompt inventories, and
/// delivery state stay process-local in `DomainAgentSessionLinkAuthority` and are never written to
/// disk: a persisted grant would be an authorization this process never re-derived.
struct AgentSessionOversightIntent: Codable, Hashable {
    let observerSessionID: UUID
    let targetSessionID: UUID

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

/// Versioned on-disk envelope. Version 1 carries only the directed UUID pairs.
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
/// Blocked and write-failed mutations leave tokens, revision, and disk untouched, so a caller can
/// always distinguish "the intent is durable" from "the action reported success but nothing was
/// written".
struct AgentSessionOversightIntentMutationReceipt: Equatable {
    enum Outcome: String, Equatable {
        /// Disk and memory changed.
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

    var isDurable: Bool {
        outcome == .applied || outcome == .unchanged
    }

    /// The token this pair holds after the mutation, when the mutation left one.
    func token(for pair: AgentSessionOversightIntent) -> AgentSessionOversightIntentToken? {
        transitions.first { $0.pair == pair }?.after
    }
}

// MARK: - Store

/// Atomic, versioned store for durable oversight intent.
///
/// One actor serializes every operation. Each mutation encodes, atomically replaces the file, and
/// commits its in-memory set/revision/tokens with **no suspension point between disk replacement
/// and memory commit** — so a cancelled caller can never leave the two disagreeing.
///
/// Beside `windowSessions.json`:
/// `~/Library/Application Support/RepoPrompt CE/agentSessionOversightLinks.json`
actor AgentSessionOversightIntentStore {
    static let filename = "agentSessionOversightLinks.json"
    static let backupsDirectoryName = "Backups"
    /// Defensive guards. Exceeding either preserves the file and blocks mutation; the store never
    /// salvages partially, silently truncates, or evicts rows.
    static let maxFileByteCount = 16 * 1024 * 1024
    static let maxDecodedRowCount = 65536
    private static let maxQuarantineAttempts = 4

    private let fileURL: URL
    private let backupsDirectoryURL: URL
    private let mode: AgentSessionOversightPersistenceMode
    /// Instance copies of the defensive guards. Production always uses the static defaults; the
    /// injection point exists so the preserve-and-block behaviour at each limit can be proved without
    /// materializing 65,536 rows or a 16 MiB document in a unit test.
    private let maxFileByteCount: Int
    private let maxDecodedRowCount: Int
    private let fileManager: FileManager
    private let writer: @Sendable (Data, URL) throws -> Void
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID
    private let storeProcessGeneration: UUID

    private var didLoad = false
    /// How this launch's one and only read classified the file. Retained so a later caller is told
    /// the *settled* answer — a quarantine or a missing file is a fact about this launch that the
    /// presentation surface still has to be able to report after Add or Stop has also loaded.
    private var settledSource: AgentSessionOversightIntentReadyLoad.Source?
    private var blockReason: AgentSessionOversightPersistenceBlockReason?
    private var tokenByPair: [AgentSessionOversightIntent: AgentSessionOversightIntentToken] = [:]
    /// How many times each pair has been *asserted* in this process. Monotonic and never reset, not
    /// even by a removal.
    ///
    /// The durable token deliberately survives a re-add — an existing row keeps its identity so an
    /// explicit Add of a launch-loaded pair joins it instead of superseding it — which is exactly why
    /// the token alone cannot tell "the intent my revocation belonged to" apart from "the intent the
    /// user reasserted while I was suspended on an authority hop". This counter can, and it is
    /// compared inside the actor, so no assertion can slip between a caller's check and its write.
    private var assertionGenerationByPair: [AgentSessionOversightIntent: UInt64] = [:]
    private var storeRevision: UInt64 = 0

    init(
        fileURL: URL,
        backupsDirectoryURL: URL,
        mode: AgentSessionOversightPersistenceMode,
        fileManager: FileManager = .default,
        writer: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        },
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        storeProcessGeneration: UUID = UUID(),
        maxFileByteCount: Int = AgentSessionOversightIntentStore.maxFileByteCount,
        maxDecodedRowCount: Int = AgentSessionOversightIntentStore.maxDecodedRowCount
    ) {
        self.fileURL = fileURL
        self.backupsDirectoryURL = backupsDirectoryURL
        self.mode = mode
        self.maxFileByteCount = maxFileByteCount
        self.maxDecodedRowCount = maxDecodedRowCount
        self.fileManager = fileManager
        self.writer = writer
        self.now = now
        self.makeUUID = makeUUID
        self.storeProcessGeneration = storeProcessGeneration
    }

    /// Production location, beside `windowSessions.json`.
    static func production(
        mode: AgentSessionOversightPersistenceMode,
        fileManager: FileManager = .default
    ) -> AgentSessionOversightIntentStore {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
        return AgentSessionOversightIntentStore(
            fileURL: base.appendingPathComponent(filename),
            backupsDirectoryURL: base.appendingPathComponent(backupsDirectoryName, isDirectory: true),
            mode: mode,
            fileManager: fileManager
        )
    }

    var persistenceMode: AgentSessionOversightPersistenceMode {
        mode
    }

    // MARK: - Load

    /// Reads the file once for this launch and classifies the result.
    ///
    /// Repeat calls report the settled state rather than re-reading: the launch coordinator, an
    /// explicit Add, and a presentation refresh must all observe the same classification.
    func loadForLaunch() -> AgentSessionOversightIntentLoadResult {
        let result = performLoadForLaunch()
        #if DEBUG
            logLaunchClassificationOnce(result)
        #endif
        return result
    }

    private func performLoadForLaunch() -> AgentSessionOversightIntentLoadResult {
        guard mode.performsProductionFileIO else { return .suppressed }
        if didLoad {
            if let blockReason { return .blocked(blockReason) }
            return .ready(readyLoad(source: settledSource ?? .loaded))
        }
        didLoad = true

        let data: Data
        switch readFile() {
        case .missing:
            return .ready(readyLoad(source: .missing))
        case let .blocked(reason):
            blockReason = reason
            return .blocked(reason)
        case let .data(value):
            data = value
        }

        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(AgentSessionOversightIntentDocumentHeader.self, from: data) else {
            // Malformed but nominally ours: preserve the bytes intact, then start empty/writable.
            return quarantineAndStartEmpty()
        }
        guard header.version <= AgentSessionOversightIntentDocument.currentVersion else {
            let reason = AgentSessionOversightPersistenceBlockReason.unsupportedFutureSchema(
                onDiskVersion: header.version,
                supportedVersion: AgentSessionOversightIntentDocument.currentVersion
            )
            blockReason = reason
            return .blocked(reason)
        }
        guard let document = try? decoder.decode(AgentSessionOversightIntentDocument.self, from: data) else {
            return quarantineAndStartEmpty()
        }
        guard document.links.count <= maxDecodedRowCount else {
            let reason = AgentSessionOversightPersistenceBlockReason.tooManyRows(rowCount: document.links.count)
            blockReason = reason
            return .blocked(reason)
        }

        // Normalization is in-memory only: a load never writes. Self-pairs are dropped because they
        // can never be granted, and duplicates collapse onto one token.
        for pair in document.links where !pair.isSelfPair {
            guard tokenByPair[pair] == nil else { continue }
            tokenByPair[pair] = mintToken(for: pair)
        }
        return .ready(readyLoad(source: .loaded))
    }

    private enum FileRead {
        case missing
        case data(Data)
        case blocked(AgentSessionOversightPersistenceBlockReason)
    }

    private func readFile() -> FileRead {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        if let size = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber,
           size.intValue > maxFileByteCount
        {
            return .blocked(.fileTooLarge(byteCount: size.intValue))
        }
        guard let data = try? Data(contentsOf: fileURL) else { return .blocked(.unreadable) }
        guard data.count <= maxFileByteCount else {
            return .blocked(.fileTooLarge(byteCount: data.count))
        }
        return .data(data)
    }

    /// Moves the intact source aside with no-replace semantics, then starts empty and writable.
    ///
    /// A collision retries under a fresh UUID rather than overwriting an earlier backup. If the file
    /// cannot be moved at all it is preserved where it is and mutation stays blocked, because
    /// starting empty over an unreadable file we could not back up would silently destroy the user's
    /// saved links on the next write.
    private func quarantineAndStartEmpty() -> AgentSessionOversightIntentLoadResult {
        try? fileManager.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        let stamp = Self.utcStamp(now())
        for _ in 0 ..< Self.maxQuarantineAttempts {
            let destination = backupsDirectoryURL.appendingPathComponent(
                "agentSessionOversightLinks.corrupt.\(stamp).\(makeUUID().uuidString).json"
            )
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.moveItem(at: fileURL, to: destination)
                return .ready(readyLoad(source: .quarantined))
            } catch {
                guard !fileManager.fileExists(atPath: fileURL.path) else { continue }
                break
            }
        }
        blockReason = .unreadable
        return .blocked(.unreadable)
    }

    private func readyLoad(source: AgentSessionOversightIntentReadyLoad.Source) -> AgentSessionOversightIntentReadyLoad {
        settledSource = source
        return AgentSessionOversightIntentReadyLoad(
            source: source,
            storeRevision: storeRevision,
            tokenByPair: tokenByPair
        )
    }

    /// Filename-safe UTC stamp. Built per call rather than from a cached formatter: `DateFormatter`
    /// is not `Sendable`, and quarantine is a once-per-launch path where allocation is irrelevant.
    private static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    // MARK: - Mutation

    /// Idempotent insert. An already-present pair keeps its token and writes nothing, so a manual
    /// Add of a launch-loaded pair joins the existing token instead of superseding it.
    func insert(_ pair: AgentSessionOversightIntent) -> AgentSessionOversightIntentMutationReceipt {
        logged("insert", performInsert(pair))
    }

    private func performInsert(_ pair: AgentSessionOversightIntent) -> AgentSessionOversightIntentMutationReceipt {
        guard mutationIsAdmitted, !pair.isSelfPair else { return blockedReceipt() }
        if let existing = tokenByPair[pair] {
            // An idempotent insert writes nothing and bumps no store revision, but it *is* a fresh
            // assertion of the pair: it is the moment a user reasserts a relationship some suspended
            // lifecycle owner is still about to clean up under the very same token.
            let generation = bumpAssertionGeneration(for: pair)
            return AgentSessionOversightIntentMutationReceipt(
                outcome: .unchanged,
                storeRevisionBefore: storeRevision,
                storeRevisionAfter: storeRevision,
                transitions: [.init(pair: pair, before: existing, after: existing)],
                wroteFile: false,
                assertionGeneration: generation
            )
        }
        var replacement = tokenByPair
        replacement[pair] = mintToken(for: pair, revision: storeRevision &+ 1)
        var receipt = commit(
            pairs: Set(replacement.keys),
            revisionBefore: storeRevision,
            transitions: [.init(pair: pair, before: nil, after: replacement[pair])],
            apply: { [self] in
                tokenByPair = replacement
            }
        )
        // Only a committed insert counts as an assertion: a refused one asserted nothing.
        if receipt.outcome == .applied {
            receipt.assertionGeneration = bumpAssertionGeneration(for: pair)
        }
        return receipt
    }

    /// Monotonic per pair, and never cleared — including by removal.
    ///
    /// Resetting on removal would let a remove/re-add cycle land back on a generation some stale
    /// owner is still holding, which is the exact comparison this counter exists to fail.
    private func bumpAssertionGeneration(for pair: AgentSessionOversightIntent) -> UInt64 {
        let next = (assertionGenerationByPair[pair] ?? 0) &+ 1
        assertionGenerationByPair[pair] = next
        return next
    }

    /// The pair's current assertion generation. Launch-loaded rows start at zero: they were restored,
    /// not asserted by anyone in this process.
    func assertionGeneration(for pair: AgentSessionOversightIntent) -> UInt64 {
        assertionGenerationByPair[pair] ?? 0
    }

    /// Expected-token removal. This is the **only** removal a compensation, lifecycle cleanup, or
    /// notice may use: a stale token can never delete the intent a newer re-add reasserted.
    ///
    /// - Parameter assertedAt: the pair's assertion generation the caller last owned, or `nil` for a
    ///   caller that owns the pair lane for the whole removal and therefore cannot be raced. A stale
    ///   generation reports `.tokenMismatch` and writes nothing — the token is deliberately *not*
    ///   enough on its own, because an idempotent re-add reuses it.
    func remove(
        _ pair: AgentSessionOversightIntent,
        ifCurrent token: AgentSessionOversightIntentToken,
        assertedAt generation: UInt64? = nil
    ) -> AgentSessionOversightIntentMutationReceipt {
        logged("remove", performRemove(pair, ifCurrent: token, assertedAt: generation))
    }

    private func performRemove(
        _ pair: AgentSessionOversightIntent,
        ifCurrent token: AgentSessionOversightIntentToken,
        assertedAt generation: UInt64?
    ) -> AgentSessionOversightIntentMutationReceipt {
        guard mutationIsAdmitted else { return blockedReceipt() }
        guard let current = tokenByPair[pair] else {
            return AgentSessionOversightIntentMutationReceipt(
                outcome: .absent,
                storeRevisionBefore: storeRevision,
                storeRevisionAfter: storeRevision,
                transitions: [],
                wroteFile: false,
                assertionGeneration: assertionGeneration(for: pair)
            )
        }
        let currentGeneration = assertionGeneration(for: pair)
        guard current == token, generation.map({ $0 == currentGeneration }) ?? true else {
            return AgentSessionOversightIntentMutationReceipt(
                outcome: .tokenMismatch,
                storeRevisionBefore: storeRevision,
                storeRevisionAfter: storeRevision,
                transitions: [.init(pair: pair, before: current, after: current)],
                wroteFile: false,
                assertionGeneration: currentGeneration
            )
        }
        var remaining = tokenByPair
        remaining.removeValue(forKey: pair)
        return commit(
            pairs: Set(remaining.keys),
            revisionBefore: storeRevision,
            transitions: [.init(pair: pair, before: current, after: nil)],
            apply: { [self] in
                tokenByPair = remaining
            }
        )
    }

    /// Removes every intent touching one session. Used only when the session itself is known to be
    /// gone process-wide (a committed deletion), never for tab teardown or rebinding.
    func removeAll(containing sessionID: UUID) -> AgentSessionOversightIntentMutationReceipt {
        logged("remove_all", performRemoveAll(containing: sessionID))
    }

    private func performRemoveAll(containing sessionID: UUID) -> AgentSessionOversightIntentMutationReceipt {
        let matches = tokenByPair.filter { $0.key.touches(sessionID: sessionID) }
        // Captured in the same actor turn as the attempted mutation. A caller cannot safely perform a
        // separate pre-read: a row inserted between that hop and this one would be covered by neither
        // the failed write nor its retry bookkeeping.
        let attempted = Dictionary(uniqueKeysWithValues: matches.map { pair, token in
            (
                pair,
                AgentSessionOversightIntentCurrentAttempt(
                    token: token,
                    assertionGeneration: assertionGeneration(for: pair)
                )
            )
        })
        guard mutationIsAdmitted else {
            return AgentSessionOversightIntentMutationReceipt(
                outcome: .blocked,
                storeRevisionBefore: storeRevision,
                storeRevisionAfter: storeRevision,
                transitions: [],
                wroteFile: false,
                attemptedCurrentByPair: attempted
            )
        }
        guard !matches.isEmpty else {
            return AgentSessionOversightIntentMutationReceipt(
                outcome: .unchanged,
                storeRevisionBefore: storeRevision,
                storeRevisionAfter: storeRevision,
                transitions: [],
                wroteFile: false
            )
        }
        var remaining = tokenByPair
        for pair in matches.keys {
            remaining.removeValue(forKey: pair)
        }
        let transitions = matches
            .map { AgentSessionOversightIntentTokenTransition(pair: $0.key, before: $0.value, after: nil) }
            .sorted { AgentSessionOversightIntent.canonicallyOrdered($0.pair, $1.pair) }
        return commit(
            pairs: Set(remaining.keys),
            revisionBefore: storeRevision,
            transitions: transitions,
            attemptedCurrentByPair: attempted,
            apply: { [self] in
                tokenByPair = remaining
            }
        )
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

    /// Confirms that every store operation registered before this call has crossed the actor
    /// boundary. Writes are write-through, so this is a linearization point, not a flush.
    func serializationBarrier() {}

    // MARK: - Diagnostics

    /// Debug-only, opt-in instrumentation shared with window/workspace restore.
    ///
    /// Everything emitted here is an enum-like outcome label or a count. Pairs, session identifiers,
    /// names, and the file/backup paths are deliberately absent: knowing *that* a launch quarantined
    /// its manifest or *that* a removal hit a stale token is the whole diagnostic value, and the
    /// identities would only add a privacy liability to a log this surface otherwise never writes to.
    private func logged(
        _ operation: String,
        _ receipt: AgentSessionOversightIntentMutationReceipt
    ) -> AgentSessionOversightIntentMutationReceipt {
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "oversight.store.receipt",
                fields: [
                    "op": operation,
                    "outcome": receipt.outcome.rawValue,
                    "wroteFile": receipt.wroteFile ? "1" : "0",
                    "revision": String(receipt.storeRevisionAfter),
                    "transitions": String(receipt.transitions.count)
                ]
            )
        #endif
        return receipt
    }

    #if DEBUG
        /// The launch classification is reported once even though `loadForLaunch()` is called by the
        /// coordinator, by Add, and by Stop: it is one fact about this launch, not one per caller.
        private var didLogLaunchClassification = false

        private func logLaunchClassificationOnce(_ result: AgentSessionOversightIntentLoadResult) {
            guard !didLogLaunchClassification else { return }
            didLogLaunchClassification = true
            switch result {
            case .suppressed:
                WorkspaceRestorePerfLog.event("oversight.store.load", fields: ["result": "suppressed"])
            case let .blocked(reason):
                WorkspaceRestorePerfLog.event(
                    "oversight.store.load",
                    fields: ["result": "blocked", "reason": reason.diagnosticLabel]
                )
            case let .ready(load):
                WorkspaceRestorePerfLog.event(
                    "oversight.store.load",
                    fields: ["result": load.source.rawValue, "pairs": String(load.tokenByPair.count)]
                )
            }
        }
    #endif

    // MARK: - Commit

    private var mutationIsAdmitted: Bool {
        mode.performsProductionFileIO && didLoad && blockReason == nil
    }

    private func blockedReceipt(
        attemptedCurrentByPair: [AgentSessionOversightIntent: AgentSessionOversightIntentCurrentAttempt] = [:]
    ) -> AgentSessionOversightIntentMutationReceipt {
        AgentSessionOversightIntentMutationReceipt(
            outcome: .blocked,
            storeRevisionBefore: storeRevision,
            storeRevisionAfter: storeRevision,
            transitions: [],
            wroteFile: false,
            attemptedCurrentByPair: attemptedCurrentByPair
        )
    }

    /// Encode → atomic replace → in-memory commit, with nothing suspendable in between.
    ///
    /// `apply` runs only after the replacement succeeded, and this whole method is synchronous
    /// inside the actor, so a cancelled caller cannot observe (or produce) a disk/memory split.
    /// - Parameter attemptedCurrentByPair: atomic current-row snapshot returned only if the write is
    ///   blocked or fails, so committed-deletion cleanup can queue exact retries without another hop.
    private func commit(
        pairs: Set<AgentSessionOversightIntent>,
        revisionBefore: UInt64,
        transitions: [AgentSessionOversightIntentTokenTransition],
        attemptedCurrentByPair: [AgentSessionOversightIntent: AgentSessionOversightIntentCurrentAttempt] = [:],
        apply: () -> Void
    ) -> AgentSessionOversightIntentMutationReceipt {
        // The defensive guards are load-time *and* mutation-time. Checking them only on load would
        // let a manifest sitting exactly at a limit accept one more row, write successfully, and then
        // block itself on the next launch — the file would be preserved, but every saved link in it
        // would become unchangeable because of a write this process reported as a success.
        guard pairs.count <= maxDecodedRowCount else {
            return blockedReceipt(attemptedCurrentByPair: attemptedCurrentByPair)
        }
        let document = AgentSessionOversightIntentDocument(
            links: pairs.sorted(by: AgentSessionOversightIntent.canonicallyOrdered)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(document)
            // Measured on the exact bytes that would be written, before the replacement: preserving
            // the old file and refusing is the contract, never a partial salvage or an eviction.
            guard data.count <= maxFileByteCount else {
                return blockedReceipt(attemptedCurrentByPair: attemptedCurrentByPair)
            }
            // The container is created here rather than borrowed from whichever other component
            // happened to run first: this store bootstraps independently of window-session restore,
            // so on a first launch its atomic replace would otherwise fail with "no such directory"
            // and report a spurious save failure for an Add that had nothing wrong with it. Reached
            // only through `mutationIsAdmitted`, so a suppressed launch still creates nothing.
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writer(data, fileURL)
        } catch {
            return AgentSessionOversightIntentMutationReceipt(
                outcome: .writeFailed,
                storeRevisionBefore: revisionBefore,
                storeRevisionAfter: revisionBefore,
                transitions: [],
                wroteFile: false,
                attemptedCurrentByPair: attemptedCurrentByPair
            )
        }
        apply()
        storeRevision = revisionBefore &+ 1
        return AgentSessionOversightIntentMutationReceipt(
            outcome: .applied,
            storeRevisionBefore: revisionBefore,
            storeRevisionAfter: storeRevision,
            transitions: transitions,
            wroteFile: true
        )
    }

    private func mintToken(
        for pair: AgentSessionOversightIntent,
        revision: UInt64? = nil
    ) -> AgentSessionOversightIntentToken {
        AgentSessionOversightIntentToken(
            storeProcessGeneration: storeProcessGeneration,
            pair: pair,
            pairRevision: revision ?? storeRevision
        )
    }
}
