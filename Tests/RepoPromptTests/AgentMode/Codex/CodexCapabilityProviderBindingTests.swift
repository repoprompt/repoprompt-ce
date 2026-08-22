import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexCapabilityProviderBindingTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testProviderSnapshotDefaultsOffAndMutationsRemainIndependent() throws {
        let defaults = try makeIsolatedDefaults()
        let snapshots = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            codexMCPServerEntries: { [] }
        )

        var tools = try XCTUnwrap(
            snapshots.topLevelSettingsControlsBinding(providerID: .codex).codexTools
        )
        XCTAssertFalse(tools.appsEnabled)
        XCTAssertFalse(tools.pluginsEnabled)
        XCTAssertFalse(tools.mcpElicitationEnabled)
        XCTAssertFalse(tools.toolSuggestionsEnabled)

        snapshots.applyCodexToolSettingMutation(.apps(enabled: true))
        tools = try XCTUnwrap(snapshots.topLevelSettingsControlsBinding(providerID: .codex).codexTools)
        XCTAssertTrue(tools.appsEnabled)
        XCTAssertFalse(tools.pluginsEnabled)
        XCTAssertFalse(tools.mcpElicitationEnabled)
        XCTAssertFalse(tools.toolSuggestionsEnabled)

        snapshots.applyCodexToolSettingMutation(.plugins(enabled: true))
        snapshots.applyCodexToolSettingMutation(.mcpElicitation(enabled: true))
        snapshots.applyCodexToolSettingMutation(.toolSuggestions(enabled: true))
        tools = try XCTUnwrap(snapshots.topLevelSettingsControlsBinding(providerID: .codex).codexTools)
        XCTAssertTrue(tools.appsEnabled)
        XCTAssertTrue(tools.pluginsEnabled)
        XCTAssertTrue(tools.mcpElicitationEnabled)
        XCTAssertTrue(tools.toolSuggestionsEnabled)
        for preference in CodexCapabilityPreference.allCases {
            XCTAssertEqual(defaults.object(forKey: preference.defaultsKey) as? Bool, true)
        }
    }

    func testLaunchSnapshotProjectsMixedDirectChoicesAndDisablesMCPRelatedSessions() throws {
        let defaults = try makeIsolatedDefaults()
        CodexCapabilityPreference.apps.setEnabled(true, defaults: defaults)
        CodexCapabilityPreference.plugins.setEnabled(false, defaults: defaults)
        CodexCapabilityPreference.mcpElicitation.setEnabled(true, defaults: defaults)
        CodexCapabilityPreference.toolSuggestions.setEnabled(false, defaults: defaults)
        let service = AgentModeProviderBindingService(preferences: AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            codexMCPServerEntries: { [] }
        ))

        XCTAssertEqual(
            service.codexCapabilitiesForLaunch(isMCPRelated: false),
            CodexCapabilitySettings(
                appsEnabled: true,
                pluginsEnabled: false,
                mcpElicitationEnabled: true,
                toolSuggestionsEnabled: false
            )
        )
        XCTAssertEqual(service.codexCapabilitiesForLaunch(isMCPRelated: true), .disabled)
    }

    func testCoordinatorLaunchSnapshotKeepsMCPRelatedSessionsDisabledForLifetime() async {
        await assertCoordinatorLaunch(
            label: "direct human",
            expectedCapabilities: Self.allEnabled
        ) { _ in }
        await assertCoordinatorLaunch(
            label: "live MCP control",
            expectedCapabilities: .disabled
        ) { session in
            session.mcpControlContext = makeLiveMCPControlContext()
        }
        await assertCoordinatorLaunch(
            label: "released MCP-originated session",
            expectedCapabilities: .disabled
        ) { session in
            session.isMCPOriginated = true
        }
        await assertCoordinatorLaunch(
            label: "released temporary MCP control",
            expectedCapabilities: .disabled
        ) { session in
            session.mcpControlActivationGeneration = 2
        }
        await assertCoordinatorLaunch(
            label: "MCP-parented session",
            expectedCapabilities: .disabled
        ) { session in
            session.parentSessionID = UUID()
        }
    }

    private static let allEnabled = CodexCapabilitySettings(
        appsEnabled: true,
        pluginsEnabled: true,
        mcpElicitationEnabled: true,
        toolSuggestionsEnabled: true
    )

    private func assertCoordinatorLaunch(
        label: String,
        expectedCapabilities: CodexCapabilitySettings,
        configure: (AgentModeViewModel.TabSession) -> Void
    ) async {
        let controller = CapabilityLaunchFakeCodexController()
        var capturedCapabilities: CodexCapabilitySettings?
        let viewModel = AgentModeViewModel(
            testWorkspacePath: "/repo",
            codexControllerFactory: { _, _, _, _, _, _ in controller },
            codexControllerFactoryWithComputerUse: { _, _, _, _, _, _, _, capabilities in
                capturedCapabilities = capabilities
                return controller
            },
            testCodexHookApprovalSettingsProvider: CapabilityHookApprovalSettings(),
            testCodexCapabilitiesForLaunch: { isMCPRelated in
                isMCPRelated ? .disabled : Self.allEnabled
            }
        )
        viewModel.test_initializeRunService()
        let session = viewModel.session(for: UUID())
        session.selectedAgent = .codexExec
        session.runState = .idle
        configure(session)

        await viewModel.test_codexCoordinator.ensureCodexNativeSession(session: session)

        XCTAssertEqual(capturedCapabilities, expectedCapabilities, label)
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
        let suiteName = "CodexCapabilityProviderBindingTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class CapabilityHookApprovalSettings: CodexHookApprovalSettingsProviding {
    func codexHookApprovalStrictModeEnabled(workspaceID _: UUID?) -> Bool {
        false
    }
}

private final class CapabilityLaunchFakeCodexController: CodexSessionControllerPassiveStubDefaults {
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
