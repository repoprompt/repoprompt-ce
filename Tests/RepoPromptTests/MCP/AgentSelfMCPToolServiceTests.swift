import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSelfMCPToolServiceTests: XCTestCase {
    func testLegacyAliasDispatchesToSameServiceResultsAndAuthority() async throws {
        let fixture = Fixture()
        let registry = MCPDomainToolRegistry()
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "self_compact"))
        let scope = MCPDomainToolRegistrationScope.window(id: fixture.window.windowID)
        try await registry.register(registrationID: .init(), scope: scope, bindings: [
            MCPDomainToolBinding(definition: definition) { args in
                try await .object(fixture.execute(args))
            }
        ])
        let canonicalName = ServerNetworkManager.canonicalToolName(for: "self_compact")
        let legacyName = ServerNetworkManager.canonicalToolName(for: "agent_self")
        let canonicalCandidate = await registry.resolve(toolName: canonicalName, scope: scope)
        let legacyCandidate = await registry.resolve(toolName: legacyName, scope: scope)
        let canonical = try XCTUnwrap(canonicalCandidate)
        let legacy = try XCTUnwrap(legacyCandidate)
        XCTAssertEqual(legacy.handle, canonical.handle)
        XCTAssertEqual(legacy.binding.definition, canonical.binding.definition)

        fixture.forcedAdmission = .blocked(reason: "compact_already_pending")
        for args: [String: Value] in [
            ["op": .string("context")],
            ["op": .string("compact"), "note": .string("continue"), "idempotency_key": .string("key")]
        ] {
            let canonicalResult = try await canonical.binding(args)
            let legacyResult = try await MCPDomainSelfToolCallContext.withRequestedName("agent_self") {
                try await legacy.binding(args)
            }
            XCTAssertEqual(legacyResult, canonicalResult)
        }

        fixture.origin = nil
        for (name, binding) in [("self_compact", canonical.binding), ("agent_self", legacy.binding)] {
            do {
                _ = try await MCPDomainSelfToolCallContext.withRequestedName(name) {
                    try await binding(["op": .string("context")])
                }
                XCTFail("Alias must not manufacture calling-session authority")
            } catch let error as MCPError {
                XCTAssertEqual(error, .invalidParams("\(name) is available only to the calling Agent Mode session with a resolved live binding; no target selector grants access."))
            }
        }
    }

    func testLegacyErrorsAndDisabledPrecedencePreserveValidationAndCallerText() async throws {
        let fixture = Fixture()
        let cases: [([String: Value], String)] = [
            ([:], "op is required: context or compact."),
            (["op": .string("self_compact")], "Unknown agent_self op 'self_compact'."),
            (["op": .string("context"), "self_compact": .null], "context does not support 'self_compact'."),
            (["op": .string("context"), "session_id": .string("target")], "context does not support 'session_id'."),
            (["op": .string("compact")], "compact note is required as a string."),
            (["op": .string("compact"), "note": .string(" ")], "compact note must not be empty or whitespace-only."),
            (["op": .string("compact"), "note": .string("a\u{0000}b")], "compact note contains a disallowed control character."),
            (["op": .string("compact"), "note": .string(String(repeating: "x", count: 8193))], "compact note is 8193 UTF-8 bytes; maximum 8192."),
            (["op": .string("compact"), "note": .string("continue")], "compact idempotency_key is required (1...200 UTF-8 bytes).")
        ]
        for enabled in [true, false] {
            fixture.enabled = enabled
            for (args, message) in cases {
                let legacyMessage = message.hasPrefix("Unknown") ? message : "agent_self " + message
                do {
                    _ = try await MCPDomainSelfToolCallContext.withRequestedName("agent_self") {
                        try await fixture.execute(args)
                    }
                    XCTFail("Legacy validation must precede disabled refusal")
                } catch let error as MCPError {
                    XCTAssertEqual(error, .invalidParams(legacyMessage))
                }
                do {
                    _ = try await fixture.execute(args)
                    XCTFail("Expected canonical refusal")
                } catch let error as MCPError {
                    let canonicalMessage = message.hasPrefix("Unknown")
                        ? "Unknown self_compact op 'self_compact'." : "self_compact " + message
                    XCTAssertEqual(error, .invalidParams(enabled ? canonicalMessage : "self_compact is disabled."))
                }
            }
        }
        for args: [String: Value] in [
            ["op": .string("context")],
            ["op": .string("compact"), "note": .string("continue"), "idempotency_key": .string("key")]
        ] {
            do {
                _ = try await MCPDomainSelfToolCallContext.withRequestedName("agent_self") {
                    try await fixture.execute(args)
                }
                XCTFail("Valid legacy calls must still be disabled")
            } catch let error as MCPError {
                XCTAssertEqual(error, .invalidParams("agent_self is disabled."))
            }
        }
        fixture.origin = nil
        do {
            _ = try await MCPDomainSelfToolCallContext.withRequestedName("agent_self") {
                try await fixture.execute(["op": .string("compact")])
            }
            XCTFail("Legacy authority refusal must still precede compact validation/disabling")
        } catch let error as MCPError {
            XCTAssertEqual(error, .invalidParams("agent_self is available only to the calling Agent Mode session with a resolved live binding; no target selector grants access."))
        }
        XCTAssertEqual(fixture.reads, 0)
        XCTAssertEqual(fixture.schedules, 0)
        XCTAssertFalse(MCPDomainSelfToolCallContext.isLegacyAlias, "Legacy presentation must not leak to subsequent calls")
    }

    func testDisabledSelfToolCannotReadOrSchedule() async throws {
        let fixture = Fixture()
        fixture.enabled = false
        for args: [String: Value] in [
            ["op": .string("context")],
            ["op": .string("compact"), "note": .string("continue"), "idempotency_key": .string("key")]
        ] {
            do {
                _ = try await fixture.execute(args)
                XCTFail("Disabled tool must reject both operations")
            } catch let error as MCPError {
                XCTAssertEqual(error, .invalidParams("self_compact is disabled."))
            }
        }
        XCTAssertEqual(fixture.reads, 0)
        XCTAssertEqual(fixture.schedules, 0)
    }

    func testWindowCatalogAdvertisesOnlyCanonicalSelfTool() async {
        let window = WindowState()
        let enabled = await window.mcpServer.setWindowToolsEnabled(true)
        XCTAssertTrue(enabled)
        addTeardownBlock { @MainActor in
            _ = await window.mcpServer.setWindowToolsEnabled(false)
        }
        let catalog = await AppDomainRuntimeComposition.shared.runtime.toolRegistry.snapshot()
        XCTAssertTrue(catalog.toolNames.contains("self_compact"))
        XCTAssertFalse(catalog.toolNames.contains("agent_self"))
        XCTAssertFalse(ToolAvailabilityStore.shared.allTools.contains { $0.name == "agent_self" })
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

    func testLegacyLifecycleContextAndDuplicateOutcomesPreserveStatusAndRecoveryText() async throws {
        let fixture = Fixture()
        let requestID = UUID()
        let recoveryNote = "Continue with the literal self_compact reference in my note."
        let statuses: [AgentSelfCompactStatus] = [
            .init(
                requestID: requestID,
                phase: "acpSettling",
                outcome: nil,
                completionVerified: nil,
                noteDelivery: nil,
                recoveryNote: nil
            ),
            .init(
                requestID: requestID,
                phase: nil,
                outcome: .recoveryRequired,
                completionVerified: false,
                noteDelivery: .deliveryUnknown,
                recoveryNote: recoveryNote
            ),
            .init(
                requestID: requestID,
                phase: "parked",
                outcome: .completionUnverified,
                completionVerified: false,
                noteDelivery: .parked,
                recoveryNote: recoveryNote
            )
        ]
        for status in statuses {
            fixture.snapshot = .init(context: nil, selfCompact: status)
            fixture.forcedAdmission = .duplicate(requestID: requestID, status: status)
            for args: [String: Value] in [
                ["op": .string("context")],
                ["op": .string("compact"), "note": .string("continue"), "idempotency_key": .string("key")]
            ] {
                let canonical = try await fixture.execute(args)
                let legacy = try await MCPDomainSelfToolCallContext.withRequestedName("agent_self") {
                    try await fixture.execute(args)
                }
                XCTAssertEqual(legacy, canonical)
                XCTAssertEqual(legacy["self_compact"]?.objectValue?["recovery_note"], status.recoveryNote.map(Value.string) ?? .null)
                XCTAssertNil(legacy["agent_self"], "The existing status field is not a tool-name echo")
            }
        }
        XCTAssertEqual(fixture.schedules, 0)
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
        for note in ["", " \t\n", "a\u{0000}b", String(repeating: "😀", count: 2049)] {
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
        do {
            _ = try await fixture.execute(["op": .string("context")])
            XCTFail("unresolved or changed caller must be denied")
        } catch let error as MCPError {
            XCTAssertEqual("\(error)", "\(AgentSelfMCPToolService.unavailableError)")
        } catch { XCTFail("\(error)") }
    }

    private func assertInvalid(_ fixture: Fixture, _ args: [String: Value]) async {
        do {
            _ = try await fixture.execute(args)
            XCTFail("expected invalid params")
        } catch is MCPError {
            // Every malformed form is denied before reading or mutating a session.
        } catch { XCTFail("\(error)") }
    }

    @MainActor
    private final class Fixture {
        let window = WindowState()
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        var origin: AgentSelfMCPCallOrigin?
        var resolvedEndpoint: DomainAgentSessionLinkEndpointIdentity?
        var snapshot = AgentSelfContextSnapshot(context: nil, selfCompact: nil)
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
                readSelf: { _, _, _ in
                    self.reads += 1
                    return self.snapshot
                },
                scheduleCompact: { _, _, _, note, key in
                    if let forcedAdmission = self.forcedAdmission { return forcedAdmission }
                    var state = self.state
                    let reservation = state.reserve(note: note, idempotencyKey: key)
                    switch reservation {
                    case let .scheduled(attempt):
                        self.schedules += 1
                        self.state = state
                        return .scheduled(attempt)
                    case let .duplicate(id):
                        return .duplicate(requestID: id, status: state.status)
                    case .conflict: return .blocked(reason: "idempotency_conflict")
                    case .alreadyPending: return .blocked(reason: "compact_already_pending")
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

@MainActor
final class AgentSelfToolAvailabilityTests: XCTestCase {
    func testLegacyDisabledSettingMigratesAndBothNamesShareToggleAcrossReload() async throws {
        let suite = "self-tool-availability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for saved in [["agent_self", "read_file"], ["self_compact", "read_file"], ["agent_self", "self_compact", "read_file"]] {
            defaults.set(saved, forKey: "mcp.disabledTools")
            let store = ToolAvailabilityStore(defaults: defaults)
            XCTAssertEqual(store.disabledTools, ["self_compact", "read_file"])
            XCTAssertEqual(Set(defaults.stringArray(forKey: "mcp.disabledTools") ?? []), ["self_compact", "read_file"])
            for name in ["self_compact", "agent_self"] {
                XCTAssertFalse(store.isEnabled(name))
                XCTAssertFalse(ToolAvailabilityStore(defaults: defaults).isEnabled(name))
            }

            await store.toggle("agent_self", enabled: true)
            let enabled = ToolAvailabilityStore(defaults: defaults)
            XCTAssertTrue(enabled.isEnabled("self_compact"))
            XCTAssertTrue(enabled.isEnabled("agent_self"))
            XCTAssertEqual(enabled.disabledTools, ["read_file"])
            await enabled.toggle("self_compact", enabled: false)
            XCTAssertFalse(ToolAvailabilityStore(defaults: defaults).isEnabled("agent_self"))
        }
    }

    func testRenameDoesNotDisablePreviouslyEnabledTool() throws {
        let suite = "self-tool-availability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["read_file"], forKey: "mcp.disabledTools")
        let store = ToolAvailabilityStore(defaults: defaults)
        XCTAssertTrue(store.isEnabled("self_compact"))
        XCTAssertTrue(store.isEnabled("agent_self"))
        XCTAssertEqual(store.disabledTools, ["read_file"])
    }
}
