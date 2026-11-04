import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSelfMCPToolServiceTests: XCTestCase {
    func testRenamedToolDispatchesContextToCallingSession() async throws {
        let fixture = Fixture()
        let registry = MCPDomainToolRegistry()
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "self_compact"))
        let scope = MCPDomainToolRegistrationScope.window(id: fixture.window.windowID)
        try await registry.register(registrationID: .init(), scope: scope, bindings: [
            MCPDomainToolBinding(definition: definition) { args in
                try await .object(fixture.execute(args))
            }
        ])
        let candidate = await registry.resolve(toolName: ServerNetworkManager.canonicalToolName(for: "self_compact"), scope: scope)
        let tool = try XCTUnwrap(candidate)
        let result = try await tool.binding(["op": .string("context")])
        XCTAssertEqual(result.objectValue?["result"], .string("ok"))
        XCTAssertEqual(fixture.reads, 1)
        let legacy = await registry.resolve(toolName: ServerNetworkManager.canonicalToolName(for: "agent_self"), scope: scope)
        XCTAssertNil(legacy)
    }

    func testRenamedToolKeepsSavedAvailability() async throws {
        let suite = "self-compact-availability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for saved in [["read_file"], ["agent_self", "read_file"], ["self_compact", "read_file"], ["agent_self", "self_compact", "read_file"]] {
            defaults.set(saved, forKey: "mcp.disabledTools")
            let store = ToolAvailabilityStore(defaults: defaults)
            let wasEnabled = saved == ["read_file"]
            XCTAssertEqual(store.isEnabled("self_compact"), wasEnabled)
            XCTAssertEqual(ToolAvailabilityStore(defaults: defaults).isEnabled("self_compact"), wasEnabled)
            XCTAssertFalse(store.disabledTools.contains("agent_self"))
            XCTAssertEqual(
                Set(defaults.stringArray(forKey: "mcp.disabledTools") ?? []),
                wasEnabled ? ["read_file"] : ["self_compact", "read_file"]
            )
            await store.toggle("self_compact", enabled: !wasEnabled)
            XCTAssertEqual(ToolAvailabilityStore(defaults: defaults).isEnabled("self_compact"), !wasEnabled)
            XCTAssertEqual(store.isEnabled("read_file"), false)
        }
    }

    func testDisabledSelfToolCannotReadOrSchedule() async {
        let fixture = Fixture()
        fixture.enabled = false
        for args: [String: Value] in [
            ["op": .string("context")],
            ["op": .string("compact"), "note": .string("continue"), "idempotency_key": .string("key")]
        ] {
            do {
                _ = try await fixture.execute(args)
                XCTFail("Disabled self_compact must not enter the calling session")
            } catch let error as MCPError {
                XCTAssertEqual(error, .invalidParams("self_compact is disabled."))
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(fixture.reads, 0)
        XCTAssertEqual(fixture.schedules, 0)
    }

    func testContextReturnsExactLoadAndStatusOrNull() async throws {
        let fixture = Fixture()
        let load = try XCTUnwrap(DomainAgentSessionContextLoad(
            usedTokens: 123, windowTokens: 1000, confidence: .exact
        ))
        fixture.snapshot = .init(context: load, selfCompact: nil)
        let result = try await fixture.execute(["op": .string("context")])
        XCTAssertEqual(result["result"], .string("ok"))
        XCTAssertEqual(result["context"]?.objectValue?["used_tokens"], .int(123))
        XCTAssertEqual(result["context"]?.objectValue?["window_tokens"], .int(1000))
        XCTAssertEqual(result["context"]?.objectValue?["used_percent"], .double(12.3))
        XCTAssertEqual(result["context"]?.objectValue?["confidence"], .string("exact"))
        XCTAssertEqual(result["self_compact"], .null)

        fixture.snapshot = .init(context: nil, selfCompact: nil)
        let unknown = try await fixture.execute(["op": .string("context")])
        XCTAssertEqual(unknown["context"], .null)
    }

    func testCompactSchedulesOnceAndSameKeyOnlyReplaysIdenticalNote() async throws {
        let fixture = Fixture()
        let args: [String: Value] = [
            "op": .string("compact"), "note": .string("continue\n  verbatim"),
            "idempotency_key": .string("request-1")
        ]
        let first = try await fixture.execute(args)
        XCTAssertEqual(first["result"], .string("scheduled"))
        XCTAssertEqual(first["duplicate"], .bool(false))
        XCTAssertEqual(first["note_bytes"], .int("continue\n  verbatim".utf8.count))
        XCTAssertTrue(first["guidance"]?.stringValue?.contains("finish this turn normally") == true)
        XCTAssertEqual(fixture.schedules, 1)
        let repeatResult = try await fixture.execute(args)
        XCTAssertEqual(repeatResult["request_id"], first["request_id"])
        XCTAssertEqual(repeatResult["duplicate"], .bool(true))
        XCTAssertTrue(repeatResult["detail"]?.stringValue?.contains("no new compaction") == true)
        XCTAssertEqual(fixture.schedules, 1)
        let conflict = try await fixture.execute(args.merging(["note": .string("different")]) { _, new in new })
        XCTAssertEqual(conflict["reason"], .string("idempotency_conflict"))
        XCTAssertTrue(conflict["detail"]?.stringValue?.contains("latest settlement") == true)
        let pending = try await fixture.execute(args.merging(["idempotency_key": .string("request-2")]) { _, new in new })
        XCTAssertEqual(pending["reason"], .string("compact_already_pending"))
        XCTAssertTrue(pending["detail"]?.stringValue?.contains("active request") == true)
        XCTAssertEqual(fixture.schedules, 1)
    }

    func testUnsupportedCompactAndUnverifiedParkedStatusHaveJustInTimeGuidance() async throws {
        let fixture = Fixture()
        fixture.forcedAdmission = .blocked(reason: "not_supported")
        let blocked = try await fixture.execute([
            "op": .string("compact"), "note": .string("continue"), "idempotency_key": .string("key")
        ])
        XCTAssertTrue(blocked["detail"]?.stringValue?.contains("/compact") == true)

        fixture.snapshot = .init(context: nil, selfCompact: .init(
            requestID: UUID(), phase: "parked", outcome: .completionUnverified,
            completionVerified: false, noteDelivery: .parked, recoveryNote: "continue"
        ))
        let context = try await fixture.execute(["op": .string("context")])
        let detail = context["self_compact"]?.objectValue?["detail"]?.stringValue
        XCTAssertTrue(detail?.contains("not verified") == true)
        XCTAssertTrue(detail?.contains("next ordinary send") == true)

        fixture.snapshot = .init(context: nil, selfCompact: .init(
            requestID: UUID(), phase: "acpSettling", outcome: nil,
            completionVerified: nil, noteDelivery: nil, recoveryNote: nil
        ))
        let settling = try await fixture.execute(["op": .string("context")])
        XCTAssertTrue(settling["self_compact"]?.objectValue?["detail"]?.stringValue?.contains("may still be running") == true)

        fixture.snapshot = .init(context: nil, selfCompact: .init(
            requestID: UUID(), phase: nil, outcome: .recoveryRequired,
            completionVerified: false, noteDelivery: .deliveryUnknown, recoveryNote: "continue"
        ))
        let recovery = try await fixture.execute(["op": .string("context")])
        let recoveryDetail = recovery["self_compact"]?.objectValue?["detail"]?.stringValue
        XCTAssertTrue(recoveryDetail?.contains("not automatically retried") == true)
        XCTAssertTrue(recoveryDetail?.contains("explicit recovery") == true)
    }

    func testNativeUnverifiedAndPersistenceWarningReasonHaveProviderNeutralGuidance() async throws {
        let fixture = Fixture()
        fixture.snapshot = .init(context: nil, selfCompact: .init(
            requestID: UUID(), phase: nil, outcome: .completionUnverified,
            completionVerified: false, noteDelivery: .notSent, recoveryNote: "continue"
        ))
        let context = try await fixture.execute(["op": .string("context")])
        XCTAssertEqual(
            context["self_compact"]?.objectValue?["detail"],
            .string("Compaction completion is not verified.")
        )

        fixture.forcedAdmission = .blocked(reason: "session_not_exclusive")
        let blocked = try await fixture.execute([
            "op": .string("compact"), "note": .string("continue"), "idempotency_key": .string("key")
        ])
        XCTAssertEqual(blocked["reason"], .string("session_not_exclusive"))
        XCTAssertEqual(
            blocked["detail"],
            .string("Exclusive durable ownership could not be confirmed; compaction is refused.")
        )
    }

    func testNoTargetSelectorOrUnknownOperationCanReachReadOrSchedule() async {
        let fixture = Fixture()
        for key in [
            "session_id", "session_ids", "window_id", "tab_id", "context_id",
            "caller_session_id", "_tabID", "_windowID"
        ] {
            await assertInvalid(fixture, ["op": .string("context"), key: .string(UUID().uuidString)])
            await assertInvalid(fixture, [
                "op": .string("compact"), "note": .string("continue"),
                "idempotency_key": .string("key"), key: .string(UUID().uuidString)
            ])
        }
        await assertInvalid(fixture, ["op": .string("poll")])
        await assertInvalid(fixture, [:])
        XCTAssertEqual(fixture.reads, 0)
        XCTAssertEqual(fixture.schedules, 0)
    }

    func testNoteValidationIsUTF8BoundedAndRejectsMalformedKeysBeforeMutation() async {
        let fixture = Fixture()
        for note in ["", " \t\n", "a\u{0000}b", String(repeating: "😀", count: 16385)] {
            await assertInvalid(fixture, [
                "op": .string("compact"), "note": .string(note),
                "idempotency_key": .string("key")
            ])
        }
        for key: Value in [.null, .string(""), .string(String(repeating: "x", count: 201))] {
            await assertInvalid(fixture, [
                "op": .string("compact"), "note": .string("valid"), "idempotency_key": key
            ])
        }
        XCTAssertEqual(fixture.schedules, 0)
    }

    func testCompactUsesCallingSessionsWindowByteLimit() async throws {
        let fixture = Fixture()
        fixture.snapshot = try .init(context: XCTUnwrap(DomainAgentSessionContextLoad(
            usedTokens: nil, windowTokens: 200_000, confidence: nil
        )), selfCompact: nil)
        let note = String(repeating: "😀", count: 20000)
        let args: [String: Value] = [
            "op": .string("compact"), "note": .string(note), "idempotency_key": .string("limit")
        ]
        let result = try await fixture.execute(args)
        XCTAssertEqual(result["result"], .string("scheduled"))
        XCTAssertEqual(result["note_bytes"], .int(80000))
        XCTAssertEqual(fixture.state.active?.note, note)
        do {
            _ = try await fixture.execute(args.merging(["note": .string(note + "x"), "idempotency_key": .string("new-oversized")]) { _, new in new })
            XCTFail("One byte above the calling session's limit must be refused")
        } catch let error as MCPError {
            XCTAssertEqual(error, .invalidParams("self_compact compact note is 80001 UTF-8 bytes; maximum 80000 for this session (10% of context window at 4 UTF-8 bytes/token)."))
        }
        XCTAssertEqual(fixture.schedules, 1)
    }

    func testCompactUnknownWindowUsesFallbackByteLimit() async throws {
        let usedOnly = try XCTUnwrap(DomainAgentSessionContextLoad(
            usedTokens: 123, windowTokens: nil, confidence: .exact
        ))
        for context in [nil, usedOnly] {
            let fixture = Fixture()
            fixture.snapshot = .init(context: context, selfCompact: nil)
            let note = String(repeating: "x", count: 65536)
            let args: [String: Value] = [
                "op": .string("compact"), "note": .string(note), "idempotency_key": .string("fallback")
            ]
            let result = try await fixture.execute(args)
            XCTAssertEqual(result["result"], .string("scheduled"))
            XCTAssertEqual(result["note_bytes"], .int(65536))
            do {
                _ = try await fixture.execute(args.merging(["note": .string(note + "x"), "idempotency_key": .string("new-oversized")]) { _, new in new })
                XCTFail("One byte above the fallback must be refused")
            } catch let error as MCPError {
                XCTAssertEqual(error, .invalidParams("self_compact compact note is 65537 UTF-8 bytes; maximum 65536 for this session (unknown context window fallback)."))
            }
            XCTAssertEqual(fixture.schedules, 1)
        }
    }

    func testIdenticalRetryDeduplicatesAfterWindowShrinksOrResolvesSmaller() async throws {
        let large = try XCTUnwrap(DomainAgentSessionContextLoad(
            usedTokens: nil, windowTokens: 200_000, confidence: nil
        ))
        let small = try XCTUnwrap(DomainAgentSessionContextLoad(
            usedTokens: nil, windowTokens: 1000, confidence: nil
        ))
        for initialContext in [nil, large] {
            for settled in [false, true] {
                let fixture = Fixture()
                fixture.snapshot = .init(context: initialContext, selfCompact: nil)
                let note = String(repeating: "x", count: 8880)
                let args: [String: Value] = [
                    "op": .string("compact"), "note": .string(note), "idempotency_key": .string("retry")
                ]
                let first = try await fixture.execute(args)
                if settled {
                    fixture.state.settle(.cancelled, noteDelivery: .notSent, completionVerified: false)
                }
                fixture.snapshot = .init(context: small, selfCompact: fixture.state.status)
                let duplicate = try await fixture.execute(args)
                XCTAssertEqual(duplicate["duplicate"], .bool(true))
                XCTAssertEqual(duplicate["request_id"], first["request_id"])
                XCTAssertEqual(duplicate["result"], .string(settled ? "settled" : "scheduled"))

                let conflict = try await fixture.execute(args.merging(["note": .string(note + "x")]) { _, new in new })
                XCTAssertEqual(conflict["reason"], .string("idempotency_conflict"))
                do {
                    _ = try await fixture.execute(args.merging(["idempotency_key": .string("new")]) { _, new in new })
                    XCTFail("A new oversized request must still be refused")
                } catch let error as MCPError {
                    XCTAssertEqual(error, .invalidParams("self_compact compact note is 8880 UTF-8 bytes; maximum 400 for this session (10% of context window at 4 UTF-8 bytes/token)."))
                }
                XCTAssertEqual(fixture.schedules, 1)
            }
        }
    }

    func testCompactAcceptsPreviouslyRejected8880ByteNote() async throws {
        let fixture = Fixture()
        fixture.snapshot = try .init(context: XCTUnwrap(DomainAgentSessionContextLoad(
            usedTokens: nil, windowTokens: 200_000, confidence: nil
        )), selfCompact: nil)
        let result = try await fixture.execute([
            "op": .string("compact"), "note": .string(String(repeating: "x", count: 8880)),
            "idempotency_key": .string("larger-note")
        ])
        XCTAssertEqual(result["result"], .string("scheduled"))
        XCTAssertEqual(result["note_bytes"], .int(8880))
        XCTAssertEqual(fixture.schedules, 1)
    }

    func testCompactWithoutSelfSnapshotFailsClosed() async {
        let fixture = Fixture()
        fixture.snapshot = nil
        await assertUnavailable(fixture)
        XCTAssertEqual(fixture.schedules, 0)
    }

    func testUnresolvedExternalAndReboundOriginFailClosed() async {
        let fixture = Fixture()
        fixture.origin = nil
        await assertUnavailable(fixture)
        fixture.origin = .init(endpoint: fixture.endpoint, runID: UUID(), runAttemptID: UUID())
        fixture.resolvedEndpoint = .init(
            windowID: fixture.endpoint.windowID, workspaceID: fixture.endpoint.workspaceID,
            tabID: UUID(), sessionID: fixture.endpoint.sessionID,
            persistentBindingGeneration: fixture.endpoint.persistentBindingGeneration,
            bindingTransitionGeneration: fixture.endpoint.bindingTransitionGeneration
        )
        await assertUnavailable(fixture)
        fixture.resolvedEndpoint = nil
        await assertUnavailable(fixture)
        XCTAssertEqual(fixture.reads, 0)
        XCTAssertEqual(fixture.schedules, 0)
    }

    private func assertUnavailable(_ fixture: Fixture) async {
        for args: [String: Value] in [
            ["op": .string("context")],
            ["op": .string("compact"), "note": .string("continue"), "idempotency_key": .string("key")]
        ] {
            do {
                _ = try await fixture.execute(args)
                XCTFail("unresolved or changed caller must be denied")
            } catch let error as MCPError {
                XCTAssertEqual("\(error)", "\(AgentSelfMCPToolService.unavailableError)")
            } catch { XCTFail("\(error)") }
        }
    }

    private func assertInvalid(_ fixture: Fixture, _ args: [String: Value]) async {
        do {
            _ = try await fixture.execute(args)
            XCTFail("expected invalid params")
        } catch is MCPError {
            // Every malformed form is denied before mutating a session.
        } catch { XCTFail("\(error)") }
    }

    @MainActor
    private final class Fixture {
        let window = WindowState()
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        var origin: AgentSelfMCPCallOrigin?
        var resolvedEndpoint: DomainAgentSessionLinkEndpointIdentity?
        var snapshot: AgentSelfContextSnapshot? = .init(context: nil, selfCompact: nil)
        var state = AgentSelfCompactState()
        var reads = 0
        var schedules = 0
        var forcedAdmission: AgentSelfMCPToolService.Admission?
        var enabled = true

        init() {
            endpoint = .init(
                windowID: window.windowID, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
                persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
            )
            origin = .init(endpoint: endpoint, runID: UUID(), runAttemptID: UUID())
            resolvedEndpoint = endpoint
        }

        func execute(_ args: [String: Value]) async throws -> [String: Value] {
            let service = AgentSelfMCPToolService(
                captureRequestMetadata: {
                    .init(connectionID: UUID(), clientName: "agent-self-test", windowID: self.window.windowID)
                },
                requireTargetWindow: { self.window },
                resolveObserverEndpoint: { _, _ in self.resolvedEndpoint },
                captureCallOrigin: { self.origin },
                enterNoop: { window, origin, invocationID, argumentsAreEmpty in
                    window.agentModeViewModel.enterSelfNoopBody(
                        origin: origin, invocationID: invocationID, argumentsAreEmpty: argumentsAreEmpty
                    )
                },
                acceptNoop: { window, origin, endpoint, invocationID in
                    window.agentModeViewModel.acceptSelfNoopBody(origin: origin, endpoint: endpoint, invocationID: invocationID)
                },
                readSelf: { _, _, _ in
                    self.reads += 1
                    return self.snapshot
                },
                scheduleCompact: { _, _, _, note, key in
                    if let forcedAdmission = self.forcedAdmission {
                        return forcedAdmission
                    }
                    var state = self.state
                    let limit = AgentSessionSelfCompactNotePolicy.noteLimit(windowTokens: self.snapshot?.context?.windowTokens)
                    let reservation = state.reserve(
                        note: note, idempotencyKey: key,
                        maximumNoteUTF8Bytes: limit.maximumUTF8Bytes
                    )
                    switch reservation {
                    case let .scheduled(attempt):
                        self.schedules += 1
                        self.state = state
                        return .scheduled(attempt)
                    case let .duplicate(id):
                        return .duplicate(requestID: id, status: state.status)
                    case .conflict: return .blocked(reason: "idempotency_conflict")
                    case .alreadyPending: return .blocked(reason: "compact_already_pending")
                    case let .invalidNote(.tooLong(byteCount, maximum)):
                        return .noteTooLong(byteCount: byteCount, maximum: maximum, basis: limit.basis)
                    case .invalidNote, .invalidIdempotencyKey: return .blocked(reason: "invalid")
                    }
                },
                isToolEnabled: { self.enabled }
            )
            let result = try await service.execute(args: args)
            return try XCTUnwrap(result.objectValue)
        }
    }
}
