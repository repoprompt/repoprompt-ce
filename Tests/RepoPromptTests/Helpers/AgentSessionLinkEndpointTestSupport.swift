import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Minimal live workspace wiring for monitor-endpoint resolution.
///
/// An oversight endpoint is the full `(window, workspace, tab, session, binding generations)` tuple, so
/// a view model with no workspace manager has no resolvable incarnation at all and every
/// endpoint-scoped path correctly fails closed. Any suite that exercises one therefore needs a real
/// compose-tab binding rather than a bare `session(for:)` tab.
@MainActor
enum AgentSessionLinkEndpointTestSupport {
    /// Installs a one-tab ephemeral workspace and makes it this view model's active workspace.
    ///
    /// - Important: `AgentModeViewModel.workspaceManager` is a **weak** reference, so the caller must
    ///   retain the returned manager for the lifetime of the test. Dropping it silently detaches the
    ///   workspace, and every endpoint-scoped path then correctly — but confusingly — fails closed.
    ///
    /// - Parameter tabName: the compose tab's name, which becomes the endpoint candidate's
    ///   `displayName` and therefore the badge a cross-session delivery is attributed to. Suites that
    ///   never assert on attribution can leave it at the default.
    static func installWorkspace(
        on viewModel: AgentModeViewModel,
        tabID: UUID,
        name: String,
        tabName: String = "T1"
    ) -> WorkspaceManagerViewModel {
        let workspaceFiles = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: workspaceFiles,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: workspaceFiles,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: name,
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: tabName)],
            activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        return manager
    }

    /// The exact live incarnation bound to `tabID`, failing the test rather than yielding `nil`.
    static func endpoint(
        _ viewModel: AgentModeViewModel,
        tabID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DomainAgentSessionLinkEndpointIdentity {
        try XCTUnwrap(
            viewModel.agentSessionLinkObserverEndpoint(tabID: tabID),
            "expected a resolvable oversight endpoint",
            file: file,
            line: line
        )
    }

    /// The claim epoch for one live incarnation, defaulting to a supplement-eligible observer.
    static func epoch(
        _ viewModel: AgentModeViewModel,
        tabID: UUID,
        allowsSupplement: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AgentSessionLinkPromptEpoch {
        try AgentSessionLinkPromptEpoch(
            endpoint: endpoint(viewModel, tabID: tabID, file: file, line: line),
            allowsSupplement: allowsSupplement
        )
    }
}

/// Deterministic exact identities for presentation-model fixtures that do not construct a live
/// workspace. Production projections never synthesize these identities; they come from authority
/// peer maps.
enum AgentSessionLinkIdentityTestSupport {
    private static let workspaceID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    private static let tabID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
    private static let bindingID = UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!

    static func endpoint(
        sessionID: UUID,
        windowID: Int = 1,
        workspaceID: UUID? = nil,
        tabID: UUID? = nil,
        bindingID: UUID? = nil,
        transitionGeneration: UInt64 = 1
    ) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: windowID,
            workspaceID: workspaceID ?? Self.workspaceID,
            tabID: tabID ?? Self.tabID,
            sessionID: sessionID,
            persistentBindingGeneration: bindingID ?? Self.bindingID,
            bindingTransitionGeneration: transitionGeneration
        )
    }
}
