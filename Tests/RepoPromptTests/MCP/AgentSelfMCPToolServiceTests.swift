import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSelfMCPToolServiceTests: XCTestCase {
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
        let window = WindowState(externalMCPComposition: FigmaMCPTestGraph.make())
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        var origin: AgentSelfMCPCallOrigin?
        var resolvedEndpoint: DomainAgentSessionLinkEndpointIdentity?
        var snapshot = AgentSelfContextSnapshot(context: nil, selfCompact: nil)
        var state = AgentSelfCompactState()
        var reads = 0
        var schedules = 0
        var forcedAdmission: AgentSelfMCPToolService.Admission?

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
                }
            )
            let result = try await service.execute(args: args)
            return try XCTUnwrap(result.objectValue)
        }
    }
}
