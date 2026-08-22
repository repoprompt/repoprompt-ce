import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexConnectedAppsProviderBindingTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testProviderSnapshotDefaultsOffAndHumanMutationRoundTrips() throws {
        let defaults = try makeIsolatedDefaults()
        let snapshots = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            codexMCPServerEntries: { [] }
        )

        XCTAssertFalse(try XCTUnwrap(
            snapshots.topLevelSettingsControlsBinding(providerID: .codex).codexTools
        ).connectedAppsEnabled)

        snapshots.applyCodexToolSettingMutation(.connectedApps(enabled: true))

        XCTAssertTrue(try XCTUnwrap(
            snapshots.topLevelSettingsControlsBinding(providerID: .codex).codexTools
        ).connectedAppsEnabled)
        XCTAssertEqual(defaults.object(forKey: CodexConnectedApps.defaultsKey) as? Bool, true)
    }

    func testLaunchSnapshotAllowsDirectSessionAndRejectsMCPRelatedSession() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: CodexConnectedApps.defaultsKey)
        let service = AgentModeProviderBindingService(preferences: AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            codexMCPServerEntries: { [] }
        ))

        XCTAssertTrue(service.codexConnectedAppsEnabledForLaunch(isMCPRelated: false))
        XCTAssertFalse(service.codexConnectedAppsEnabledForLaunch(isMCPRelated: true))
    }

    func testCoordinatorLaunchSnapshotKeepsMCPRelatedSessionsDisabledForLifetime() async {
        await assertCoordinatorLaunch(
            label: "direct human",
            expectedConnectedAppsEnabled: true
        ) { _ in }
        await assertCoordinatorLaunch(
            label: "live MCP control",
            expectedConnectedAppsEnabled: false
        ) { session in
            session.mcpControlContext = makeLiveMCPControlContext()
        }
        await assertCoordinatorLaunch(
            label: "released MCP-originated session",
            expectedConnectedAppsEnabled: false
        ) { session in
            session.isMCPOriginated = true
        }
        await assertCoordinatorLaunch(
            label: "released temporary MCP control",
            expectedConnectedAppsEnabled: false
        ) { session in
            session.mcpControlActivationGeneration = 2
        }
    }

    private func assertCoordinatorLaunch(
        label: String,
        expectedConnectedAppsEnabled: Bool,
        configure: (AgentModeViewModel.TabSession) -> Void
    ) async {
        let controller = ConnectedAppsLaunchFakeCodexController()
        var capturedConnectedAppsEnabled: Bool?
        let viewModel = AgentModeViewModel(
            testWorkspacePath: "/repo",
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            codexControllerFactoryWithComputerUse: { _, _, _, _, _, _, _, connectedAppsEnabled in
                capturedConnectedAppsEnabled = connectedAppsEnabled
                return controller
            },
            testCodexHookApprovalSettingsProvider: ConnectedAppsHookApprovalSettings(),
            testCodexConnectedAppsEnabledForLaunch: { isMCPRelated in
                !isMCPRelated
            }
        )
        viewModel.test_initializeRunService()
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.runState = .idle
        configure(session)

        await viewModel.test_codexCoordinator.ensureCodexNativeSession(session: session)

        XCTAssertEqual(capturedConnectedAppsEnabled, expectedConnectedAppsEnabled, label)
        await viewModel.test_codexCoordinator.shutdownCodexSession(session)
    }

    private func makeLiveMCPControlContext() -> AgentModeViewModel.AgentMCPControlContext {
        let sessionID = UUID()
        return AgentModeViewModel.AgentMCPControlContext(
            sessionID: sessionID,
            activationID: UUID(),
            registration: .init(
                runtimeID: UUID(),
                runtimeGeneration: 1,
                sessionID: sessionID,
                generation: 1
            ),
            currentEpoch: nil,
            preparedEpoch: nil,
            pendingEpochTransition: nil,
            originatingConnectionID: nil,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: true,
            forceAutoEditEnabled: true,
            autoEditEnabledBeforeOverride: false,
            taskLabelKind: nil
        )
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "CodexConnectedAppsProviderBindingTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class ConnectedAppsHookApprovalSettings: CodexHookApprovalSettingsProviding {
    func codexHookApprovalStrictModeEnabled(workspaceID _: UUID?) -> Bool {
        false
    }
}

private final class ConnectedAppsLaunchFakeCodexController: CodexSessionControllerPassiveStubDefaults {
    let events: AsyncStream<CodexNativeSessionController.Event>
    private var eventsContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?

    init() {
        var capturedContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        eventsContinuation = capturedContinuation
    }

    func shutdown() async {
        eventsContinuation?.finish()
    }
}
