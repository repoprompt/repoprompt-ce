import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRunMCPToolServiceHookApprovalTests: XCTestCase {
    func testWaitRoundTripPreservesHookApprovalFieldCapabilitiesAndMetadata() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let request = try fixture.installReview(phase: .reviewRequired)

        let value = try await fixture.service.execute(args: [
            "op": .string("wait"),
            "session_id": .string(fixture.sessionID.uuidString),
            "timeout": .int(1)
        ])
        let object = try XCTUnwrap(value.objectValue)
        let interaction = try XCTUnwrap(object["interaction"]?.objectValue)
        XCTAssertEqual(interaction["id"]?.stringValue, request.id.uuidString)
        XCTAssertEqual(interaction["kind"]?.stringValue, "hook_approval")
        XCTAssertEqual(interaction["response_type"]?.stringValue, "decision")

        let field = try XCTUnwrap(interaction["fields"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(field["id"]?.stringValue, "hook_keys")
        XCTAssertEqual(field["allows_multiple"]?.boolValue, true)
        XCTAssertEqual(field["allows_custom"]?.boolValue, false)
        XCTAssertNil(field["allows_other"])
        XCTAssertEqual(field["options"]?.arrayValue?.first?.objectValue?["label"]?.stringValue, HookApprovalMCPFixture.hookKey)

        let serialized = String(describing: interaction)
        for expected in [
            HookApprovalMCPFixture.hookKey,
            HookApprovalMCPFixture.sourcePath,
            HookApprovalMCPFixture.currentHash,
            HookApprovalMCPFixture.command
        ] {
            XCTAssertTrue(serialized.contains(expected), expected)
        }
    }

    func testAllPhasesMapOptionsAndStrictModeFiltersLive() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }

        let cases: [(AgentCodexHookReviewRequest.Phase, [String])] = [
            (.reviewRequired, ["approve_selected", "trust_all", "continue_without_hooks"]),
            (.writeFailed, ["approve_selected", "trust_all", "continue_without_hooks"]),
            (.verificationFailed, ["approve_selected", "trust_all", "continue_without_hooks"]),
            (.discoveryFailed, ["retry", "continue_without_hooks"]),
            (.discovering, []),
            (.submitting, [])
        ]
        for (phase, expected) in cases {
            _ = try fixture.installReview(phase: phase)
            XCTAssertEqual(fixture.interactionOptions(), expected, phase.rawValue)
        }

        _ = try fixture.installReview(phase: .reviewRequired)
        fixture.setStrictMode(true)
        XCTAssertEqual(fixture.interactionOptions(), ["approve_selected", "trust_all"])
        _ = try fixture.installReview(phase: .discoveryFailed)
        XCTAssertEqual(fixture.interactionOptions(), ["retry"])
    }

    func testApproveSelectedCanonicalResponseSurfacesSanitizedOutcomeAudit() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let request = try fixture.installReview(phase: .reviewRequired)
        let trustedInventory = try fixture.trustedInventory()
        fixture.controller.trustResults = [.success(trustedInventory)]

        let value = try await fixture.respond(
            requestID: request.id,
            response: "approve_selected",
            answers: ["hook_keys": [.string(HookApprovalMCPFixture.hookKey)]]
        )

        XCTAssertNil(fixture.session.pendingCodexHookReview)
        XCTAssertEqual(fixture.controller.trustCalls.first?.candidates.map(\.key), [HookApprovalMCPFixture.hookKey])
        let hookGate = try XCTUnwrap(value.objectValue?["hook_gate"]?.objectValue)
        XCTAssertEqual(hookGate["status"]?.stringValue, "approved_selected")
        XCTAssertEqual(hookGate["approved_hook_count"]?.intValue, 1)
        XCTAssertEqual(hookGate["skipped_hook_count"]?.intValue, 0)
        let serializedAudit = String(describing: hookGate)
        for privateValue in HookApprovalMCPFixture.privateMetadata {
            XCTAssertFalse(serializedAudit.contains(privateValue), privateValue)
        }
    }

    func testDiscoveryRetryToZeroSurfacesResolvedExternallyAudit() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let request = try fixture.installReview(phase: .discoveryFailed)
        let emptyInventory = try CodexHookInventory(executionCWD: "/repo", hooks: [])
        fixture.controller.listResults = [.success(emptyInventory)]

        let value = try await fixture.respond(requestID: request.id, response: "retry")

        XCTAssertNil(fixture.session.pendingCodexHookReview)
        let hookGate = try XCTUnwrap(value.objectValue?["hook_gate"]?.objectValue)
        XCTAssertEqual(hookGate["status"]?.stringValue, "resolved_externally")
        XCTAssertEqual(hookGate["approved_hook_count"]?.intValue, 0)
        XCTAssertEqual(hookGate["skipped_hook_count"]?.intValue, 0)
    }

    func testDiscoveryFailureContinueWithoutHooksSurfacesBypassAudit() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let request = try fixture.installReview(phase: .discoveryFailed)

        let value = try await fixture.respond(requestID: request.id, response: "continue_without_hooks")

        XCTAssertNil(fixture.session.pendingCodexHookReview)
        let hookGate = try XCTUnwrap(value.objectValue?["hook_gate"]?.objectValue)
        XCTAssertEqual(hookGate["status"]?.stringValue, "continued_without_hooks")
        XCTAssertEqual(hookGate["approved_hook_count"]?.intValue, 0)
        XCTAssertNil(hookGate["skipped_hook_count"])
        XCTAssertTrue(fixture.session.items.contains { item in
            item.kind == .system && item.text.contains("unknown number of Codex project hooks")
        })
    }

    func testDiscoveryFailureRejectsApprovalDecisionsWithoutMutation() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let request = try fixture.installReview(phase: .discoveryFailed)

        for response in ["approve_selected", "trust_all"] {
            let message = await fixture.invalidRespondMessage(
                requestID: request.id,
                payload: ["response": .string(response)]
            )
            XCTAssertTrue(message.localizedCaseInsensitiveContains("not available"), response)
            XCTAssertEqual(fixture.session.pendingCodexHookReview?.id, request.id, response)
            XCTAssertTrue(fixture.controller.trustCalls.isEmpty, response)
        }
    }

    func testCanonicalValidationRejectsAliasesPayloadsAndInvalidSelectionsWithoutMutation() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let request = try fixture.installReview(phase: .reviewRequired)
        let cases: [(String, [String: Value])] = [
            ("alias", ["response": .string("approve")]),
            ("decision", ["response": .string("trust_all"), "decision": .string("trust_all")]),
            ("skip", ["response": .string("trust_all"), "skip": .bool(false)]),
            ("amendment", ["response": .string("trust_all"), "amendment": .string("")]),
            ("content", ["response": .string("trust_all"), "content": .object([:])]),
            ("meta", ["response": .string("trust_all"), "_meta": .object([:])]),
            ("unknown top-level field", ["response": .string("trust_all"), "unexpected": .array([])]),
            (
                "structured answers",
                [
                    "response": .string("approve_selected"),
                    "answers": .object(["hook_keys": .object(["answers": .array([.string(HookApprovalMCPFixture.hookKey)])])])
                ]
            ),
            (
                "scalar hook keys",
                [
                    "response": .string("approve_selected"),
                    "answers": .object(["hook_keys": .string(HookApprovalMCPFixture.hookKey)])
                ]
            ),
            (
                "empty hook keys",
                [
                    "response": .string("approve_selected"),
                    "answers": .object(["hook_keys": .array([])])
                ]
            ),
            (
                "empty answers object",
                [
                    "response": .string("trust_all"),
                    "answers": .object([:])
                ]
            ),
            (
                "unknown empty answer field",
                [
                    "response": .string("trust_all"),
                    "answers": .object(["unexpected": .array([])])
                ]
            ),
            (
                "approve selected unknown empty answer field",
                [
                    "response": .string("approve_selected"),
                    "answers": .object(["unexpected": .array([])])
                ]
            ),
            (
                "duplicate keys",
                [
                    "response": .string("approve_selected"),
                    "answers": .object([
                        "hook_keys": .array([
                            .string(HookApprovalMCPFixture.hookKey),
                            .string(HookApprovalMCPFixture.hookKey)
                        ])
                    ])
                ]
            ),
            (
                "unknown key",
                [
                    "response": .string("approve_selected"),
                    "answers": .object(["hook_keys": .array([.string("UNKNOWN_PRIVATE_KEY")])])
                ]
            )
        ]

        for (label, payload) in cases {
            await fixture.assertInvalidRespond(requestID: request.id, payload: payload, label: label)
            XCTAssertEqual(fixture.session.pendingCodexHookReview?.id, request.id, label)
            XCTAssertTrue(fixture.controller.trustCalls.isEmpty, label)
        }
    }

    func testMalformedNestedSnapshotSectionsFailAtomically() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        _ = try fixture.installReview(phase: .reviewRequired)
        let value = try await fixture.service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(fixture.sessionID.uuidString)
        ])
        var object = try XCTUnwrap(value.objectValue)

        object["interaction"] = .object([:])
        XCTAssertNil(fixture.service.test_decodeSnapshot(from: .object(object)))

        object = try XCTUnwrap(value.objectValue)
        object["hook_gate"] = .string("malformed")
        XCTAssertNil(fixture.service.test_decodeSnapshot(from: .object(object)))
    }

    func testHookGateCountsDecodeFailClosedAndAbsentSkippedMeansUnknown() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let value = try await fixture.service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(fixture.sessionID.uuidString)
        ])
        var object = try XCTUnwrap(value.objectValue)
        let validHookGate = AgentRunMCPSnapshot.HookGate(
            status: .continuedWithoutHooks,
            approvedHookCount: 0,
            skippedHookCount: nil,
            resolvedAt: Date()
        ).asObject()

        object["hook_gate"] = .object(validHookGate)
        let decoded = try XCTUnwrap(fixture.service.test_decodeSnapshot(from: .object(object)))
        XCTAssertNil(decoded.hookGate?.skippedHookCount)

        var missingApprovedCount = validHookGate
        missingApprovedCount.removeValue(forKey: "approved_hook_count")
        object["hook_gate"] = .object(missingApprovedCount)
        XCTAssertNil(fixture.service.test_decodeSnapshot(from: .object(object)))

        var malformedSkippedCount = validHookGate
        malformedSkippedCount["skipped_hook_count"] = .string("unknown")
        object["hook_gate"] = .object(malformedSkippedCount)
        XCTAssertNil(fixture.service.test_decodeSnapshot(from: .object(object)))
    }

    func testConcurrentAndDuplicateResponsesDoNotDoubleMutate() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }
        let request = try fixture.installReview(phase: .reviewRequired)
        let trustedInventory = try fixture.trustedInventory()
        fixture.controller.trustResults = [.success(trustedInventory)]
        let gate = HookApprovalMCPAsyncGate()
        fixture.controller.trustGate = gate

        let firstResponse = Task { @MainActor in
            try await fixture.respond(requestID: request.id, response: "trust_all")
        }
        await gate.waitUntilEntered()

        let concurrentMessage = await fixture.invalidRespondMessage(
            requestID: request.id,
            payload: ["response": .string("trust_all")]
        )
        XCTAssertTrue(concurrentMessage.localizedCaseInsensitiveContains("already in progress"), concurrentMessage)

        await gate.release()
        _ = try await firstResponse.value

        let duplicateMessage = await fixture.invalidRespondMessage(
            requestID: request.id,
            payload: ["response": .string("trust_all")]
        )
        XCTAssertTrue(duplicateMessage.localizedCaseInsensitiveContains("no pending interaction"), duplicateMessage)
        XCTAssertEqual(fixture.controller.trustCalls.count, 1)
    }

    func testStrictContinueAndResolvingPhasesRejectWithoutMutation() async throws {
        let fixture = try await HookApprovalMCPFixture.make()
        addTeardownBlock { @MainActor in await fixture.cleanup() }

        var request = try fixture.installReview(phase: .reviewRequired)
        fixture.setStrictMode(true)
        let strictMessage = await fixture.invalidRespondMessage(
            requestID: request.id,
            payload: ["response": .string("continue_without_hooks")]
        )
        XCTAssertTrue(strictMessage.localizedCaseInsensitiveContains("strict mode"), strictMessage)
        XCTAssertEqual(fixture.session.pendingCodexHookReview?.id, request.id)

        fixture.setStrictMode(false)
        for phase in [AgentCodexHookReviewRequest.Phase.discovering, .submitting] {
            request = try fixture.installReview(phase: phase)
            let message = await fixture.invalidRespondMessage(
                requestID: request.id,
                payload: ["response": .string("trust_all")]
            )
            XCTAssertTrue(message.localizedCaseInsensitiveContains("already in progress"), message)
            XCTAssertEqual(fixture.session.pendingCodexHookReview?.id, request.id)
        }
    }
}

@MainActor
private final class HookApprovalMCPFixture {
    static let hookKey = "PRIVATE_HOOK_KEY"
    static let sourcePath = "/repo/private/.codex/config.toml"
    static let currentHash = "PRIVATE_CURRENT_HASH"
    static let command = "/repo/private/run-hook --secret"
    static let privateMetadata = [hookKey, sourcePath, currentHash, command]

    private let context: AgentRunMCPControlledSessionContext
    let controller = HookApprovalMCPFakeController()
    private let previousStrictMode: Bool

    var window: WindowState {
        context.window
    }

    var sessionID: UUID {
        context.sessionID
    }

    var session: AgentModeViewModel.TabSession {
        context.session
    }

    var service: AgentRunMCPToolService {
        context.service
    }

    private init(
        context: AgentRunMCPControlledSessionContext,
        previousStrictMode: Bool
    ) {
        self.context = context
        self.previousStrictMode = previousStrictMode
    }

    static func make() async throws -> HookApprovalMCPFixture {
        let settings = GlobalSettingsStore.shared
        let previousStrictMode = settings.globalCodexHookApprovalStrictModeEnabled()
        settings.setGlobalCodexHookApprovalStrictModeEnabled(false, commit: false)

        do {
            let context = try await AgentRunMCPControlledSessionContext.make(
                workspaceNamePrefix: "Hook Approval MCP",
                workspaceSwitchReason: "hookApprovalMCPTests",
                clientName: "hook-approval-mcp-tests",
                unusedStartRunMessage: "startRun should not be used by hook approval MCP tests"
            )
            return HookApprovalMCPFixture(
                context: context,
                previousStrictMode: previousStrictMode
            )
        } catch {
            settings.setGlobalCodexHookApprovalStrictModeEnabled(previousStrictMode, commit: false)
            throw error
        }
    }

    func setStrictMode(_ enabled: Bool) {
        GlobalSettingsStore.shared.setGlobalCodexHookApprovalStrictModeEnabled(enabled, commit: false)
    }

    @discardableResult
    func installReview(phase: AgentCodexHookReviewRequest.Phase) throws -> AgentCodexHookReviewRequest {
        let hooks: [AgentCodexHookReviewHook]
        let fingerprint: String?
        if phase == .discoveryFailed || phase == .discovering {
            hooks = []
            fingerprint = nil
        } else {
            let inventory = try unresolvedInventory()
            hooks = inventory.unresolvedProjectHooks.map(AgentCodexHookReviewHook.init)
            fingerprint = inventory.fingerprint
        }
        session.codexController = controller
        session.codexHookGateGeneration &+= 1
        let request = AgentCodexHookReviewRequest(
            tabID: session.tabID,
            runAttemptID: session.activeRunAttemptID,
            runID: session.runID,
            executionCWD: "/repo",
            hooks: hooks,
            warnings: ["PRIVATE_WARNING"],
            phase: phase,
            errorMessage: phase == .discoveryFailed ? "PRIVATE_DISCOVERY_ERROR" : nil,
            gateGeneration: session.codexHookGateGeneration
        )
        session.codexHookGateInventoryFingerprint = fingerprint
        session.codexHookGateActiveBinding = .init(
            controllerInstanceID: ObjectIdentifier(controller),
            controllerGeneration: session.codexControllerGeneration
        )
        session.pendingCodexHookReview = request
        session.codexHookGateAudit = nil
        session.runState = .waitingForApproval
        return request
    }

    func interactionOptions() -> [String] {
        window.agentModeViewModel.mcpSnapshot(sessionID: sessionID)?.interaction?.options.map(\.label) ?? []
    }

    func respond(
        requestID: UUID,
        response: String,
        answers: [String: [Value]] = [:]
    ) async throws -> Value {
        var args: [String: Value] = [
            "op": .string("respond"),
            "session_id": .string(sessionID.uuidString),
            "interaction_id": .string(requestID.uuidString),
            "response": .string(response)
        ]
        if !answers.isEmpty {
            args["answers"] = .object(answers.mapValues(Value.array))
        }
        return try await service.execute(args: args)
    }

    func assertInvalidRespond(requestID: UUID, payload: [String: Value], label: String) async {
        let message = await invalidRespondMessage(requestID: requestID, payload: payload)
        XCTAssertFalse(message.isEmpty, label)
    }

    func invalidRespondMessage(requestID: UUID, payload: [String: Value]) async -> String {
        var args = payload
        args["op"] = .string("respond")
        args["session_id"] = .string(sessionID.uuidString)
        args["interaction_id"] = .string(requestID.uuidString)
        do {
            _ = try await service.execute(args: args)
            XCTFail("Expected invalid params")
            return ""
        } catch let error as MCPError {
            return String(describing: error)
        } catch {
            XCTFail("Expected MCPError.invalidParams, got \(error)")
            return ""
        }
    }

    func unresolvedInventory() throws -> CodexHookInventory {
        try CodexHookInventory(executionCWD: "/repo", hooks: [hook(status: .untrusted)])
    }

    func trustedInventory() throws -> CodexHookInventory {
        try CodexHookInventory(executionCWD: "/repo", hooks: [hook(status: .trusted)])
    }

    func cleanup() async {
        GlobalSettingsStore.shared.setGlobalCodexHookApprovalStrictModeEnabled(previousStrictMode, commit: false)
        await context.cleanup()
    }

    private func hook(status: CodexHookTrustStatus) throws -> CodexHookMetadata {
        try CodexHookMetadata(
            eventName: "PreToolUse",
            source: "project",
            sourcePath: Self.sourcePath,
            key: Self.hookKey,
            currentHash: Self.currentHash,
            enabled: true,
            handlerType: "command",
            trustStatus: status,
            commandOrHandler: Self.command
        )
    }
}

private final class HookApprovalMCPFakeController: CodexSessionControllerPassiveStubDefaults {
    struct TrustCall {
        let candidates: [CodexHookTrustCandidate]
        let fingerprint: String
    }

    var listResults: [Result<CodexHookInventory, Error>] = []
    var trustResults: [Result<CodexHookInventory, Error>] = []
    private(set) var trustCalls: [TrustCall] = []
    var trustGate: HookApprovalMCPAsyncGate?

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { _ in }
    }

    func listHooksForCurrentWorkspace() async throws -> CodexHookInventory {
        guard !listResults.isEmpty else {
            throw CodexHookTrustError.malformedListResponse
        }
        return try listResults.removeFirst().get()
    }

    func trustHooksForCurrentWorkspace(
        expectedCandidates: [CodexHookTrustCandidate],
        expectedInventoryFingerprint: String
    ) async throws -> CodexHookInventory {
        trustCalls.append(.init(candidates: expectedCandidates, fingerprint: expectedInventoryFingerprint))
        if let trustGate {
            await trustGate.wait()
        }
        guard !trustResults.isEmpty else {
            throw CodexHookTrustError.batchWriteFailed
        }
        return try trustResults.removeFirst().get()
    }

    func shutdown() async {}
}

private actor HookApprovalMCPAsyncGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
