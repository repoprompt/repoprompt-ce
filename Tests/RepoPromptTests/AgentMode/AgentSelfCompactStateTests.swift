import CryptoKit
@testable import RepoPromptApp
import XCTest

final class AgentSelfCompactStateTests: XCTestCase {
    private static let teardownNote = "Continue the current task."

    private static func holding(
        _ phase: AgentSelfCompactAttempt.Phase,
        verified: Bool = false,
        noteStarted: Bool = false
    ) -> AgentSelfCompactState {
        var attempt = AgentSelfCompactAttempt(idempotencyKey: "hold", note: teardownNote, phase: phase)
        attempt.compactTurnSucceeded = verified ? true : nil
        attempt.noteDispatchStarted = noteStarted
        return AgentSelfCompactState(active: attempt)
    }

    func testManagedStopHoldCoversOnlyRepoPromptOwnedUnsentDispatch() {
        let blocking: Set<AgentSelfCompactAttempt.Phase> = [
            .compactDispatchPending, .dispatchingCompact, .awaitingCompactTurn, .acpSettling,
            .awaitingNoteBoundary, .noteDispatchPending, .dispatchingNote
        ]
        for phase in AgentSelfCompactAttempt.Phase.allCases {
            XCTAssertEqual(Self.holding(phase).blocksManagedStop, blocking.contains(phase), phase.rawValue)
        }
        // The caller's originating turn and every already-started note send stay stoppable, even
        // though overseer delivery remains held until the note settles.
        XCTAssertTrue(Self.holding(.scheduled).blocksOverseerDelivery)
        let started = Self.holding(.dispatchingNote, verified: true, noteStarted: true)
        XCTAssertFalse(started.blocksManagedStop)
        XCTAssertTrue(started.blocksOverseerDelivery)
        XCTAssertFalse(AgentSelfCompactState().blocksManagedStop)
    }

    @MainActor
    func testRuntimeTeardownSettlesOrParksEveryWorkerOwnedHold() {
        for phase in [AgentSelfCompactAttempt.Phase.scheduled, .compactDispatchPending] {
            let session = AgentTabSession(tabID: UUID())
            session.selfCompactState = Self.holding(phase)
            session.cancelEphemeralRuntimeState()
            XCTAssertNil(session.selfCompactState.active, phase.rawValue)
            XCTAssertEqual(session.selfCompactState.latest?.outcome, .cancelled, phase.rawValue)
            XCTAssertEqual(session.selfCompactState.latest?.noteDelivery, .notSent, phase.rawValue)
            XCTAssertEqual(session.selfCompactState.latest?.recoveryNote, Self.teardownNote, phase.rawValue)
            XCTAssertFalse(session.selfCompactState.blocksAutomaticWake, phase.rawValue)
        }

        let unproven: [AgentSelfCompactAttempt.Phase] = [.dispatchingCompact, .awaitingCompactTurn, .acpSettling]
        let proven: [AgentSelfCompactAttempt.Phase] = [.awaitingNoteBoundary, .noteDispatchPending, .dispatchingNote]
        for (phase, verified) in unproven.map({ ($0, false) }) + proven.map({ ($0, true) }) {
            let session = AgentTabSession(tabID: UUID())
            session.selfCompactState = Self.holding(phase, verified: verified)
            session.selfCompactACPCommandItemIDs = [UUID()]
            session.isDirty = false
            session.cancelEphemeralRuntimeState()
            let state = session.selfCompactState
            XCTAssertNil(state.latest, phase.rawValue)
            XCTAssertEqual(state.active?.phase, .parked, phase.rawValue)
            XCTAssertEqual(state.active?.acpCompletionUnverified, verified ? nil : true, phase.rawValue)
            XCTAssertEqual(state.parkedNote?.frame, AgentSelfCompactNoteEnvelope.frame(Self.teardownNote), phase.rawValue)
            XCTAssertFalse(state.blocksOverseerDelivery, phase.rawValue)
            XCTAssertFalse(state.blocksManagedStop, phase.rawValue)
            XCTAssertNil(session.selfCompactNativeCompletion, phase.rawValue)
            XCTAssertNil(session.selfCompactACPCommandItemIDs, phase.rawValue)
            XCTAssertTrue(session.isDirty, phase.rawValue)
        }

        // A started send is owned by its provider seam, which always settles it; a parked note is
        // already free of every hold except Auto-wake, which the next ordinary send clears.
        for untouched in [Self.holding(.dispatchingNote, verified: true, noteStarted: true), Self.holding(.parked)] {
            let session = AgentTabSession(tabID: UUID())
            session.selfCompactState = untouched
            session.cancelEphemeralRuntimeState()
            XCTAssertEqual(session.selfCompactState, untouched)
        }
    }

    func testNotePolicyIsByteBoundedAndPreservesBody() {
        let exact = String(repeating: "x", count: 65536)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: exact, maximum: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .valid(byteCount: 65536))
        XCTAssertEqual(
            AgentSessionSelfCompactNotePolicy.validation(of: exact + "x", maximum: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes),
            .tooLong(byteCount: 65537, maximum: 65536)
        )
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: " \t\r\n ", maximum: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .empty)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: "a\u{0000}b", maximum: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .invalidScalar)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: "a\u{0085}b", maximum: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .invalidScalar)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: "a\t\r\nb", maximum: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .valid(byteCount: 5))
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.validation(of: String(repeating: "😀", count: 16384), maximum: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .valid(byteCount: 65536))

        let body = "  /compact\r\nKeep  two spaces\t😀  "
        let expected = SHA256.hash(data: Data(("agent_self.compact/v1\n" + body).utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.digest(of: body), expected)
        XCTAssertNotEqual(AgentSessionSelfCompactNotePolicy.digest(of: body), AgentSessionSelfCompactNotePolicy.digest(of: body.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func testNoteLimitUsesLiteralWindowShareWithoutFloorOrOverflow() {
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.maximumNoteUTF8Bytes(windowTokens: 200_000), 80000)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.maximumNoteUTF8Bytes(windowTokens: nil), 65536)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.maximumNoteUTF8Bytes(windowTokens: 10000), 4000)
        XCTAssertEqual(AgentSessionSelfCompactNotePolicy.maximumNoteUTF8Bytes(windowTokens: 20483), 8193)
        XCTAssertEqual(
            AgentSessionSelfCompactNotePolicy.maximumNoteUTF8Bytes(windowTokens: Int.max),
            3_689_348_814_741_910_322
        )
    }

    func testNoteLimitAndErrorBasisShareFallbackPredicate() {
        for window in [nil, 0, -1] {
            let limit = AgentSessionSelfCompactNotePolicy.noteLimit(windowTokens: window)
            XCTAssertEqual(limit.maximumUTF8Bytes, AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes)
            XCTAssertEqual(limit.basis, "unknown context window fallback")
        }
        let known = AgentSessionSelfCompactNotePolicy.noteLimit(windowTokens: 1000)
        XCTAssertEqual(known.maximumUTF8Bytes, 400)
        XCTAssertEqual(known.basis, "10% of context window at 4 UTF-8 bytes/token")
    }

    func testRetainedRetryDeduplicatesBeforeCurrentAdmissionByteLimit() throws {
        let note = String(repeating: "x", count: 8880)
        for originalLimit in [80000, AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes] {
            for settled in [false, true] {
                var state = AgentSelfCompactState()
                let first = try XCTUnwrap(state.reserve(
                    note: note, idempotencyKey: "retry", maximumNoteUTF8Bytes: originalLimit
                ).scheduledAttempt)
                if settled { state.settle(.cancelled, noteDelivery: .notSent, completionVerified: false) }
                XCTAssertEqual(state.reserve(note: note, idempotencyKey: "retry", maximumNoteUTF8Bytes: 400), .duplicate(first.id))
                XCTAssertEqual(state.reserve(note: note + "x", idempotencyKey: "retry", maximumNoteUTF8Bytes: 400), .conflict)
                XCTAssertEqual(
                    state.reserve(note: note, idempotencyKey: "new", maximumNoteUTF8Bytes: 400),
                    .invalidNote(.tooLong(byteCount: 8880, maximum: 400))
                )
                XCTAssertEqual(state.reserve(note: " \t\n", idempotencyKey: "retry", maximumNoteUTF8Bytes: 400), .invalidNote(.empty))
                XCTAssertEqual(state.reserve(note: "a\u{0000}b", idempotencyKey: "retry", maximumNoteUTF8Bytes: 400), .invalidNote(.invalidScalar))
                XCTAssertEqual(state.reserve(note: note, idempotencyKey: "", maximumNoteUTF8Bytes: 400), .invalidIdempotencyKey)
            }
        }
    }

    func testReservationUsesExplicitSessionAndFallbackLimits() throws {
        let maximum = AgentSessionSelfCompactNotePolicy.maximumNoteUTF8Bytes(windowTokens: 200_000)
        let note = String(repeating: "x", count: maximum)
        var known = AgentSelfCompactState()
        let attempt = try XCTUnwrap(known.reserve(
            note: note, idempotencyKey: "known", maximumNoteUTF8Bytes: maximum
        ).scheduledAttempt)
        XCTAssertEqual(attempt.note, note)
        XCTAssertEqual(known.reserve(
            note: note + "x", idempotencyKey: "over", maximumNoteUTF8Bytes: maximum
        ), .invalidNote(.tooLong(byteCount: 80001, maximum: 80000)))

        var unknown = AgentSelfCompactState()
        let fallback = String(repeating: "x", count: 65536)
        XCTAssertNotNil(unknown.reserve(note: fallback, idempotencyKey: "unknown", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes).scheduledAttempt)
        XCTAssertEqual(
            unknown.reserve(note: fallback + "x", idempotencyKey: "over", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes),
            .invalidNote(.tooLong(byteCount: 65537, maximum: 65536))
        )
        var small = AgentSelfCompactState()
        XCTAssertEqual(
            small.reserve(note: String(repeating: "x", count: 4001), idempotencyKey: "small", maximumNoteUTF8Bytes: 4000),
            .invalidNote(.tooLong(byteCount: 4001, maximum: 4000))
        )
    }

    func testPersistedLargeNotesKeepIntegrityWithoutAdmissionByteCap() throws {
        let note = String(repeating: "😀", count: 20000)
        var state = AgentSelfCompactState()
        let attempt = try XCTUnwrap(state.reserve(
            note: note, idempotencyKey: "large", maximumNoteUTF8Bytes: 80000
        ).scheduledAttempt)
        XCTAssertTrue(attempt.isValid)
        let active = try JSONDecoder().decode(AgentSelfCompactState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(active.active?.note, note)

        var session = AgentSession(name: "Large note", autoEditEnabled: true)
        session.selfCompactState = state
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertFalse(restored.selfCompactPersistenceWarning)
        XCTAssertEqual(restored.selfCompactState?.latest?.recoveryNote, note)
        XCTAssertNil(restored.selfCompactState?.active)

        state.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
        XCTAssertTrue(try XCTUnwrap(state.latest).isValid)
        let settled = try JSONDecoder().decode(AgentSelfCompactState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(settled.latest?.recoveryNote, note)

        // Removing the decode byte cap must not relax content or digest integrity.
        for invalidNote in ["", " \t\n", "a\u{0000}b", "a\u{0085}b"] {
            let invalid = AgentSelfCompactAttempt(idempotencyKey: "invalid", note: invalidNote)
            XCTAssertFalse(invalid.isValid)
            XCTAssertFalse(AgentSelfCompactSettlement.recoveryRequired(from: invalid).isValid)
        }
        for record in [AgentSelfCompactState(active: attempt), state] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            let key = record.active == nil ? "latest" : "active"
            var fields = try XCTUnwrap(object[key] as? [String: Any])
            fields["noteDigest"] = String(repeating: "0", count: 64)
            object[key] = fields
            XCTAssertThrowsError(try JSONDecoder().decode(
                AgentSelfCompactState.self, from: JSONSerialization.data(withJSONObject: object)
            ))
        }
    }

    func testActiveRequestTakesPrecedenceOverLatestSettlementRetry() throws {
        let maximum = AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes
        var state = AgentSelfCompactState()
        let first = try XCTUnwrap(state.reserve(note: "A", idempotencyKey: "A", maximumNoteUTF8Bytes: maximum).scheduledAttempt)
        state.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
        let second = try XCTUnwrap(state.reserve(note: "B", idempotencyKey: "B", maximumNoteUTF8Bytes: maximum).scheduledAttempt)
        XCTAssertEqual(state.reserve(note: "A", idempotencyKey: "A", maximumNoteUTF8Bytes: maximum), .alreadyPending)
        XCTAssertEqual(state.reserve(note: "changed A", idempotencyKey: "A", maximumNoteUTF8Bytes: maximum), .alreadyPending)
        XCTAssertEqual(
            state.reserve(note: String(repeating: "x", count: maximum + 1), idempotencyKey: "A", maximumNoteUTF8Bytes: maximum),
            .invalidNote(.tooLong(byteCount: maximum + 1, maximum: maximum))
        )
        XCTAssertEqual(state.active?.id, second.id)
        XCTAssertEqual(state.latest?.requestID, first.id)
    }

    func testActiveAndLatestIdempotencyHorizon() throws {
        var state = AgentSelfCompactState()
        let first = try XCTUnwrap(state.reserve(note: "first", idempotencyKey: "same", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes).scheduledAttempt)
        XCTAssertEqual(state.reserve(note: "first", idempotencyKey: "same", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .duplicate(first.id))
        XCTAssertEqual(state.reserve(note: "changed", idempotencyKey: "same", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .conflict)
        XCTAssertEqual(state.reserve(note: "second", idempotencyKey: "other", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .alreadyPending)
        state.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
        XCTAssertNil(state.active)
        XCTAssertEqual(state.reserve(note: "first", idempotencyKey: "same", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .duplicate(first.id))
        XCTAssertEqual(state.reserve(note: "changed", idempotencyKey: "same", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .conflict)
        let second = try XCTUnwrap(state.reserve(note: "second", idempotencyKey: "other", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes).scheduledAttempt)
        XCTAssertNotEqual(second.id, first.id)
        state.settle(.failed, noteDelivery: .notSent, completionVerified: false)
        // The contract intentionally retains only the active and latest keys.
        XCTAssertNotNil(state.reserve(note: "first", idempotencyKey: "same", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes).scheduledAttempt)
    }

    func testColdDecodeConvertsEveryRestoredPhaseIncludingParkedToNonExecutingRecovery() throws {
        for phase in AgentSelfCompactAttempt.Phase.allCases {
            var session = AgentSession(name: "Cold", autoEditEnabled: true)
            var state = AgentSelfCompactState()
            let attempt = try XCTUnwrap(state.reserve(note: "verbatim\n  note", idempotencyKey: "key", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes).scheduledAttempt)
            state.active?.phase = phase
            if phase == .dispatchingNote { state.active?.noteDispatchStarted = true }
            session.selfCompactState = state
            let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
            XCTAssertNil(restored.selfCompactState?.active, "\(phase)")
            XCTAssertEqual(restored.selfCompactState?.latest?.outcome, .recoveryRequired, "\(phase)")
            XCTAssertEqual(restored.selfCompactState?.latest?.requestID, attempt.id, "\(phase)")
            XCTAssertEqual(restored.selfCompactState?.status?.recoveryNote, "verbatim\n  note", "\(phase)")
            let expectedDelivery: AgentSelfCompactSettlement.NoteDelivery = switch phase {
            case .parked, .dispatchingNote: .deliveryUnknown
            default: .notSent
            }
            XCTAssertEqual(restored.selfCompactState?.status?.noteDelivery, expectedDelivery, "\(phase)")
            XCTAssertTrue(restored.selfCompactNeedsRecoveryRewrite, "\(phase)")
        }
    }

    func testColdRestoreTreatsUnsavedDispatchMarkerAsDeliveryUnknown() throws {
        var session = AgentSession(name: "Prepared", autoEditEnabled: true)
        var state = AgentSelfCompactState()
        _ = state.reserve(note: "recover", idempotencyKey: "prepared", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes)
        state.active?.phase = .dispatchingNote
        state.active?.noteDispatchStarted = false
        session.selfCompactState = state
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        // Claude can accept the note while its debounced noteDispatchStarted save still lags.
        // A persisted dispatching phase cannot prove the transport was never attempted.
        XCTAssertEqual(restored.selfCompactState?.latest?.noteDelivery, .deliveryUnknown)
        XCTAssertEqual(restored.selfCompactState?.latest?.recoveryNote, "recover")
    }

    func testColdRestoreOfParkedSnapshotAfterOrdinaryAcceptanceIsDeliveryUnknown() throws {
        // Claude, Codex, and ACP ordinary sends all persist the parked state before their
        // attempt marker, then schedule (rather than require) the marker save at transport.
        for provider in [
            AgentSessionLinkCompactSupport.claudeCode,
            .codex,
            .acpAdvertisedCommand
        ] {
            var session = AgentSession(name: "Parked \(provider.rawValue)", autoEditEnabled: true)
            var state = AgentSelfCompactState()
            let attempt = try XCTUnwrap(state.reserve(
                note: "recover once", idempotencyKey: "parked-\(provider.rawValue)",
                maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes
            ).scheduledAttempt)
            state.active?.admittedSupport = provider
            state.active?.phase = .parked
            session.selfCompactState = state
            let durableBeforeSend = try JSONEncoder().encode(session)

            // Hold the durable snapshot while the live ordinary turn enters transport and is
            // accepted. The debounced marker/settlement save has not committed at crash time.
            let dispatchID = AgentSelfCompactionDispatchID(requestID: attempt.id, stage: .note)
            XCTAssertTrue(state.noteWillAttempt(dispatchID))
            XCTAssertTrue(state.noteAccepted(dispatchID))
            XCTAssertEqual(state.latest?.noteDelivery, .prepended)

            let restored = try JSONDecoder().decode(AgentSession.self, from: durableBeforeSend)
            XCTAssertNil(restored.selfCompactState?.active)
            XCTAssertEqual(restored.selfCompactState?.latest?.noteDelivery, .deliveryUnknown, provider.rawValue)
            XCTAssertEqual(restored.selfCompactState?.latest?.recoveryNote, "recover once")
            var retry = try XCTUnwrap(restored.selfCompactState)
            XCTAssertEqual(retry.reserve(
                note: "recover once", idempotencyKey: "parked-\(provider.rawValue)",
                maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes
            ), .duplicate(attempt.id))
        }
    }

    func testMalformedOptionalRecordsDoNotDiscardSession() throws {
        let base = try JSONEncoder().encode(AgentSession(name: "Still here", autoEditEnabled: true))
        for malformed in [
            "{\"unknown\":true}",
            "{\"version\":99,\"active\":{}}",
            "{\"version\":1,\"active\":{\"note\":42,\"phase\":\"scheduled\"}}"
        ] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: base) as? [String: Any])
            object["selfCompactState"] = try JSONSerialization.jsonObject(with: Data(malformed.utf8))
            let restored = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(restored.name, "Still here")
            XCTAssertNil(restored.selfCompactState?.active)
            XCTAssertTrue(restored.selfCompactPersistenceWarning)
            XCTAssertEqual(restored.selfCompactState?.latest?.outcome, .recoveryRequired)
        }
    }

    func testColdRestorePreservesUnknownNoteDeliveryWithoutRetry() throws {
        var session = AgentSession(name: "Ambiguous", autoEditEnabled: true)
        var state = AgentSelfCompactState()
        let attempt = try XCTUnwrap(state.reserve(note: "exact body", idempotencyKey: "same", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes).scheduledAttempt)
        state.active?.phase = .dispatchingNote
        state.active?.noteDispatchStarted = true
        session.selfCompactState = state

        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertNil(restored.selfCompactState?.active)
        XCTAssertEqual(restored.selfCompactState?.latest?.outcome, .recoveryRequired)
        XCTAssertEqual(restored.selfCompactState?.latest?.noteDelivery, .deliveryUnknown)
        XCTAssertEqual(restored.selfCompactState?.latest?.recoveryNote, "exact body")
        var retry = try XCTUnwrap(restored.selfCompactState)
        XCTAssertEqual(retry.reserve(note: "exact body", idempotencyKey: "same", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .duplicate(attempt.id))
    }

    func testMalformedRecordIsBackedUpBeforeRepair() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-compact-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = AgentSession(name: "Preserve source", autoEditEnabled: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object["selfCompactState"] = ["version": 99, "note": "original recovery bytes"]
        let original = try JSONSerialization.data(withJSONObject: object)
        let fileURL = directory.appendingPathComponent("AgentSession-\(session.id.uuidString).json")
        try original.write(to: fileURL)

        let loaded = try await AgentSessionDataService().loadAgentSession(from: fileURL)
        XCTAssertEqual(loaded.name, "Preserve source")
        XCTAssertTrue(loaded.selfCompactPersistenceWarning)
        XCTAssertEqual(loaded.selfCompactState?.latest?.outcome, .recoveryRequired)
        let backupDirectory = directory.appendingPathComponent(".self-compact-recovery")
        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        let repaired = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: fileURL))
        XCTAssertFalse(repaired.selfCompactPersistenceWarning)
        XCTAssertEqual(repaired.selfCompactState?.latest?.outcome, .recoveryRequired)
    }

    func testRepeatedMaximumSizeRetryHasBoundedCost() throws {
        let note = String(repeating: "😀", count: 16384)
        var state = AgentSelfCompactState()
        let first = try XCTUnwrap(state.reserve(note: note, idempotencyKey: "retry", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes).scheduledAttempt)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0 ..< 1000 {
            XCTAssertEqual(state.reserve(note: note, idempotencyKey: "retry", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes), .duplicate(first.id))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
        XCTAssertEqual(state.active?.note, note)
    }
}

private extension AgentSelfCompactState.Reservation {
    var scheduledAttempt: AgentSelfCompactAttempt? {
        if case let .scheduled(attempt) = self { return attempt }
        return nil
    }
}
