import Foundation
@testable import RepoPrompt
import XCTest

final class AgentModeExploreShellPolicyTests: XCTestCase {
    func testCodexLaunchUsesNormalShellPolicyForExploreRole() throws {
        let sourceURL = try RepoRoot.url()
            .appendingPathComponent("Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("permissionProfile, _, computerUseEnabled in"))
        XCTAssertTrue(source.contains("shellToolEnabled: nil"))
        XCTAssertFalse(source.contains("taskLabelKind == .explore ? false : nil"))
    }

    @MainActor
    func testClaudeCompatibleLaunchesDoNotForceNativeBashOffForExploreRole() async {
        let profiles: [AgentProviderPermissionProfile] = [
            .userConfigured,
            .mcpSafeDefaults,
            .providerOverride(.claude(.fullAccess))
        ]
        let providers: [AgentProviderKind] = [
            .claudeCode,
            .claudeCodeGLM,
            .kimiCode,
            .customClaudeCompatible
        ]

        for provider in providers {
            for profile in profiles {
                let controller = ExploreShellFakeNativeController(sessionID: "explore-session")
                var capturedAllowNativeBashTool: Bool?
                let coordinator = ClaudeAgentModeCoordinator(
                    windowID: 7,
                    workspacePathProvider: { _ in "/tmp/workspace" },
                    claudeControllerFactory: { _, _, _, _, _, allowNativeBashTool, _ in
                        capturedAllowNativeBashTool = allowNativeBashTool
                        return controller
                    }
                )
                let session = AgentModeViewModel.TabSession(tabID: UUID())
                session.selectedAgent = provider
                session.permissionProfile = profile
                session.mcpControlContext = makeExploreControlContext()

                await coordinator.ensureClaudeNativeSession(session: session)

                XCTAssertNil(
                    capturedAllowNativeBashTool,
                    "provider=\(provider.rawValue) profile=\(profile)"
                )
                XCTAssertEqual(session.providerSessionID, "explore-session")
            }
        }
    }

    @MainActor
    func testClaudeExploreFreshStartRetryDoesNotForceNativeBashOff() async {
        let staleController = ExploreShellFakeNativeController(
            sessionID: nil,
            failResume: true
        )
        let freshController = ExploreShellFakeNativeController(sessionID: "fresh-session")
        var factoryCalls = 0
        var capturedAllowNativeBashTools: [Bool?] = []
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: 7,
            workspacePathProvider: { _ in "/tmp/workspace" },
            claudeControllerFactory: { _, _, _, _, _, allowNativeBashTool, _ in
                factoryCalls += 1
                capturedAllowNativeBashTools.append(allowNativeBashTool)
                return factoryCalls == 1 ? staleController : freshController
            }
        )
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.providerSessionID = "stale-session"
        session.permissionProfile = .mcpSafeDefaults
        session.mcpControlContext = makeExploreControlContext()

        await coordinator.ensureClaudeNativeSession(session: session)

        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(capturedAllowNativeBashTools.count, 2)
        XCTAssertTrue(capturedAllowNativeBashTools.allSatisfy { $0 == nil })
        XCTAssertEqual(session.providerSessionID, "fresh-session")
    }

    func testExploreKeepsExistingNonShellMCPRestrictions() {
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: "read_file",
            taskLabelKind: .explore
        ))
        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
            toolName: "file_search",
            taskLabelKind: .explore
        ))

        for toolName in [
            "apply_edits",
            "file_actions",
            "manage_selection",
            "workspace_context",
            "prompt",
            "context_builder",
            "ask_oracle",
            "agent_run",
            "agent_explore"
        ] {
            XCTAssertFalse(
                AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: toolName,
                    taskLabelKind: .explore
                ),
                toolName
            )
        }
    }

    func testShellAvailabilityDoesNotChangeCodexSandboxOrApprovalPolicy() {
        let overrides = CodexNativeSessionController.defaultAppServerConfigOverrides(
            forceExperimentalSteering: true,
            approvalPolicy: .onRequest,
            sandboxMode: .readOnly,
            approvalReviewer: .user,
            shellToolEnabled: true
        )

        XCTAssertEqual(overrides["features.shell_tool"] as? Bool, true)
        XCTAssertNil(overrides["features.unified_exec"])
        XCTAssertEqual(overrides["approval_policy"] as? String, "on-request")
        XCTAssertEqual(overrides["sandbox_mode"] as? String, "read-only")
        XCTAssertEqual(overrides["approvals_reviewer"] as? String, "user")
        XCTAssertEqual(overrides["features.apply_patch_freeform"] as? Bool, false)
        XCTAssertEqual(overrides["features.multi_agent"] as? Bool, false)
    }

    @MainActor
    private func makeExploreControlContext() -> AgentModeViewModel.AgentMCPControlContext {
        let sessionID = UUID()
        return AgentModeViewModel.AgentMCPControlContext(
            sessionID: sessionID,
            activationID: UUID(),
            registration: .init(sessionID: sessionID, generation: 0),
            currentEpoch: nil,
            preparedEpoch: nil,
            pendingEpochTransition: nil,
            originatingConnectionID: nil,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: true,
            forceAutoEditEnabled: true,
            autoEditEnabledBeforeOverride: true,
            taskLabelKind: .explore
        )
    }
}

private actor ExploreShellFakeNativeController: NativeAgentRuntimeControlling {
    private let sessionRef: NativeAgentRuntimeSessionRef
    private let failResume: Bool
    private let stream: AsyncStream<NativeAgentRuntimeEvent>

    init(sessionID: String?, failResume: Bool = false) {
        sessionRef = NativeAgentRuntimeSessionRef(sessionID: sessionID)
        self.failResume = failResume
        stream = AsyncStream { _ in }
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        false
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        stream
    }

    func ensureEventsStreamReady() async {}
    func resetEventsStreamForNewRun() async {}

    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        if failResume, existingSessionID != nil {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        return sessionRef
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        sessionRef
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {}
    func sendUserMessage(_ text: String) async throws -> UUID {
        UUID()
    }

    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() async {}
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {}
}
