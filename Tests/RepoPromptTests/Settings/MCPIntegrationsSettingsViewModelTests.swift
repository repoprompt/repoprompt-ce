import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

private let openCodeProvider: ExternalMCPRuntimeProvider = .openCode
private let cursorProvider: ExternalMCPRuntimeProvider = .cursor
private let claudeProvider: ExternalMCPRuntimeProvider = .claudeCode

enum FigmaSettingsTestCLIAvailability {
    static let ready = AgentModelCatalog.AvailabilityContext(
        claudeCodeAvailable: true,
        codexAvailable: true,
        openCodeAvailable: true,
        cursorAvailable: true,
        grokBuildAvailable: true,
        antigravityAvailable: true,
        devinAvailable: true,
        zaiConfigured: false,
        kimiConfigured: false,
        customClaudeCompatibleConfigured: false
    )

    static let withoutCodex = AgentModelCatalog.AvailabilityContext(
        claudeCodeAvailable: true,
        codexAvailable: false,
        openCodeAvailable: true,
        cursorAvailable: true,
        grokBuildAvailable: true,
        antigravityAvailable: true,
        devinAvailable: true,
        zaiConfigured: false,
        kimiConfigured: false,
        customClaudeCompatibleConfigured: false
    )
}

@MainActor
final class MCPIntegrationsSettingsViewModelTests: XCTestCase {
    func testFinalActionMatrixIsExplicitAndHasNoPolicyOrDiscoveryAction() {
        let expected: [(FigmaMCPSettingsPresentationState, SettingsConnectionStatus, FigmaMCPSettingsCardContentMode, FigmaMCPSettingsPrimaryAction?, Bool)] = [
            (.fresh, .notConnected, .disconnected, .connect, false),
            (.inspecting, .connecting, .disconnected, .operationInProgress, false),
            (.canonicalImportFound, .notConnected, .disconnected, .useExistingConnection, false),
            (.connecting, .connecting, .disconnected, .operationInProgress, false),
            (.awaitingBrowserAuthorization, .notConnected, .disconnected, .checkConnection, true),
            (.authorizationRequired, .notConnected, .disconnected, .reauthenticate, true),
            (.connected, .connected, .connected, .testConnection, true),
            (.testing, .connected, .connected, .operationInProgress, true),
            (.expired, .notConnected, .disconnected, .reauthenticate, true),
            (.serverUnavailable, .unavailable, .disconnected, .retryConnection, true),
            (.error, .error, .disconnected, .retryConnection, true),
            (.signingOut, .connecting, .disconnected, nil, true),
            (.cancellationFinalizing, .connecting, .disconnected, nil, false),
            (.busy, .connecting, .disconnected, nil, false),
            (.codexUnavailable, .unavailable, .disconnected, .openCLIProviders, true),
            (.credentialRevocationRequired, .error, .disconnected, nil, true)
        ]

        XCTAssertEqual(Set(FigmaMCPSettingsPresentationState.allCases), Set(expected.map(\.0)))
        for (state, status, contentMode, action, showsSignOut) in expected {
            let spec = FigmaMCPSettingsPresentationSpec.resolve(state, hasDefinition: true)
            XCTAssertEqual(spec.status, status, "Unexpected status for \(state)")
            XCTAssertEqual(spec.contentMode, contentMode, "Unexpected content mode for \(state)")
            XCTAssertEqual(spec.primaryAction, action, "Unexpected action for \(state)")
            XCTAssertEqual(spec.showsSignOutAction, showsSignOut, "Unexpected Sign Out visibility for \(state)")
        }
    }

    func testClaudeCodeFigmaFocusRecheckIsArmedOnlyForOneAuthorizationReturn() {
        var policy = ClaudeCodeFigmaFocusRecheckPolicy()

        XCTAssertFalse(policy.consumeAppActivation())
        policy.beginAuthorization()
        XCTAssertTrue(policy.isAwaitingAuthorizationReturn)
        XCTAssertTrue(policy.consumeAppActivation())
        XCTAssertFalse(policy.consumeAppActivation())
        XCTAssertFalse(policy.isAwaitingAuthorizationReturn)
    }

    func testClaudeCodeFigmaFocusRecheckDisarmsWhenAuthorizationFinishes() {
        var policy = ClaudeCodeFigmaFocusRecheckPolicy()

        policy.beginAuthorization()
        policy.finishAuthorization()

        XCTAssertFalse(policy.consumeAppActivation())
    }

    func testCLIReadinessGroupsEveryRowWithoutChangingFigmaStatus() {
        var navigationCount = 0
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(),
            cliAvailability: .none,
            openCLIProviders: { navigationCount += 1 }
        )

        let unavailableGroups = model.providerRowGroups
        XCTAssertTrue(unavailableGroups.connected.isEmpty)
        XCTAssertFalse(unavailableGroups.notConnected.isEmpty)
        XCTAssertFalse(unavailableGroups.unsupported.isEmpty)
        XCTAssertTrue(unavailableGroups.notConnected.allSatisfy { !$0.canExpand && !$0.isCLIAvailable })
        XCTAssertTrue(unavailableGroups.unsupported.allSatisfy { !$0.canExpand && $0.actions.isEmpty })
        XCTAssertEqual(Set(model.providerRows.map(\.id)).count, 7)
        XCTAssertEqual(
            Set(unavailableGroups.notConnected.map(\.id) + unavailableGroups.unsupported.map(\.id)),
            Set(model.providerRows.map(\.id))
        )
        XCTAssertEqual(
            unavailableGroups.notConnected.map(\.displayName),
            unavailableGroups.notConnected.map(\.displayName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )
        XCTAssertEqual(
            unavailableGroups.unsupported.map(\.displayName),
            unavailableGroups.unsupported.map(\.displayName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )

        model.updateCLIAvailability(FigmaSettingsTestCLIAvailability.ready)
        XCTAssertTrue(model.providerRowGroups.notConnected.allSatisfy(\.canExpand))
        XCTAssertTrue(model.providerRowGroups.connected.isEmpty)
        XCTAssertEqual(model.providerRows.first { $0.id == .claudeCode }?.status, .needsLogin)
        model.openCLIProviderSettings()
        XCTAssertEqual(navigationCount, 1)
    }

    func testCLIPrerequisiteCopyNamesProviderAndAccessibleSettingsPath() throws {
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(),
            cliAvailability: .none
        )
        let row = try XCTUnwrap(model.providerRows.first { $0.id == .codex })
        XCTAssertEqual(
            row.cliPrerequisitePrefix,
            "Connect Codex CLI to RepoPrompt CE first, before connecting to Figma MCP.\nGo to Settings → Agent Mode → "
        )
        XCTAssertEqual(
            row.cliPrerequisiteAccessibilityMessage,
            "Connect Codex CLI to RepoPrompt CE first, before connecting to Figma MCP. Go to Settings → Agent Mode → CLI Providers"
        )
    }

    func testMCPIntegrationWindowTitleUsesCategoryBreadcrumbWithoutChangingOtherPanes() {
        XCTAssertEqual(SettingsWindowCoordinator.windowTitle(for: .mcpIntegrations), "Settings — MCP Integration — Figma")
        XCTAssertEqual(SettingsWindowCoordinator.windowTitle(for: .mcp), "Settings — Server")
        XCTAssertEqual(SettingsWindowCoordinator.windowTitle(for: .appearance), "Settings — Appearance")
    }

    func testCanonicalAvailableAgentKindsUnlockOnlyTheirFigmaRuntimeFamily() {
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(),
            cliAvailability: .none
        )
        for kind in AgentProviderKind.allCases {
            model.updateCLIAvailability(.none.assumingAvailable(kind))
            let availableRows = Set(model.providerRows.filter(\.isCLIAvailable).map(\.id))
            XCTAssertEqual(availableRows, [kind.externalMCPRuntimeProvider], "Unexpected Figma readiness for \(kind)")
        }
        model.updateCLIAvailability(.none)
        XCTAssertTrue(model.providerRows.allSatisfy { !$0.isCLIAvailable })
    }

    func testFreshStateUsesLoginWithFigma() async throws {
        let store = try makeStore()
        let service = FigmaSettingsTestService()
        let model = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, settingsStore: store, service: service)

        model.activateAndLoad()
        try await waitUntil { !model.isPerformingOperation }

        XCTAssertEqual(model.presentationState, .fresh)
        XCTAssertEqual(model.primaryActionTitle, "Connect")
        XCTAssertTrue(model.showsPrimaryAction)
        XCTAssertFalse(model.showsSignOutAction)
        let discoveryCount = await service.discoveryCount()
        let refreshCount = await service.refreshCount()
        XCTAssertEqual(discoveryCount, 0)
        XCTAssertEqual(refreshCount, 0)
        model.deactivate()
    }

    func testDisconnectedCodexBlocksFigmaWorkAndRoutesToCLIProviders() async throws {
        let store = try makeStore()
        let service = FigmaSettingsTestService(connectResult: .authorizationRequired)
        var openedCLIProviders = 0
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: store,
            service: service,
            openCLIProviders: { openedCLIProviders += 1 }
        )

        model.activateAndLoad()
        model.performPrimaryAction()

        XCTAssertEqual(model.presentationState, .codexUnavailable)
        XCTAssertEqual(model.connectionStatus, .unavailable)
        XCTAssertEqual(model.primaryActionTitle, "Open CLI Providers")
        XCTAssertEqual(openedCLIProviders, 1)
        let discoveryCount = await service.discoveryCount()
        let connectCount = await service.connectCount()
        let refreshCount = await service.refreshCount()
        XCTAssertEqual(discoveryCount, 0)
        XCTAssertEqual(connectCount, 0)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(model.connectionMessage, "Connect Codex in CLI Providers before setting up Figma.")

        model.updateCLIAvailability(FigmaSettingsTestCLIAvailability.ready)
        XCTAssertEqual(model.presentationState, .fresh)
        model.deactivate()
    }

    func testConnectDiscoversCanonicalImportThenRequiresConfirmation() async throws {
        let store = try makeStore()
        let service = FigmaSettingsTestService(
            refreshSnapshot: connectedSnapshot(),
            discoveryResult: .available(connectedSnapshot())
        )
        let model = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, settingsStore: store, service: service)
        model.activateAndLoad()
        model.performPrimaryAction()
        try await waitUntil { !model.isPerformingOperation }

        XCTAssertEqual(model.presentationState, .canonicalImportFound)
        XCTAssertEqual(model.primaryActionTitle, "Use Existing Connection")
        let discoveryCount = await service.discoveryCount()
        let connectCount = await service.connectCount()
        XCTAssertEqual(discoveryCount, 1)
        XCTAssertEqual(connectCount, 0)
        XCTAssertNil(store.externalMCPIntegration(for: .figma))
        XCTAssertFalse(model.connectionMessage?.contains("https://") ?? false)

        model.performPrimaryAction()
        try await waitUntil { !model.isPerformingOperation }
        XCTAssertEqual(store.externalMCPIntegration(for: .figma)?.origin, .adoptedImport)
        XCTAssertEqual(model.presentationState, .connected)
        model.deactivate()
    }

    func testConnectedPresentationRequiresCurrentCodexRuntimeVerification() throws {
        let store = try makeStore()
        let definition = ExternalMCPIntegrationDefinition.figma()
        XCTAssertTrue(store.setExternalMCPIntegration(definition))
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        let connected = connectedSnapshot()
        authority.publish(snapshot: connected, definition: definition)
        let coordinator = FigmaMCPIntegrationCoordinator(
            settingsStore: store,
            service: FigmaSettingsTestService(),
            runtimeAvailability: authority
        )
        coordinator.publish(connected, definition: definition)
        authority.clearAvailability()

        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            coordinator: coordinator
        )

        XCTAssertEqual(model.presentationState, .error)
        XCTAssertEqual(model.connectionStatus, .error)
        XCTAssertEqual(model.contentMode, .disconnected)
        XCTAssertFalse(model.isAuthenticatedConnection)
        XCTAssertNil(model.pendingPresentationEvent)
    }

    func testConnectedSummaryIsStatusOnlyAndTestingIsNotFreshVerification() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let service = FigmaSettingsTestService(refreshSnapshot: connectedSnapshot())
        let model = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, settingsStore: store, service: service)

        model.activateAndLoad()
        try await waitUntil { model.presentationState == .connected }
        XCTAssertEqual(model.connectionSummary?.rows, [
            .connection("Figma MCP"),
            .authentication("Figma sign-in verified through Codex"),
            .credentialOwner("Managed by Codex")
        ])
        let connectedRow = try XCTUnwrap(model.providerRows.first { $0.id == .codex })
        XCTAssertEqual(connectedRow.connectionSummary, model.connectionSummary)
        XCTAssertFalse(model.connectionSummary?.rows.contains { row in
            switch row {
            case .connection, .authentication, .credentialOwner: false
            }
        } ?? true)

        model.testConnection()
        XCTAssertEqual(model.presentationState, .testing)
        XCTAssertEqual(model.connectionSummary?.rows, [
            .connection("Figma MCP"),
            .authentication("Checking Figma sign-in through Codex"),
            .credentialOwner("Managed by Codex")
        ])
        let testingRow = try XCTUnwrap(model.providerRows.first { $0.id == .codex })
        XCTAssertTrue(testingRow.isTestingConnection)
        XCTAssertEqual(testingRow.verifiedAt, connectedRow.verifiedAt)
        XCTAssertEqual(testingRow.connectionSummary, model.connectionSummary)
        XCTAssertEqual(testingRow.actions.map(\.id), connectedRow.actions.map(\.id))
        XCTAssertTrue(testingRow.actions.allSatisfy(\.isDisabled))
        XCTAssertEqual(testingRow.actions.first(where: { $0.id == .testConnection })?.isLoading, true)
        model.deactivate()
    }

    func testOAuthURLHandoffStartsAutomaticVerificationAndShowsLoadingState() async throws {
        let store = try makeStore()
        let service = FigmaSettingsTestService(
            refreshSnapshot: .init(state: .authorizationRequired, authentication: .notLoggedIn, tools: [], lastSuccessfulCheck: nil, failureMessage: nil),
            connectResult: .authorizationRequired
        )
        var openedURL: URL?
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: service,
            openAuthorizationURL: { url in
                openedURL = url
                return true
            }
        )
        model.activateAndLoad()
        model.performPrimaryAction()
        try await waitUntil { model.currentOperationKind == .awaitAuthorizationCompletion }

        XCTAssertEqual(openedURL, FigmaSettingsTestService.authorizationURL)
        XCTAssertEqual(model.presentationState, .connecting)
        XCTAssertEqual(rowStatus(.codex, in: model), .authorizing)
        XCTAssertEqual(rowStatus(.codex, in: model)?.label, "Authorizing")
        XCTAssertEqual(rowStatus(.codex, in: model)?.capsuleStatus, .connecting)
        XCTAssertEqual(rowActions(.codex, in: model).map(\.id), [.cancelLogin])
        XCTAssertFalse(rowActions(.codex, in: model).first?.isDisabled ?? true)
        XCTAssertEqual(model.integrationCardStatus, .connecting)
        XCTAssertEqual(model.integrationCardStatusLabelOverride, "Authorizing")
        XCTAssertEqual(model.primaryActionTitle, "Check Connection")
        XCTAssertTrue(model.primaryActionIsLoading)
        XCTAssertTrue(model.primaryActionIsDisabled)
        XCTAssertEqual(model.primaryActionAccessibilityLabel, "Waiting for Figma sign in to complete")
        XCTAssertFalse(model.showsSignOutAction)
        XCTAssertNil(model.pendingPresentationEvent)
        XCTAssertEqual(model.authorizationHandoffOutcome, .awaitingBrowserAuthorization)
        XCTAssertEqual(model.connectionMessage, "Waiting for Figma sign in to complete…")

        // The provider-row X cancels the same app-wide Codex authorization operation.
        model.performProviderRowAction(provider: .codex, action: .cancelLogin)
        try await waitUntil { !model.isPerformingOperation }
        XCTAssertNil(model.pendingPresentationEvent)
        XCTAssertFalse(model.isAuthenticatedConnection)
        let refreshCount = await service.refreshCount()
        try await waitUntilAsync { await service.handoffDispositions() == [.opened] }
        let handoffDispositions = await service.handoffDispositions()
        XCTAssertGreaterThanOrEqual(refreshCount, 1)
        XCTAssertEqual(handoffDispositions, [.opened])
        model.deactivate()
    }

    func testPendingOAuthVerificationStaysDisconnectedUntilCodexConfirmsAuthenticatedStatus() async throws {
        let store = try makeStore()
        let authorizationRequired = FigmaMCPIntegrationSnapshot(
            state: .authorizationRequired,
            authentication: .notLoggedIn,
            tools: [],
            lastSuccessfulCheck: nil,
            failureMessage: nil
        )
        let service = FigmaSettingsTestService(
            refreshSnapshots: [authorizationRequired, connectedSnapshot()],
            connectResult: .authorizationRequired,
            operationDelayNanoseconds: 100_000_000
        )
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: service,
            openAuthorizationURL: { _ in true }
        )

        model.activateAndLoad()
        model.performPrimaryAction()
        var waited: UInt64 = 0
        while waited < 2_000_000_000 {
            let refreshCount = await service.refreshCount()
            if refreshCount == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 10_000_000
        }
        let refreshCountAfterPendingResponse = await service.refreshCount()
        XCTAssertEqual(refreshCountAfterPendingResponse, 1)

        XCTAssertEqual(model.snapshot, authorizationRequired)
        XCTAssertEqual(model.presentationState, .connecting)
        XCTAssertEqual(model.connectionStatus, .connecting)
        XCTAssertEqual(model.contentMode, .disconnected)
        XCTAssertFalse(model.isAuthenticatedConnection)
        XCTAssertNil(model.pendingPresentationEvent)
        XCTAssertFalse(model.isCurrentPresentationEvent(.init(
            id: UUID(),
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 0,
            coordinatorGeneration: model.figmaMCPCoordinator.state.revision,
            kind: .loginCompleted
        )))

        try await waitUntil { model.pendingPresentationEvent != nil }
        XCTAssertEqual(model.presentationState, .connected)
        XCTAssertTrue(model.isAuthenticatedConnection)
        XCTAssertEqual(model.pendingPresentationEvent?.kind, .loginCompleted)
        model.deactivate()
    }

    func testOpenedOAuthAutomaticallyVerifiesAndPresentsNativeSuccessAcknowledgement() async throws {
        let store = try makeStore()
        let service = FigmaSettingsTestService(
            refreshSnapshots: [connectedSnapshot()],
            connectResult: .authorizationRequired
        )
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: service,
            openAuthorizationURL: { _ in true }
        )
        model.activateAndLoad()
        model.performPrimaryAction()
        try await waitUntil { model.pendingPresentationEvent != nil }

        let refreshCount = await service.refreshCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(model.presentationState, .connected)
        XCTAssertTrue(model.isAuthenticatedConnection)
        let event = try XCTUnwrap(model.pendingPresentationEvent)
        XCTAssertEqual(event.kind, .loginCompleted)

        var presentation = FigmaMCPSettingsModalPresentation()
        XCTAssertTrue(presentation.receive(event))
        XCTAssertEqual(presentation.active, .acknowledgement(event))
        XCTAssertEqual(FigmaMCPSettingsAcknowledgementSpec(kind: .loginCompleted).title, "Figma MCP Management")
        XCTAssertEqual(FigmaMCPSettingsAcknowledgementSpec(kind: .loginCompleted).message, "Figma login completed.")
        XCTAssertEqual(FigmaMCPSettingsAcknowledgementSpec(kind: .loginCompleted).dismissTitle, "OK")
        XCTAssertFalse(presentation.receive(event))
        model.deactivate()
    }

    func testAutomaticOAuthVerificationPreservesTerminalFailureWithoutAcknowledgement() async throws {
        let store = try makeStore()
        let service = FigmaSettingsTestService(
            refreshSnapshots: [.init(state: .serverUnavailable, authentication: .unknown, tools: [], lastSuccessfulCheck: nil, failureMessage: "Unavailable")],
            connectResult: .authorizationRequired
        )
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: service,
            openAuthorizationURL: { _ in true }
        )
        model.activateAndLoad()
        model.performPrimaryAction()
        try await waitUntil { !model.isPerformingOperation && model.pendingPresentationEvent == nil && model.authorizationHandoffOutcome == nil }

        XCTAssertEqual(model.presentationState, .serverUnavailable)
        XCTAssertTrue(model.connectionMessage?.contains("unavailable") ?? false)
        XCTAssertNil(model.pendingPresentationEvent)
        model.deactivate()
    }

    func testFailedBrowserHandoffOffersRetryInsteadOfCheckConnection() async throws {
        let store = try makeStore()
        let service = FigmaSettingsTestService(connectResult: .authorizationRequired)
        var openedURL: URL?
        var openAttempt = 0
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: service,
            openAuthorizationURL: { url in
                openedURL = url
                openAttempt += 1
                return openAttempt > 1
            }
        )
        model.activateAndLoad()
        model.performPrimaryAction()
        try await waitUntil { !model.isPerformingOperation }

        XCTAssertEqual(openedURL, FigmaSettingsTestService.authorizationURL)
        XCTAssertEqual(model.presentationState, .error)
        XCTAssertEqual(model.primaryActionTitle, "Retry Connection")
        XCTAssertTrue(model.connectionMessage?.contains("could not be opened") ?? false)
        XCTAssertFalse(model.connectionMessage?.contains("Check Connection") ?? false)
        XCTAssertEqual(model.authorizationHandoffOutcome, .browserOpenFailed)

        // Retry Connection must restart OAuth, not merely poll the failed status.
        await service.setRefreshSnapshots([connectedSnapshot()])
        model.performPrimaryAction()
        try await waitUntil { model.pendingPresentationEvent != nil }
        let connectCountAfterRetry = await service.connectCount()
        XCTAssertEqual(connectCountAfterRetry, 2)
        XCTAssertEqual(model.presentationState, .connected)
        XCTAssertEqual(model.pendingPresentationEvent?.kind, .loginCompleted)
        try await waitUntilAsync {
            await service.handoffDispositions() == [.abandoned, .opened]
        }
        let handoffDispositions = await service.handoffDispositions()
        XCTAssertEqual(handoffDispositions, [.abandoned, .opened])
        model.deactivate()
    }

    func testManagedAuthorizationRequiredRowStartsFreshOAuthHandoff() async throws {
        let store = try makeStore()
        let definition = ExternalMCPIntegrationDefinition.figma()
        XCTAssertTrue(store.setExternalMCPIntegration(definition))
        let authorizationRequired = FigmaMCPIntegrationSnapshot(
            state: .authorizationRequired,
            authentication: .notLoggedIn,
            tools: [],
            lastSuccessfulCheck: nil,
            failureMessage: nil
        )
        let service = FigmaSettingsTestService(
            refreshSnapshots: [authorizationRequired, connectedSnapshot()],
            connectResult: .authorizationRequired
        )
        var openedURL: URL?
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: service,
            openAuthorizationURL: { url in
                openedURL = url
                return true
            }
        )

        model.activateAndLoad()
        try await waitUntil { model.presentationState == .authorizationRequired && !model.isPerformingOperation }
        let row = try XCTUnwrap(model.providerRows.first { $0.id == .codex })
        XCTAssertTrue(row.actions.contains { $0.id == .connect })
        XCTAssertEqual(row.actions.first(where: { $0.id == .connect })?.title, "Connect")

        model.performProviderRowAction(provider: .codex, action: .connect)
        try await waitUntil { model.pendingPresentationEvent != nil }

        let discoveryCount = await service.discoveryCount()
        let connectCount = await service.connectCount()
        let refreshCount = await service.refreshCount()
        try await waitUntilAsync { await service.handoffDispositions() == [.opened] }
        let handoffDispositions = await service.handoffDispositions()
        XCTAssertEqual(discoveryCount, 0)
        XCTAssertEqual(connectCount, 1)
        XCTAssertGreaterThanOrEqual(refreshCount, 2)
        XCTAssertEqual(openedURL, FigmaSettingsTestService.authorizationURL)
        XCTAssertEqual(handoffDispositions, [.opened])
        XCTAssertEqual(model.presentationState, .connected)
        XCTAssertEqual(model.pendingPresentationEvent?.kind, .loginCompleted)
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), definition)
        model.deactivate()
    }

    func testCodexConnectShowsAuthorizingCancelAndOutranksChecking() async throws {
        let store = try makeStore()
        let service = FigmaSettingsTestService(discoveryDelayNanoseconds: 5_000_000_000)
        let providerCoordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(provider: .openCode, delayNanoseconds: 5_000_000_000)
        ])
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: service,
            providerConnectionCoordinator: providerCoordinator
        )

        model.activateAndLoad()
        model.performProviderRowAction(provider: .codex, action: .connect)
        try await waitUntil {
            self.rowStatus(.codex, in: model) == .authorizing
                && self.rowStatus(.openCode, in: model) == .checking
        }

        let codexActions = rowActions(.codex, in: model)
        XCTAssertEqual(codexActions.count, 1)
        let cancel = try XCTUnwrap(codexActions.first)
        XCTAssertEqual(cancel.id, .cancelLogin)
        XCTAssertEqual(cancel.title, "Cancel Login")
        XCTAssertEqual(cancel.systemImage, "xmark.circle")
        XCTAssertEqual(cancel.accessibilityLabel, "Cancel Figma login for Codex CLI")
        XCTAssertFalse(cancel.isDisabled)
        XCTAssertEqual(model.integrationCardStatus, .connecting)
        XCTAssertEqual(model.integrationCardStatusLabelOverride, "Authorizing")

        model.performProviderRowAction(provider: .codex, action: .cancelLogin)
        try await waitUntilAsync { await service.cancellationCount() == 1 }
        try await waitUntil { !model.isPerformingOperation }
        XCTAssertEqual(rowStatus(.codex, in: model), .needsLogin)
        model.deactivate()
    }

    func testBrowserAuthorizationHandoffShowsAuthorizingAndFencesRepeatedConnect() async throws {
        let store = try makeStore()
        let authorizationRequired = FigmaMCPIntegrationSnapshot(
            state: .authorizationRequired,
            authentication: .notLoggedIn,
            tools: [],
            lastSuccessfulCheck: nil,
            failureMessage: nil
        )
        let service = FigmaSettingsTestService(
            refreshSnapshot: authorizationRequired,
            connectResult: .authorizationRequired,
            handoffSettlementDelayNanoseconds: 100_000_000
        )
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: service,
            openAuthorizationURL: { _ in true }
        )

        model.activateAndLoad()
        model.performProviderRowAction(provider: .codex, action: .connect)
        try await waitUntil {
            model.authorizationHandoffOutcome == .awaitingBrowserAuthorization
                && model.currentOperationKind == .awaitAuthorizationCompletion
        }

        let row = try XCTUnwrap(model.providerRows.first { $0.id == .codex })
        XCTAssertEqual(row.status, .authorizing)
        XCTAssertEqual(row.status.label, "Authorizing")
        XCTAssertEqual(row.status.capsuleStatus, .connecting)
        XCTAssertEqual(row.actions.map(\.id), [.cancelLogin])
        XCTAssertFalse(row.actions.first?.isDisabled ?? true)
        XCTAssertEqual(model.integrationCardStatus, .connecting)
        XCTAssertEqual(model.integrationCardStatusLabelOverride, "Authorizing")
        model.performProviderRowAction(provider: .codex, action: .connect)
        try await Task.sleep(nanoseconds: 20_000_000)
        let connectCount = await service.connectCount()
        XCTAssertEqual(connectCount, 1)

        model.performProviderRowAction(provider: .codex, action: .cancelLogin)
        try await waitUntilAsync { await service.cancellationCount() == 1 }
        try await waitUntil {
            !model.isPerformingOperation
                && self.rowStatus(.codex, in: model) == .needsLogin
        }
        XCTAssertFalse(model.isAuthenticatedConnection)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(rowStatus(.codex, in: model), .needsLogin)
        XCTAssertNil(model.pendingPresentationEvent)
        model.deactivate()
    }

    func testLateAuthorizationCompletionAfterCancelStaysNeedsLoginAndNextConnectRestartsAuthorization() async throws {
        let store = try makeStore()
        let authorizationRequired = FigmaMCPIntegrationSnapshot(
            state: .authorizationRequired,
            authentication: .notLoggedIn,
            tools: [],
            lastSuccessfulCheck: nil,
            failureMessage: nil
        )
        let service = FigmaSettingsTestService(
            refreshSnapshot: authorizationRequired,
            connectResult: .authorizationRequired,
            operationDelayNanoseconds: 100_000_000
        )
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: service,
            openAuthorizationURL: { _ in true }
        )

        model.activateAndLoad()
        model.performProviderRowAction(provider: .codex, action: .connect)
        try await waitUntil {
            model.currentOperationKind == .awaitAuthorizationCompletion
                && self.rowStatus(.codex, in: model) == .authorizing
        }

        model.performProviderRowAction(provider: .codex, action: .cancelLogin)
        await service.setRefreshSnapshot(connectedSnapshot())
        try await waitUntil {
            !model.isPerformingOperation
                && !model.figmaMCPCoordinator.hasInteractiveSettingsOperation
        }
        XCTAssertEqual(rowStatus(.codex, in: model), .needsLogin)
        XCTAssertFalse(model.isAuthenticatedConnection)
        XCTAssertFalse(model.showsSignOutAction)
        XCTAssertFalse(rowActions(.codex, in: model).contains { $0.id == .disconnect })
        XCTAssertNil(model.pendingPresentationEvent)

        await service.setRefreshSnapshot(authorizationRequired)
        try await waitUntil { !model.figmaMCPCoordinator.hasInteractiveSettingsOperation }
        model.performProviderRowAction(provider: .codex, action: .connect)
        try await waitUntilAsync { await service.connectCount() == 2 }
        try await waitUntil { model.currentOperationKind == .awaitAuthorizationCompletion }
        XCTAssertEqual(rowStatus(.codex, in: model), .authorizing)
        model.performProviderRowAction(provider: .codex, action: .cancelLogin)
        try await waitUntil { !model.isPerformingOperation }
        model.deactivate()
    }

    func testAuthorizationTimeoutReturnsNeedsLoginAndIgnoresLateCompletion() async throws {
        let store = try makeStore()
        let service = FigmaSettingsTestService(
            refreshSnapshot: connectedSnapshot(),
            connectResult: .authorizationRequired,
            operationDelayNanoseconds: 100_000_000,
            handoffSettlementDelayNanoseconds: 300_000_000
        )
        let coordinator = FigmaMCPIntegrationCoordinator(
            settingsStore: store,
            service: service,
            runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority(), authorizationCompletionTimeout: .zero
        )
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            coordinator: coordinator,
            openAuthorizationURL: { _ in true }
        )

        model.activateAndLoad()
        model.performProviderRowAction(provider: .codex, action: .connect)
        try await waitUntil {
            !model.isPerformingOperation
                && model.authorizationHandoffOutcome == nil
                && self.rowStatus(.codex, in: model) == .needsLogin
        }
        XCTAssertEqual(model.presentationState, .authorizationRequired)
        XCTAssertFalse(model.isAuthenticatedConnection)
        XCTAssertNil(model.pendingPresentationEvent)
        let dispositionsBeforeSettlement = await service.handoffDispositions()
        XCTAssertTrue(dispositionsBeforeSettlement.isEmpty)

        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(rowStatus(.codex, in: model), .needsLogin)
        XCTAssertFalse(model.isAuthenticatedConnection)
        XCTAssertNil(model.pendingPresentationEvent)
        model.deactivate()
    }

    func testDeactivationCancelsAuthorizationWaitAndDoesNotApplyItsLateCompletion() async throws {
        let store = try makeStore()
        let service = FigmaSettingsTestService(
            refreshSnapshot: connectedSnapshot(),
            connectResult: .authorizationRequired,
            operationDelayNanoseconds: 100_000_000
        )
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            coordinator: coordinator,
            openAuthorizationURL: { _ in true }
        )

        model.activateAndLoad()
        model.performProviderRowAction(provider: .codex, action: .connect)
        try await waitUntil { model.currentOperationKind == .awaitAuthorizationCompletion }
        model.deactivate()
        try await waitUntilAsync { await service.cancellationCount() == 1 }
        XCTAssertFalse(coordinator.hasInteractiveSettingsOperation)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(coordinator.runtimeAvailability.hasAuthenticatedRuntime)
        XCTAssertNil(model.pendingPresentationEvent)
    }

    func testManagedAuthorizationRequiredWithoutURLDoesNotWaitOrPoll() async throws {
        let store = try makeStore()
        let definition = ExternalMCPIntegrationDefinition.figma()
        XCTAssertTrue(store.setExternalMCPIntegration(definition))
        let authorizationRequired = FigmaMCPIntegrationSnapshot(
            state: .authorizationRequired,
            authentication: .notLoggedIn,
            tools: [],
            lastSuccessfulCheck: nil,
            failureMessage: nil
        )
        let service = FigmaSettingsTestService(
            refreshSnapshot: authorizationRequired,
            connectResult: .authorizationRequired,
            authorizationRequestURL: nil
        )
        var openedURL: URL?
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: service,
            openAuthorizationURL: { url in
                openedURL = url
                return true
            }
        )

        model.activateAndLoad()
        try await waitUntil { model.presentationState == .authorizationRequired && !model.isPerformingOperation }
        let refreshCountAfterActivation = await service.refreshCount()

        model.performProviderRowAction(provider: .codex, action: .connect)
        try await waitUntil { !model.isPerformingOperation }

        let connectCount = await service.connectCount()
        let refreshCount = await service.refreshCount()
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(refreshCount, refreshCountAfterActivation)
        XCTAssertNil(openedURL)
        XCTAssertNil(model.authorizationHandoffOutcome)
        XCTAssertNil(model.pendingPresentationEvent)
        XCTAssertNil(model.currentOperationKind)
        XCTAssertEqual(model.presentationState, .authorizationRequired)
        XCTAssertEqual(model.connectionMessage, "Figma authorization could not be started because Codex did not provide a sign-in link. Choose Connect to try again.")
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), definition)
        model.deactivate()
    }

    func testAuthorizationRequiredAndExpiredStatesOfferActionableRecovery() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let service = FigmaSettingsTestService(
            refreshSnapshot: .init(state: .authorizationRequired, authentication: .notLoggedIn, tools: [], lastSuccessfulCheck: nil, failureMessage: nil)
        )
        let model = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, settingsStore: store, service: service)
        model.activateAndLoad()
        try await waitUntil { !model.isPerformingOperation }
        XCTAssertEqual(model.presentationState, .authorizationRequired)
        XCTAssertEqual(model.primaryActionTitle, "Connect")
        XCTAssertFalse(model.showsSignOutAction)

        await service.setRefreshSnapshot(.init(state: .expired, authentication: .expired, tools: [], lastSuccessfulCheck: nil, failureMessage: nil))
        model.testConnection()
        try await waitUntil { !model.isPerformingOperation }
        XCTAssertEqual(model.presentationState, .expired)
        XCTAssertEqual(model.primaryActionTitle, "Connect")
        XCTAssertTrue(model.showsSignOutAction)
        model.deactivate()
    }

    func testSettingsSignOutLeavesLoggedOutStateWhenServiceCleanupFails() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let service = FigmaSettingsTestService(
            refreshSnapshot: connectedSnapshot(),
            disconnectResult: .failed
        )
        let model = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, settingsStore: store, service: service)
        model.activateAndLoad()
        try await waitUntil { model.presentationState == .connected }
        model.signOut()
        try await waitUntil { !model.isPerformingOperation }

        XCTAssertEqual(model.presentationState, .credentialRevocationRequired)
        XCTAssertEqual(model.primaryActionTitle, "")
        XCTAssertFalse(model.showsPrimaryAction)
        XCTAssertTrue(model.showsSignOutAction)
        XCTAssertFalse(model.signOutActionIsDisabled)
        XCTAssertFalse(model.showsTestAction)
        XCTAssertTrue(model.connectionMessage?.contains("did not confirm credential removal") == true)
        XCTAssertFalse(model.connectionMessage?.contains("Retry Sign Out") == true)
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), .figma())
        model.deactivate()
    }

    func testVerifiedSignOutEmitsSignOutCompletedOnlyAfterTruthIsCurrent() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: FigmaSettingsTestService(refreshSnapshot: connectedSnapshot())
        )
        model.activateAndLoad()
        try await waitUntil { model.presentationState == .connected }

        model.signOut()
        try await waitUntil { model.pendingPresentationEvent != nil }
        let event = try XCTUnwrap(model.pendingPresentationEvent)
        XCTAssertEqual(event.kind, .signOutCompleted)
        XCTAssertTrue(model.isCurrentPresentationEvent(event))
        model.consumePresentationEvent(id: event.id)
        XCTAssertNil(model.pendingPresentationEvent)
        model.deactivate()
    }

    func testVerifiedAuthenticationEmitsLoginCompletedOnce() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let service = FigmaSettingsTestService(
            refreshSnapshot: .init(state: .authorizationRequired, authentication: .notLoggedIn, tools: [], lastSuccessfulCheck: nil, failureMessage: nil)
        )
        let model = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, settingsStore: store, service: service)
        model.activateAndLoad()
        try await waitUntil { !model.isPerformingOperation }

        await service.setRefreshSnapshot(connectedSnapshot())
        model.testConnection()
        try await waitUntil { model.pendingPresentationEvent != nil }

        let event = try XCTUnwrap(model.pendingPresentationEvent)
        XCTAssertEqual(event.kind, .loginCompleted)
        XCTAssertEqual(event.windowID, 0)
        model.consumePresentationEvent(id: event.id)
        XCTAssertNil(model.pendingPresentationEvent)
        model.consumePresentationEvent(id: event.id)
        XCTAssertNil(model.pendingPresentationEvent)
        model.deactivate()
    }

    func testDeactivationInvalidatesInFlightRequestAndDoesNotReplayResult() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let service = FigmaSettingsTestService(
            refreshSnapshot: .init(state: .authorizationRequired, authentication: .notLoggedIn, tools: [], lastSuccessfulCheck: nil, failureMessage: nil),
            operationDelayNanoseconds: 100_000_000
        )
        let model = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, settingsStore: store, service: service)
        model.activateAndLoad()
        XCTAssertNotNil(model.activeRequestID)
        model.deactivate()
        XCTAssertNil(model.activeRequestID)
        XCTAssertNil(model.pendingPresentationEvent)

        model.activateAndLoad()
        try await waitUntil { !model.isPerformingOperation && model.presentationState == .authorizationRequired }
        // The reactivated request's notice must survive the cancelled first request settling later.
        XCTAssertEqual(model.connectionMessage, "Figma sign-in is required.")
        XCTAssertNil(model.pendingPresentationEvent)
        model.deactivate()
    }

    func testModalActionSeamDoesNotRepeatDestructiveOrAcknowledgementActions() {
        var presentation = FigmaMCPSettingsModalPresentation()
        var destructiveDispatches = 0
        XCTAssertTrue(presentation.requestSignOutConfirmation())
        XCTAssertTrue(presentation.cancelSignOutConfirmation())
        XCTAssertEqual(destructiveDispatches, 0)
        XCTAssertFalse(presentation.confirmSignOut { destructiveDispatches += 1 })

        XCTAssertTrue(presentation.requestSignOutConfirmation())
        XCTAssertTrue(presentation.confirmSignOut { destructiveDispatches += 1 })
        XCTAssertFalse(presentation.confirmSignOut { destructiveDispatches += 1 })
        XCTAssertEqual(destructiveDispatches, 1)

        let event = FigmaMCPSettingsPresentationEvent(
            id: UUID(), requestID: UUID(), ownerID: UUID(), windowID: 1, coordinatorGeneration: 3, kind: .loginCompleted
        )
        XCTAssertTrue(presentation.receive(event))
        XCTAssertFalse(presentation.receive(event))
        let staleEvent = FigmaMCPSettingsPresentationEvent(
            id: UUID(), requestID: UUID(), ownerID: UUID(), windowID: 1, coordinatorGeneration: 2, kind: .loginCompleted
        )
        XCTAssertFalse(presentation.receive(staleEvent, generationIsCurrent: false))
    }

    func testStaleCoordinatorResponseCannotReplayConnectedPresentation() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let service = FigmaSettingsTestService(
            refreshSnapshot: connectedSnapshot(),
            operationDelayNanoseconds: 50_000_000
        )
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let model = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, coordinator: coordinator)
        let revocationID = UUID()
        model.test_setBeforeApplyingResponse {
            coordinator.revokeForExplicitDisconnect(revocationID: revocationID)
            model.test_setBeforeApplyingResponse(nil)
        }

        model.activateAndLoad()
        try await waitUntil { !model.isPerformingOperation }

        XCTAssertEqual(model.snapshot.state, .notConfigured)
        XCTAssertNotEqual(model.presentationState, .connected)
        XCTAssertFalse(model.isAuthenticatedConnection)
        XCTAssertNil(model.pendingPresentationEvent)
        XCTAssertNil(model.authorizationHandoffOutcome)
        model.deactivate()
    }

    func testStalePresentationGenerationIsSuppressed() {
        XCTAssertFalse(MCPIntegrationsSettingsViewModel.isCurrentPresentationGeneration(
            2, currentRevision: 3, kind: .loginCompleted, runtimeRevision: 3
        ))
        XCTAssertFalse(MCPIntegrationsSettingsViewModel.isCurrentPresentationGeneration(
            2, currentRevision: 4, kind: .signOutCompleted, runtimeRevision: 4
        ))
        XCTAssertTrue(MCPIntegrationsSettingsViewModel.isCurrentPresentationGeneration(
            3, currentRevision: 4, kind: .signOutCompleted, runtimeRevision: 4
        ))
    }

    func testSignOutConfirmationCopyAndRolesAreExact() {
        XCTAssertEqual(FigmaMCPSignOutConfirmation.confirmRole, .destructive)
        XCTAssertEqual(FigmaMCPSignOutConfirmation.cancelRole, .cancel)
        XCTAssertEqual(FigmaMCPSignOutConfirmation.confirmTitle, "Stop Sessions & Sign Out")
        XCTAssertEqual(FigmaMCPSignOutConfirmation.cancelTitle, "Cancel")

        var cancelledPresentation = FigmaMCPSettingsModalPresentation()
        XCTAssertTrue(cancelledPresentation.requestSignOutConfirmation())
        cancelledPresentation.clearActiveModal()
        XCTAssertNil(cancelledPresentation.active)
        XCTAssertTrue(cancelledPresentation.consumedEventIDs.isEmpty)
    }

    func testPendingProviderConfirmationsDoNotReturnWhenActionsReappear() {
        let pending = FigmaMCPProviderConfirmationState(
            showsClaudeCodeLaunchConfirmation: true,
            providerDisconnectConfirmation: .init(provider: .openCode)
        )
        var actionsAvailable = false
        let invalidated = pending.invalidatingUnavailableActions { _, _ in actionsAvailable }
        XCTAssertFalse(invalidated.showsClaudeCodeLaunchConfirmation)
        XCTAssertNil(invalidated.providerDisconnectConfirmation)

        actionsAvailable = true
        let afterActionsReturn = invalidated.invalidatingUnavailableActions { _, _ in actionsAvailable }
        XCTAssertFalse(afterActionsReturn.showsClaudeCodeLaunchConfirmation)
        XCTAssertNil(afterActionsReturn.providerDisconnectConfirmation)
    }

    func testProviderDisconnectConfirmationUsesSharedProviderScopedContract() {
        let codex = FigmaMCPProviderDisconnectConfirmation(provider: .codex)
        XCTAssertEqual(codex.title, "Sign Out of Figma in Codex CLI?")
        XCTAssertEqual(codex.confirmTitle, "Sign Out")
        XCTAssertTrue(codex.message.contains("stop active Figma MCP sessions"))
        XCTAssertTrue(codex.message.contains("Other providers are not affected"))

        let claude = FigmaMCPProviderDisconnectConfirmation(provider: .claudeCode)
        XCTAssertEqual(claude.title, "Sign Out of Figma in Claude Code?")
        XCTAssertEqual(claude.confirmTitle, "Sign Out")
        XCTAssertEqual(
            claude.message,
            "Claude Code will clear its own Figma MCP OAuth credentials. Codex and other providers are not affected."
        )

        let cursor = FigmaMCPProviderDisconnectConfirmation(provider: .cursor)
        XCTAssertEqual(cursor.title, "Disconnect Figma in Cursor CLI?")
        XCTAssertEqual(cursor.confirmTitle, "Disconnect")
        XCTAssertTrue(cursor.message.contains("disable its Figma MCP integration"))
        XCTAssertTrue(cursor.message.contains("configuration and OAuth credentials will be kept"))
        XCTAssertEqual(cursor.cancelTitle, "Cancel")
        XCTAssertEqual(cursor.confirmRole, .destructive)
        XCTAssertEqual(cursor.cancelRole, .cancel)

        XCTAssertEqual(
            FigmaMCPProviderDisconnectConfirmation(provider: .antigravity).message,
            "Google Antigravity ACP does not support this remote Figma MCP endpoint."
        )
    }

    func testPresentationModalCopyAndArbitrationAreDeterministic() {
        XCTAssertEqual(FigmaMCPSignOutConfirmation.title, "Stop Figma MCP Sessions and Sign Out?")
        XCTAssertEqual(FigmaMCPSignOutConfirmation.message, "Active Figma MCP work in all RepoPrompt CE windows will stop. Conversations and unsent drafts will be preserved.")
        XCTAssertEqual(FigmaMCPSignOutConfirmation.confirmTitle, "Stop Sessions & Sign Out")
        XCTAssertEqual(FigmaMCPSignOutConfirmation.cancelTitle, "Cancel")
        XCTAssertEqual(FigmaMCPSignOutConfirmation.confirmRole, .destructive)
        XCTAssertEqual(FigmaMCPSignOutConfirmation.cancelRole, .cancel)
        XCTAssertEqual(FigmaMCPSettingsAcknowledgementSpec(kind: .loginCompleted).message, "Figma login completed.")
        XCTAssertEqual(FigmaMCPSettingsAcknowledgementSpec(kind: .signOutCompleted).message, "Signed out from Figma.")
        XCTAssertEqual(FigmaMCPSettingsAcknowledgementSpec(kind: .loginCompleted).dismissTitle, "OK")

        let event = FigmaMCPSettingsPresentationEvent(
            id: UUID(), requestID: UUID(), ownerID: UUID(), windowID: 4, coordinatorGeneration: 9, kind: .loginCompleted
        )
        var presentation = FigmaMCPSettingsModalPresentation()
        XCTAssertTrue(presentation.requestSignOutConfirmation())
        XCTAssertFalse(presentation.requestSignOutConfirmation())
        XCTAssertTrue(presentation.receive(event))
        XCTAssertFalse(presentation.receive(event))
        XCTAssertEqual(presentation.queuedAcknowledgement, event)
        presentation.clearActiveModal()
        presentation.advanceAfterDismissal()
        XCTAssertEqual(presentation.active, .acknowledgement(event))
        presentation.clearActiveModal()
        presentation.advanceAfterDismissal()
        XCTAssertNil(presentation.active)
    }

    func testLoginSpinnerUsesOperationSpecificAccessibility() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let service = FigmaSettingsTestService(
            refreshSnapshot: .init(state: .authorizationRequired, authentication: .notLoggedIn, tools: [], lastSuccessfulCheck: nil, failureMessage: nil),
            operationDelayNanoseconds: 100_000_000
        )
        let model = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, settingsStore: store, service: service)
        model.activateAndLoad()
        await Task.yield()
        XCTAssertEqual(model.primaryActionAccessibilityLabel, "Checking Figma connection")
        XCTAssertTrue(model.primaryActionIsLoading)
        XCTAssertTrue(model.primaryActionIsDisabled)
        try await waitUntil { !model.isPerformingOperation }

        model.testConnection()
        await Task.yield()
        XCTAssertEqual(model.primaryActionAccessibilityLabel, "Checking Figma login")
        XCTAssertTrue(model.primaryActionIsLoading)
        XCTAssertTrue(model.primaryActionIsDisabled)
        try await waitUntil { !model.isPerformingOperation }
        model.deactivate()
    }

    func testOtherWindowShowsNonActionableBusyStateAndClearsStaleNotice() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let service = FigmaSettingsTestService(
            refreshSnapshot: .init(state: .authorizationRequired, authentication: .notLoggedIn, tools: [], lastSuccessfulCheck: nil, failureMessage: nil),
            operationDelayNanoseconds: 100_000_000
        )
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let firstWindow = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, windowID: 1, coordinator: coordinator)
        let secondWindow = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, windowID: 2, coordinator: coordinator)
        firstWindow.activateAndLoad()
        await Task.yield()
        secondWindow.activateAndLoad()

        try await waitUntil { secondWindow.presentationState == .busy }
        XCTAssertFalse(secondWindow.showsPrimaryAction)
        XCTAssertFalse(secondWindow.showsSignOutAction)
        XCTAssertEqual(secondWindow.connectionMessage, FigmaMCPSettingsActionResult.busy.notice)

        try await waitUntil { !firstWindow.isPerformingOperation && secondWindow.presentationState == .authorizationRequired }
        XCTAssertNil(secondWindow.connectionMessage)
        firstWindow.deactivate()
        secondWindow.deactivate()
    }

    func testOtherWindowObservesStateWithoutAcknowledgement() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let service = FigmaSettingsTestService(
            refreshSnapshot: .init(state: .authorizationRequired, authentication: .notLoggedIn, tools: [], lastSuccessfulCheck: nil, failureMessage: nil)
        )
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let firstWindow = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, windowID: 1, coordinator: coordinator)
        let secondWindow = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, windowID: 2, coordinator: coordinator)
        firstWindow.activateAndLoad()
        try await waitUntil { !firstWindow.isPerformingOperation }
        secondWindow.activateAndLoad()
        try await waitUntil { !secondWindow.isPerformingOperation }

        await service.setRefreshSnapshot(connectedSnapshot())
        firstWindow.testConnection()
        try await waitUntil { firstWindow.pendingPresentationEvent != nil }
        try await waitUntil { secondWindow.isAuthenticatedConnection }

        XCTAssertEqual(firstWindow.pendingPresentationEvent?.kind, .loginCompleted)
        XCTAssertNil(secondWindow.pendingPresentationEvent)
        firstWindow.deactivate()
        secondWindow.deactivate()
    }

    func testVoiceOverLabelsRemainStableForLoadingAndSignOutActions() throws {
        let fresh = try MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, settingsStore: makeStore())
        XCTAssertEqual(fresh.primaryActionAccessibilityLabel, "Connect")
        XCTAssertEqual(fresh.primaryActionAccessibilityHint, "Checks for an existing Figma connection, then starts validated Figma sign in if needed.")
        XCTAssertTrue(fresh.signOutActionAccessibilityHint.contains("Codex sign-in remains unchanged"))
        XCTAssertEqual(SettingsConnectionStatus.connected.label, "Connected")
        XCTAssertEqual(SettingsConnectionStatus.notConnected.label, "Not Connected")
        XCTAssertEqual(SettingsConnectionStatus.connecting.label, "Connecting")
        XCTAssertEqual(SettingsConnectionStatus.unavailable.label, "Unavailable")
        XCTAssertEqual(SettingsConnectionStatus.error.label, "Error")
    }

    func testProviderRowsHaveStableOrderAndIndependentActionAvailability() throws {
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(provider: .claudeCode),
            providerRegistration(
                provider: .openCode,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .unverified(.noStructuredProofContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            providerRegistration(
                provider: .cursor,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .unverified(.noStructuredProofContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            )
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )
        let rows = model.providerRows

        XCTAssertEqual(rows.map(\.id), [.codex, .claudeCode, .openCode, .cursor, .grokBuild, .antigravity, .devin])
        XCTAssertEqual(rows.map(\.displayName), ["Codex CLI", "Claude Code CLI", "OpenCode CLI", "Cursor CLI", "Grok Build CLI", "Google Antigravity ACP", "Devin CLI"])
        XCTAssertEqual(rows.map(\.status), [.needsLogin, .needsLogin, .needsLogin, .needsLogin, .currentlyUnsupported, .currentlyUnsupported, .currentlyUnsupported])
        XCTAssertEqual(rows.first(where: { $0.id == .claudeCode })?.actions.map(\.id), [.connect])
        XCTAssertTrue(rows.first(where: { $0.id == .openCode })?.actions.isEmpty == true)
        XCTAssertTrue(rows.first(where: { $0.id == .cursor })?.actions.isEmpty == true)
        XCTAssertTrue(rows.dropFirst().dropLast().allSatisfy { !$0.isError && $0.status.capsuleStatus == .notConnected })
        XCTAssertTrue(rows.last?.actions.isEmpty == true)
        XCTAssertEqual(rows.first(where: { $0.id == .grokBuild })?.message, "Grok Build CLI does currently not support Figma MCP in RepoPrompt CE.")
        XCTAssertEqual(FigmaMCPProviderRowStatus.currentlyUnsupported.label, "Currently unsupported")
        XCTAssertEqual(FigmaMCPProviderRowStatus.currentlyUnsupported.capsuleStatus, .notConnected)
        XCTAssertEqual(FigmaMCPProviderRowStatus.unsupported.label, "Currently unsupported")
        XCTAssertEqual(FigmaMCPProviderRowStatus.unsupported.capsuleStatus, .notConnected)
        XCTAssertEqual(FigmaMCPProviderRowStatus.error.label, "Needs login")
        XCTAssertEqual(FigmaMCPProviderRowStatus.error.capsuleStatus, .notConnected)
        XCTAssertEqual(FigmaMCPProviderRowStatus.connecting.label, "Connecting…")
        XCTAssertEqual(FigmaMCPProviderRowStatus.connecting.capsuleStatus, .connecting)
    }

    func testProductionOpenCodeDevinAndAntigravityRowsAreActionlessAndDoNotBorrowClaudeAuthority() throws {
        let graph = FigmaMCPTestGraph.make()
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: graph, cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore()
        )
        let rows = model.providerRows
        XCTAssertEqual(rows.count, 7)
        let openCode = try XCTUnwrap(rows.first(where: { $0.id == .openCode }))
        XCTAssertEqual(openCode.status, .currentlyUnsupported)
        XCTAssertEqual(openCode.message, "OpenCode CLI does currently not support Figma MCP in RepoPrompt CE.")
        XCTAssertTrue(openCode.actions.isEmpty)
        XCTAssertNil(openCode.verifiedAt)
        XCTAssertNil(openCode.connectionSummary)
        XCTAssertFalse(openCode.isError)
        let devin = try XCTUnwrap(rows.first(where: { $0.id == .devin }))
        XCTAssertEqual(devin.status, .currentlyUnsupported)
        XCTAssertEqual(devin.message, "Devin CLI does currently not support Figma MCP in RepoPrompt CE.")
        XCTAssertTrue(devin.actions.isEmpty)
        XCTAssertNil(devin.verifiedAt)
        XCTAssertNil(devin.connectionSummary)
        XCTAssertFalse(devin.isError)
        let antigravity = try XCTUnwrap(rows.first(where: { $0.id == .antigravity }))
        XCTAssertEqual(antigravity.status, .currentlyUnsupported)
        XCTAssertEqual(antigravity.message, "Google Antigravity ACP does currently not support Figma MCP in RepoPrompt CE.")
        XCTAssertTrue(antigravity.actions.isEmpty)
        XCTAssertNil(antigravity.verifiedAt)
        XCTAssertNil(antigravity.connectionSummary)
        XCTAssertFalse(antigravity.isError)
        XCTAssertEqual(rows.count(where: { $0.id == .claudeCode }), 1)
        XCTAssertEqual(rows.last?.id, .devin)

        model.activateAndLoad()
        defer { model.deactivate() }
        for action in [FigmaMCPProviderRowAction.connect, .cancelLogin, .testConnection, .disconnect] {
            model.performProviderRowAction(provider: .devin, action: action)
        }
        XCTAssertTrue(model.providerRows.first(where: { $0.id == .devin })?.actions.isEmpty == true)
    }

    func testProductionCapabilityDevinRemainsUnsupportedAfterAsyncAvailabilityRefresh() async throws {
        let registration = ExternalMCPProviderRegistration(
            provider: .devin,
            adapter: VMFailClosedAdapter(runtimeProvider: .devin),
            figmaCapabilities: .adapterOnly(for: .devin)
        )
        let coordinator = try makeProviderCoordinator(registrations: [registration])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil {
            guard let state = coordinator.state(for: .devin) else { return false }
            if case .unavailable = state { return true }
            return false
        }

        let row = try XCTUnwrap(model.providerRows.first { $0.id == .devin })
        XCTAssertTrue(row.isCLIAvailable)
        XCTAssertEqual(row.status, .currentlyUnsupported)
        XCTAssertFalse(row.canExpand)
        XCTAssertTrue(row.actions.isEmpty)
        XCTAssertEqual(row.message, "Devin CLI does currently not support Figma MCP in RepoPrompt CE.")
        XCTAssertTrue(model.providerRowGroups.unsupported.contains { $0.id == .devin })
        XCTAssertFalse(model.providerRowGroups.notConnected.contains { $0.id == .devin })
    }

    func testInjectedLoginOnlyDevinDispatchesConnectWithoutPublishingProofOrSignOut() async throws {
        let driver = VMProviderLoginDriver(provider: .devin)
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .devin,
                driver: driver,
                proofSupport: .unverified(.noStructuredProofContract),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            )
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.rowActions(.devin, in: model).map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .devin, action: .connect)
        try await waitUntilAsync { await driver.beginCount == 1 }
        try await waitUntil {
            self.rowMessage(.devin, in: model)?.contains("cannot verify current Figma access") == true
        }

        let row = try XCTUnwrap(model.providerRows.first { $0.id == .devin })
        XCTAssertEqual(row.status, .needsLogin)
        XCTAssertNil(row.verifiedAt)
        XCTAssertEqual(row.actions.map(\.id), [.connect])
        XCTAssertFalse(coordinator.canSignOut(provider: .devin))
        model.performProviderRowAction(provider: .devin, action: .disconnect)
        XCTAssertFalse(coordinator.canSignOut(provider: .devin))
    }

    func testInjectedVerifiedDevinDispatchesCancelForItsActiveAttempt() async throws {
        let driver = VMProviderLoginDriver(provider: .devin, waitsForCompletion: true)
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .devin,
                driver: driver,
                proofSupport: .unverified(.noStructuredProofContract),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            )
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.rowActions(.devin, in: model).map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .devin, action: .connect)
        try await waitUntil { self.rowActions(.devin, in: model).map(\.id) == [.cancelLogin] }
        model.performProviderRowAction(provider: .devin, action: .cancelLogin)
        try await waitUntilAsync { await driver.cancelCount == 1 }
        XCTAssertFalse(coordinator.canSignOut(provider: .devin))
    }

    func testInjectedVerifiedDevinDispatchesStructuredTestAndRevocation() async throws {
        let logoutState = VMProviderLogoutState()
        let statusCounter = VMStructuredStatusCounter()
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .devin,
                revocationSupport: .verified(providerEvidence(for: .devin)),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract),
                proofAuthentication: .providerOwned,
                statusCounter: statusCounter,
                logoutState: logoutState
            )
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { coordinator.canSignOut(provider: .devin) }
        XCTAssertEqual(rowActions(.devin, in: model).map(\.id), [.testConnection, .disconnect])

        let checksBeforeTest = await statusCounter.value
        model.performProviderRowAction(provider: .devin, action: .testConnection)
        try await waitUntilAsync { await statusCounter.value > checksBeforeTest }
        try await waitUntil { coordinator.canSignOut(provider: .devin) }

        model.performProviderRowAction(provider: .devin, action: .disconnect)
        try await waitUntilAsync { await logoutState.callCount == 1 }
        try await waitUntil { self.rowStatus(.devin, in: model) == .needsLogin }
        XCTAssertFalse(coordinator.canSignOut(provider: .devin))
    }

    func testClaudeAndOpenCodeLaunchFailureShowsNeedsLoginAndRetriesConnect() async throws {
        for (provider, displayName) in [
            (ExternalMCPRuntimeProvider.claudeCode, "Claude Code CLI"),
            (.openCode, "OpenCode CLI")
        ] {
            let driver = VMProviderLoginDriver(provider: provider, result: .launchFailed)
            let coordinator = try makeProviderCoordinator(registrations: [
                providerRegistration(provider: provider, driver: driver)
            ])
            let model = try MCPIntegrationsSettingsViewModel(
                externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
                settingsStore: makeStore(),
                providerConnectionCoordinator: coordinator
            )

            model.activateAndLoad()
            defer { model.deactivate() }
            try await waitUntil { self.rowActions(provider, in: model).map(\.id) == [.connect] }
            model.performProviderRowAction(provider: provider, action: .connect)
            try await waitUntil {
                self.rowMessage(provider, in: model)?.localizedCaseInsensitiveContains("could not be launched") == true
            }

            let row = try XCTUnwrap(model.providerRows.first { $0.id == provider })
            XCTAssertEqual(row.displayName, displayName)
            XCTAssertEqual(row.status.label, "Needs login")
            XCTAssertEqual(row.status.capsuleStatus, .notConnected)
            XCTAssertFalse(row.isError)
            XCTAssertTrue(row.message.localizedCaseInsensitiveContains("could not be launched"))
            XCTAssertEqual(row.actions.map(\.id), [.connect])
            XCTAssertEqual(row.actions.map(\.title), ["Connect"])
            XCTAssertFalse(row.actions.first?.isDisabled ?? true)

            model.performProviderRowAction(provider: provider, action: .connect)
            try await waitUntilAsync { await driver.beginCount == 2 }
        }
    }

    func testNonCodexProviderProcessFailureUsesNeedsLoginPresentation() async throws {
        let driver = VMProviderLoginDriver(provider: .openCode, result: .exited(status: 1))
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(provider: .openCode, driver: driver)
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        try await waitUntil { self.rowActions(.openCode, in: model).map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .openCode, action: .connect)
        try await waitUntil {
            self.rowMessage(.openCode, in: model)?.localizedCaseInsensitiveContains("command failed") == true
        }

        let row = try XCTUnwrap(model.providerRows.first { $0.id == .openCode })
        XCTAssertEqual(row.status.label, "Needs login")
        XCTAssertEqual(row.status.capsuleStatus, .notConnected)
        XCTAssertFalse(row.isError)
        XCTAssertTrue(row.message.localizedCaseInsensitiveContains("command failed"))
        XCTAssertEqual(row.actions.map(\.id), [.connect])
        model.deactivate()
    }

    func testNonCodexLoginDoesNotMutateGlobalSettingsStore() async throws {
        let store = try makeStore()
        let definition = ExternalMCPIntegrationDefinition.figma()
        XCTAssertTrue(store.setExternalMCPIntegration(definition))
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .openCode,
                driver: VMProviderLoginDriver(provider: .openCode, result: .exited(status: 0))
            )
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: store,
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        try await waitUntil { self.rowActions(.openCode, in: model).map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .openCode, action: .connect)
        try await waitUntil {
            self.rowMessage(.openCode, in: model)?.localizedCaseInsensitiveContains("finished") == true
        }

        XCTAssertEqual(store.externalMCPIntegration(for: .figma), definition)
        model.deactivate()
    }

    func testVerifiedProviderRegistrationOffersConnectUntilProofExists() throws {
        let coordinator = try makeProviderCoordinator(registrations: [providerRegistration(provider: .claudeCode)])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )
        let row = try XCTUnwrap(model.providerRows.first { $0.id == claudeProvider })

        XCTAssertEqual(row.status, .needsLogin)
        XCTAssertEqual(row.status.label, "Needs login")
        XCTAssertEqual(row.status.capsuleStatus, .notConnected)
        XCTAssertEqual(row.actions.map(\.id), [.connect])
        XCTAssertEqual(row.actions.first?.title, "Connect")
        XCTAssertEqual(row.actions.first?.accessibilityLabel, "Connect Figma for Claude Code CLI")
        XCTAssertNil(row.verifiedAt)
        XCTAssertFalse(row.isError)
    }

    func testConnectedClaudeRowOffersTestConnectionAndSignOut() async throws {
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(provider: .claudeCode, proofAuthentication: .providerOwned)
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        try await waitUntil { self.rowStatus(.claudeCode, in: model) == .connected }

        let actions = rowActions(.claudeCode, in: model)
        XCTAssertEqual(actions.map(\.id), [.testConnection, .disconnect])
        XCTAssertEqual(actions.map(\.title), ["Test Connection", "Sign Out"])
        XCTAssertEqual(actions.last?.accessibilityLabel, "Sign Out of Figma in Claude Code CLI")
        XCTAssertEqual(model.providerRows.first { $0.id == .claudeCode }?.connectionSummary?.rows, [
            .connection("Figma MCP"),
            .authentication("Figma sign-in verified through Claude Code CLI"),
            .credentialOwner("Managed by Claude Code CLI")
        ])
        XCTAssertEqual(model.integrationCardStatus, .connected)
        model.deactivate()
    }

    func testAggregatePrioritizesCheckingOverConnected() async throws {
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(provider: .claudeCode, proofAuthentication: .providerOwned),
            providerRegistration(provider: .openCode, delayNanoseconds: 1_000_000_000)
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        try await waitUntil {
            self.rowStatus(.claudeCode, in: model) == .connected
                && self.rowStatus(.openCode, in: model) == .checking
        }

        XCTAssertEqual(model.integrationCardStatus, .connecting)
        XCTAssertEqual(model.integrationCardStatusLabelOverride, "Checking")

        try await waitUntil { self.rowStatus(.openCode, in: model) != .checking }
        XCTAssertEqual(model.integrationCardStatus, .connected)
        XCTAssertEqual(model.integrationCardStatusLabelOverride, "Connected")
        model.deactivate()
    }

    func testCodexRefreshMakesAggregateCheckingEvenWhenClaudeIsConnected() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(provider: .claudeCode, proofAuthentication: .providerOwned)
        ])
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: store,
            service: FigmaSettingsTestService(operationDelayNanoseconds: 1_000_000_000),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        try await waitUntil {
            self.rowStatus(.claudeCode, in: model) == .connected && model.isPerformingOperation
        }

        XCTAssertEqual(model.integrationCardStatus, .connecting)
        XCTAssertEqual(model.integrationCardStatusLabelOverride, "Checking")
        model.deactivate()
    }

    func testConnectedClaudeRowOmitsSignOutWithoutVerifiedRevocationCapability() async throws {
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .claudeCode,
                proofSupport: .verified(providerEvidence(for: .claudeCode)),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract),
                proofAuthentication: .providerOwned
            )
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        try await waitUntil { self.rowStatus(.claudeCode, in: model) == .connected }

        XCTAssertEqual(rowActions(.claudeCode, in: model).map(\.id), [.testConnection])
        model.deactivate()
    }

    func testProviderLoginCancelAndTestUseSharedCoordinatorStateOnly() async throws {
        let store = try makeStore()
        let driver = VMProviderLoginDriver(provider: .claudeCode, waitsForCompletion: true)
        let coordinator = try makeProviderCoordinator(registrations: [providerRegistration(provider: .claudeCode, driver: driver)])
        var navigationCount = 0
        let legacy = VMLegacyStatusProbe(result: .verified(.init(
            integrationID: ExternalMCPIntegrationTarget.figma.integrationID,
            connection: .connected,
            authentication: .providerOwned
        )))
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: store,
            providerConnectionCoordinator: coordinator,
            providerStatusService: legacy,
            openCLIProviders: { navigationCount += 1 }
        )

        model.activateAndLoad()
        try await waitUntil { self.rowActions(.claudeCode, in: model).map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .claudeCode, action: .connect)
        try await waitUntil { self.rowActions(.claudeCode, in: model).map(\.id) == [.cancelLogin] }
        let beginCount = await driver.beginCount
        XCTAssertEqual(beginCount, 1)

        model.performProviderRowAction(provider: .claudeCode, action: .cancelLogin)
        try await waitUntil {
            if case let .notVerified(_, notice) = coordinator.state(for: .claudeCode) {
                return notice == .cancelledAuthenticationStateUnknown
            }
            return false
        }
        let cancelCount = await driver.cancelCount
        XCTAssertEqual(cancelCount, 1)

        let retryAction = try XCTUnwrap(model.providerRows.first { $0.id == claudeProvider }?.actions.first)
        XCTAssertEqual(retryAction.id, .connect)
        XCTAssertEqual(retryAction.title, "Retry Connection")
        XCTAssertEqual(retryAction.systemImage, "arrow.clockwise")
        XCTAssertEqual(retryAction.accessibilityLabel, "Retry Figma connection for Claude Code CLI")

        model.performProviderRowAction(provider: .claudeCode, action: .testConnection)
        XCTAssertEqual(rowStatus(.claudeCode, in: model), .needsLogin)
        XCTAssertEqual(navigationCount, 0)
        XCTAssertEqual(legacy.callCount, 0)
        XCTAssertEqual(model.providerRows.first { $0.id == claudeProvider }?.actions.map(\.id), [.connect])
        model.deactivate()
    }

    func testTypedNegativeStatusesAllUseNeedsLoginPresentation() async throws {
        for outcome in [FigmaMCPProviderStructuredStatusOutcome.unauthenticated, .expired] {
            let coordinator = try makeProviderCoordinator(registrations: [providerRegistration(provider: .openCode, outcome: outcome)])
            let model = try MCPIntegrationsSettingsViewModel(
                externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
                settingsStore: makeStore(),
                providerConnectionCoordinator: coordinator
            )
            model.activateAndLoad()
            try await waitUntil { self.rowStatus(.openCode, in: model) == .needsLogin }
            XCTAssertEqual(rowActions(.openCode, in: model).map(\.id), [.connect])
            model.deactivate()
        }

        for outcome in [FigmaMCPProviderStructuredStatusOutcome.unknown, .stale] {
            let coordinator = try makeProviderCoordinator(registrations: [providerRegistration(provider: .openCode, outcome: outcome)])
            let model = try MCPIntegrationsSettingsViewModel(
                externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
                settingsStore: makeStore(),
                providerConnectionCoordinator: coordinator
            )
            model.activateAndLoad()
            try await waitUntil { self.rowStatus(.openCode, in: model) == .needsLogin }
            XCTAssertEqual(rowActions(.openCode, in: model).map(\.id), [.connect])
            model.deactivate()
        }
    }

    func testVerifiedLoginWithUnverifiedProofExposesConnectWithoutStatusProbe() async throws {
        let checker = VMStructuredStatusCounter()
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .openCode,
                proofSupport: .unverified(.noStructuredProofContract),
                runtimeBindingSupport: .unverified(.noStructuredProofContract),
                statusCounter: checker
            )
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        try await waitUntil { self.rowStatus(.openCode, in: model) == .needsLogin }
        XCTAssertEqual(rowActions(.openCode, in: model).map(\.id), [.connect])
        let checkerValue = await checker.value
        XCTAssertEqual(checkerValue, 0)
        model.deactivate()
    }

    func testStructuredProviderProofConnectsMatchingRowAndAggregateWithoutSharingProviderState() async throws {
        let store = try makeStore()
        let definition = ExternalMCPIntegrationDefinition.figma()
        XCTAssertTrue(store.setExternalMCPIntegration(definition))
        let evidence = providerEvidence(for: .openCode)
        let checker = VMStructuredStatusCounter()
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .openCode,
                proofSupport: .verified(evidence),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract),
                proofAuthentication: .providerOwned,
                statusCounter: checker
            ),
            providerRegistration(provider: .cursor, outcome: .unknown, delayNanoseconds: 100_000_000),
            providerRegistration(provider: .claudeCode, outcome: .unknown, delayNanoseconds: 100_000_000)
        ])
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: store,
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        try await waitUntil { self.rowStatus(.openCode, in: model) == .connected }
        XCTAssertEqual(rowActions(.openCode, in: model).map(\.id), [.testConnection])
        XCTAssertEqual(rowActions(.openCode, in: model).map(\.title), ["Test Connection"])
        try await waitUntil {
            self.rowStatus(.cursor, in: model) != .checking
                && self.rowStatus(.claudeCode, in: model) != .checking
        }
        XCTAssertEqual(model.integrationCardStatus, .connected)
        XCTAssertNotEqual(rowStatus(.cursor, in: model), .connected)
        XCTAssertNotEqual(rowStatus(.claudeCode, in: model), .connected)

        model.performProviderRowAction(provider: .openCode, action: .testConnection)
        try await waitUntilAsync { await checker.value >= 2 }
        XCTAssertEqual(rowStatus(.openCode, in: model), .connected)
        model.deactivate()
    }

    func testProviderConnectionTestRetainsConnectedRowsWhileChecking() async throws {
        let checker = VMStructuredStatusCounter()
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .openCode,
                proofAuthentication: .providerOwned,
                statusCounter: checker,
                delayNanoseconds: 500_000_000
            )
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.rowStatus(.openCode, in: model) == .connected }
        let connectedRow = try XCTUnwrap(model.providerRows.first { $0.id == .openCode })
        XCTAssertTrue(model.providerRowGroups.connected.contains { $0.id == .openCode })

        model.performProviderRowAction(provider: .openCode, action: .testConnection)
        try await waitUntilAsync {
            await checker.value >= 2 && self.rowStatus(.openCode, in: model) == .checking
        }

        let testingRow = try XCTUnwrap(model.providerRows.first { $0.id == .openCode })
        XCTAssertTrue(testingRow.isTestingConnection)
        XCTAssertEqual(testingRow.verifiedAt, connectedRow.verifiedAt)
        XCTAssertEqual(testingRow.timestampPresentation, connectedRow.timestampPresentation)
        XCTAssertEqual(testingRow.connectionSummary?.rows, [
            .connection("Figma MCP"),
            .authentication("Checking Figma sign-in through OpenCode CLI"),
            .credentialOwner("Managed by OpenCode CLI")
        ])
        XCTAssertEqual(testingRow.message, "Checking provider-owned Figma status through OpenCode CLI.")
        XCTAssertEqual(testingRow.actions.map(\.id), connectedRow.actions.map(\.id))
        XCTAssertTrue(testingRow.actions.allSatisfy(\.isDisabled))
        XCTAssertEqual(testingRow.actions.first(where: { $0.id == .testConnection })?.isLoading, true)
        XCTAssertTrue(model.providerRowGroups.connected.contains { $0.id == .openCode })
        XCTAssertFalse(model.providerRowGroups.notConnected.contains { $0.id == .openCode })

        model.updateCLIAvailability(.none)
        XCTAssertFalse(model.providerRowGroups.connected.contains { $0.id == .openCode })
        XCTAssertTrue(model.providerRowGroups.notConnected.contains { $0.id == .openCode })
        XCTAssertTrue(model.providerRowGroups.unsupported.contains { $0.id == .grokBuild })
        model.updateCLIAvailability(FigmaSettingsTestCLIAvailability.withoutCodex)
        XCTAssertTrue(model.providerRowGroups.connected.contains { $0.id == .openCode })

        try await waitUntil { self.rowStatus(.openCode, in: model) == .connected }
        XCTAssertFalse(model.providerRows.first { $0.id == .openCode }?.isTestingConnection ?? true)
        XCTAssertTrue(model.providerRowGroups.connected.contains { $0.id == .openCode })
    }

    func testFailedProviderConnectionTestLeavesConnectedGroupAfterSettlement() async throws {
        let checker = VMStructuredStatusCounter()
        let logoutState = VMProviderLogoutState()
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .openCode,
                proofAuthentication: .providerOwned,
                statusCounter: checker,
                logoutState: logoutState,
                delayNanoseconds: 150_000_000
            )
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.rowStatus(.openCode, in: model) == .connected }
        await logoutState.logout()

        model.performProviderRowAction(provider: .openCode, action: .testConnection)
        try await waitUntilAsync {
            await checker.value >= 2 && self.rowStatus(.openCode, in: model) == .checking
        }
        XCTAssertTrue(model.providerRowGroups.connected.contains { $0.id == .openCode })

        try await waitUntil { self.rowStatus(.openCode, in: model) == .needsLogin }
        XCTAssertFalse(model.providerRowGroups.connected.contains { $0.id == .openCode })
        XCTAssertTrue(model.providerRowGroups.notConnected.contains { $0.id == .openCode })
    }

    func testClaudeProviderConnectionTestUsesTestingCopyAndRetainsConnectedPresentation() async throws {
        let checker = VMStructuredStatusCounter()
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .claudeCode,
                proofAuthentication: .providerOwned,
                statusCounter: checker,
                delayNanoseconds: 150_000_000
            )
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.rowStatus(.claudeCode, in: model) == .checking }
        XCTAssertEqual(
            model.providerRows.first { $0.id == .claudeCode }?.message,
            "Checking provider-reported Figma status through Claude Code."
        )
        try await waitUntil { self.rowStatus(.claudeCode, in: model) == .connected }

        XCTAssertTrue(coordinator.recheckStatus(provider: .claudeCode))
        try await waitUntilAsync {
            await checker.value >= 2 && self.rowStatus(.claudeCode, in: model) == .checking
        }
        let refreshRow = try XCTUnwrap(model.providerRows.first { $0.id == .claudeCode })
        XCTAssertEqual(refreshRow.message, "Checking provider-reported Figma status through Claude Code.")
        XCTAssertFalse(refreshRow.isTestingConnection)
        XCTAssertTrue(refreshRow.actions.isEmpty)
        try await waitUntil { self.rowStatus(.claudeCode, in: model) == .connected }
        let connectedRow = try XCTUnwrap(model.providerRows.first { $0.id == .claudeCode })

        model.performProviderRowAction(provider: .claudeCode, action: .testConnection)
        try await waitUntilAsync {
            await checker.value >= 3 && self.rowStatus(.claudeCode, in: model) == .checking
        }

        let testingRow = try XCTUnwrap(model.providerRows.first { $0.id == .claudeCode })
        XCTAssertTrue(testingRow.isTestingConnection)
        XCTAssertEqual(testingRow.verifiedAt, connectedRow.verifiedAt)
        XCTAssertEqual(testingRow.timestampPresentation, connectedRow.timestampPresentation)
        XCTAssertEqual(testingRow.connectionSummary?.rows, [
            .connection("Figma MCP"),
            .authentication("Checking Figma sign-in through Claude Code CLI"),
            .credentialOwner("Managed by Claude Code CLI")
        ])
        XCTAssertEqual(testingRow.message, "Testing Figma connection…")
        XCTAssertEqual(testingRow.actions.map(\.id), connectedRow.actions.map(\.id))
        XCTAssertTrue(testingRow.actions.allSatisfy(\.isDisabled))
        XCTAssertEqual(testingRow.actions.first(where: { $0.id == .testConnection })?.isLoading, true)

        try await waitUntil { self.rowStatus(.claudeCode, in: model) == .connected }
        XCTAssertFalse(model.providerRows.first { $0.id == .claudeCode }?.isTestingConnection ?? true)
    }

    func testProviderConnectionTestRetainsConnectedRowsInAnotherSettingsWindow() async throws {
        let checker = VMStructuredStatusCounter()
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(
                provider: .openCode,
                proofAuthentication: .providerOwned,
                statusCounter: checker,
                delayNanoseconds: 150_000_000
            )
        ])
        let firstWindow = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )
        let secondWindow = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )

        firstWindow.activateAndLoad()
        secondWindow.activateAndLoad()
        defer {
            firstWindow.deactivate()
            secondWindow.deactivate()
        }
        try await waitUntil {
            self.rowStatus(.openCode, in: firstWindow) == .connected
                && self.rowStatus(.openCode, in: secondWindow) == .connected
        }
        let secondConnectedRow = try XCTUnwrap(secondWindow.providerRows.first { $0.id == .openCode })

        firstWindow.performProviderRowAction(provider: .openCode, action: .testConnection)
        try await waitUntilAsync {
            await checker.value >= 2 && self.rowStatus(.openCode, in: secondWindow) == .checking
        }

        let secondTestingRow = try XCTUnwrap(secondWindow.providerRows.first { $0.id == .openCode })
        XCTAssertTrue(secondTestingRow.isTestingConnection)
        XCTAssertEqual(secondTestingRow.verifiedAt, secondConnectedRow.verifiedAt)
        XCTAssertEqual(secondTestingRow.actions.map(\.id), secondConnectedRow.actions.map(\.id))
        XCTAssertTrue(secondTestingRow.actions.allSatisfy(\.isDisabled))
        XCTAssertEqual(secondTestingRow.actions.first(where: { $0.id == .testConnection })?.isLoading, true)
    }

    func testAuthenticatedSnapshotCannotBecomeProviderProofAndBareSnapshotServiceIsIgnored() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(provider: .cursor, proofAuthentication: .authenticated)
        ])
        let legacy = VMLegacyStatusProbe(result: .verified(.init(
            integrationID: ExternalMCPIntegrationTarget.figma.integrationID,
            connection: .connected,
            authentication: .authenticated
        )))
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: store,
            providerConnectionCoordinator: coordinator,
            providerStatusService: legacy
        )

        model.activateAndLoad()
        try await waitUntil { self.rowStatus(.cursor, in: model) == .needsLogin }
        XCTAssertTrue(rowActions(.cursor, in: model).isEmpty)
        XCTAssertNotEqual(rowStatus(.cursor, in: model), .connected)
        XCTAssertEqual(legacy.callCount, 0)
        model.deactivate()
    }

    func testOneProviderLoginDoesNotChangeAnotherProviderOrAnotherSettingsWindow() async throws {
        let openDriver = VMProviderLoginDriver(provider: .openCode, waitsForCompletion: true)
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(provider: .openCode, driver: openDriver),
            providerRegistration(provider: .cursor, outcome: .unknown)
        ])
        let firstWindow = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex, windowID: 1, providerConnectionCoordinator: coordinator)
        let secondWindow = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex, windowID: 2, providerConnectionCoordinator: coordinator)
        firstWindow.activateAndLoad()
        secondWindow.activateAndLoad()
        try await waitUntil { self.rowActions(.openCode, in: firstWindow).map(\.id) == [.connect] }

        firstWindow.performProviderRowAction(provider: openCodeProvider, action: .connect)
        try await waitUntil { self.rowStatus(.openCode, in: secondWindow) == .authorizing }
        XCTAssertEqual(rowStatus(.cursor, in: secondWindow), .needsLogin)
        firstWindow.deactivate()
        let cancelCount = await openDriver.cancelCount
        XCTAssertEqual(cancelCount, 0)
        XCTAssertEqual(rowStatus(.openCode, in: secondWindow), .authorizing)
        secondWindow.deactivate()
        await coordinator.cancelLogin(provider: .openCode)
    }

    func testGrokBuildIsNeutralUnsupportedAndActionless() throws {
        let coordinator = try makeProviderCoordinator(registrations: [])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )
        let row = try XCTUnwrap(model.providerRows.first { $0.id == .grokBuild })
        XCTAssertEqual(row.status, .currentlyUnsupported)
        XCTAssertEqual(row.status.label, "Currently unsupported")
        XCTAssertEqual(row.status.capsuleStatus, .notConnected)
        XCTAssertTrue(row.actions.isEmpty)
        XCTAssertNil(row.verifiedAt)
        XCTAssertFalse(row.isError)
        XCTAssertEqual(model.integrationCardStatus, .notConnected)
        XCTAssertEqual(model.integrationCardStatusLabelOverride, "Needs Login")
    }

    func testProviderRowsNeverExposeRefreshAndCheckingRowsHaveNoActions() async throws {
        let coordinator = try makeProviderCoordinator(registrations: [
            providerRegistration(provider: .claudeCode, delayNanoseconds: 100_000_000),
            providerRegistration(provider: .openCode, delayNanoseconds: 100_000_000),
            providerRegistration(provider: .cursor, delayNanoseconds: 100_000_000)
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: coordinator
        )
        model.activateAndLoad()
        try await waitUntil {
            [claudeProvider, openCodeProvider].allSatisfy { self.rowStatus($0, in: model) == .checking }
                && self.rowStatus(cursorProvider, in: model) == .needsLogin
        }
        for provider in [claudeProvider, openCodeProvider, cursorProvider, .grokBuild] {
            XCTAssertTrue(rowActions(provider, in: model).allSatisfy { action in
                !action.title.localizedCaseInsensitiveContains("refresh")
                    && !action.accessibilityLabel.localizedCaseInsensitiveContains("refresh")
                    && !action.accessibilityHint.localizedCaseInsensitiveContains("refresh")
            })
        }
        model.deactivate()
    }

    private func makeProviderCoordinator(
        registrations: [ExternalMCPProviderRegistration]
    ) throws -> FigmaMCPProviderConnectionCoordinator {
        let registry = try ExternalMCPAdapterRegistry(registrations: registrations)
        return FigmaMCPProviderConnectionCoordinator(
            registry: registry, sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }),
            terminationObserver: VMSettingsTerminationObserver()
        )
    }

    private func providerRegistration(
        provider: ExternalMCPRuntimeProvider,
        driver: VMProviderLoginDriver? = nil,
        outcome: FigmaMCPProviderStructuredStatusOutcome = .unknown,
        loginSupport: FigmaMCPProviderCapabilitySupport? = nil,
        proofSupport: FigmaMCPProviderCapabilitySupport? = nil,
        revocationSupport: FigmaMCPProviderCapabilitySupport? = nil,
        runtimeBindingSupport: FigmaMCPProviderCapabilitySupport? = nil,
        proofAuthentication: ExternalMCPAuthenticationState? = nil,
        statusCounter: VMStructuredStatusCounter? = nil,
        logoutState: VMProviderLogoutState? = nil,
        delayNanoseconds: UInt64 = 0
    ) -> ExternalMCPProviderRegistration {
        let evidence = providerEvidence(for: provider)
        let resolvedDriver = driver ?? VMProviderLoginDriver(provider: provider)
        let proofSupport = proofSupport ?? .verified(evidence)
        let runtimeBindingSupport = runtimeBindingSupport ?? .verified(evidence)
        return ExternalMCPProviderRegistration(
            provider: provider,
            adapter: logoutState.map { VMProviderLogoutAdapter(runtimeProvider: provider, state: $0) as any ExternalMCPProviderAdapter }
                ?? VMFailClosedAdapter(runtimeProvider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: loginSupport ?? .verified(evidence),
                proofSupport: proofSupport,
                revocationSupport: revocationSupport ?? {
                    if case .verified = runtimeBindingSupport {
                        return .verified(evidence)
                    }
                    return .unverified(.noRevocationContract)
                }(),
                runtimeBindingSupport: runtimeBindingSupport
            ),
            targetResolver: VMTargetResolver(runtimeProvider: provider),
            loginDriver: resolvedDriver,
            structuredStatusChecker: { target, _, context, generation in
                if let statusCounter { await statusCounter.increment() }
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                if let logoutState, await logoutState.didLogout { return .unauthenticated }
                if let proofAuthentication {
                    return .verified(.init(
                        runtimeProvider: provider,
                        canonicalTarget: target,
                        providerTargetIdentifier: "figma-\(provider.rawValue)",
                        credentialContext: .providerDefaultUserProfile,
                        sanitizedSnapshot: .init(
                            integrationID: target.integrationID,
                            connection: .connected,
                            authentication: proofAuthentication
                        ),
                        evidenceID: context.identity.provider == provider ? evidence.evidenceID : "wrong",
                        capabilityRevision: evidence.capabilityRevision,
                        operationGeneration: generation
                    ))
                }
                return outcome
            }
        )
    }

    private func providerEvidence(for provider: ExternalMCPRuntimeProvider) -> FigmaMCPProviderCapabilityEvidence {
        .init(provider: provider, evidenceID: "view-model-\(provider.rawValue)", capabilityRevision: "revision-1")
    }

    private func connectedSnapshot() -> FigmaMCPIntegrationSnapshot {
        .init(state: .connected, authentication: .authenticated, tools: [], lastSuccessfulCheck: Date(timeIntervalSince1970: 1), failureMessage: nil)
    }

    private func makeStore() throws -> GlobalSettingsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPIntegrationsSettingsViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "MCPIntegrationsSettingsViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: directory.appendingPathComponent("globalSettings.json"))
        )
    }

    private func rowStatus(
        _ provider: ExternalMCPRuntimeProvider,
        in model: MCPIntegrationsSettingsViewModel
    ) -> FigmaMCPProviderRowStatus? {
        model.providerRows.first(where: { $0.id == provider })?.status
    }

    private func rowActions(
        _ provider: ExternalMCPRuntimeProvider,
        in model: MCPIntegrationsSettingsViewModel
    ) -> [FigmaMCPProviderRowActionPresentation] {
        model.providerRows.first(where: { $0.id == provider })?.actions ?? []
    }

    private func rowMessage(
        _ provider: ExternalMCPRuntimeProvider,
        in model: MCPIntegrationsSettingsViewModel
    ) -> String? {
        model.providerRows.first(where: { $0.id == provider })?.message
    }

    private func waitUntilAsync(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let step: UInt64 = 10_000_000
        var waited: UInt64 = 0
        while await !condition(), waited < timeoutNanoseconds {
            try await Task.sleep(nanoseconds: step)
            waited += step
        }
        let conditionMet = await condition()
        XCTAssertTrue(conditionMet, "Condition did not become true before timeout")
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let step: UInt64 = 10_000_000
        var waited: UInt64 = 0
        while !condition(), waited < timeoutNanoseconds {
            try await Task.sleep(nanoseconds: step)
            waited += step
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }
}

private struct VMFailClosedAdapter: ExternalMCPFailClosedProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider
}

private actor VMProviderLogoutState {
    private(set) var callCount = 0
    private(set) var didLogout = false

    func logout() {
        callCount += 1
        didLogout = true
    }
}

private struct VMProviderLogoutAdapter: ExternalMCPFailClosedProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider
    let state: VMProviderLogoutState

    func disconnect(
        in _: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPDisconnectResult {
        await state.logout()
        return .init(
            receipt: .init(outcome: .completed),
            snapshot: .disconnected(integrationID: integration.integrationID)
        )
    }
}

private struct VMTargetResolver: FigmaMCPProviderTargetResolving {
    let runtimeProvider: ExternalMCPRuntimeProvider

    func resolveTarget(for _: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        .resolved(
            providerTargetIdentifier: "figma-\(runtimeProvider.rawValue)",
            source: .reviewedFixedIdentifier,
            credentialContext: .providerDefaultUserProfile
        )
    }
}

private actor VMStructuredStatusCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor VMLoginDriverCounts {
    var beginCount = 0
    var cancelCount = 0

    func began() {
        beginCount += 1
    }

    func cancelled() {
        cancelCount += 1
    }
}

private final class VMProviderLoginDriver: FigmaMCPProviderLoginDriving, @unchecked Sendable {
    let runtimeProvider: ExternalMCPRuntimeProvider
    let result: FigmaMCPProviderLoginSettlement
    let waitsForCompletion: Bool
    private let counts = VMLoginDriverCounts()

    init(
        provider: ExternalMCPRuntimeProvider,
        result: FigmaMCPProviderLoginSettlement = .exited(status: 0),
        waitsForCompletion: Bool = false
    ) {
        runtimeProvider = provider
        self.result = result
        self.waitsForCompletion = waitsForCompletion
    }

    func evaluateAvailability(
        provider _: ExternalMCPRuntimeProvider,
        target _: ExternalMCPIntegrationTarget
    ) async -> FigmaMCPProviderLoginAvailability {
        .available
    }

    func beginLogin(
        provider _: ExternalMCPRuntimeProvider,
        target _: ExternalMCPIntegrationTarget,
        attemptContext _: FigmaMCPProviderLoginAttemptContext
    ) async -> FigmaMCPProviderLoginSettlement {
        await counts.began()
        if waitsForCompletion {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return result
    }

    func cancelLogin(provider _: ExternalMCPRuntimeProvider, attemptID _: UUID) async {
        await counts.cancelled()
    }

    var beginCount: Int {
        get async { await counts.beginCount }
    }

    var cancelCount: Int {
        get async { await counts.cancelCount }
    }
}

@MainActor
private final class VMLegacyStatusProbe: FigmaMCPProviderStatusChecking {
    let result: FigmaMCPProviderStatusCheckResult
    private(set) var callCount = 0

    init(result: FigmaMCPProviderStatusCheckResult) {
        self.result = result
    }

    func checkStatus(
        provider _: ExternalMCPRuntimeProvider,
        integration _: ExternalMCPIntegrationDefinition,
        cancellationToken _: ExternalMCPCancellationToken
    ) async -> FigmaMCPProviderStatusCheckResult {
        callCount += 1
        return result
    }
}

@MainActor
private final class VMSettingsTerminationObserver: ApplicationTerminationObserving {
    func observeApplicationTermination(_: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NSObject()
    }

    func removeApplicationTerminationObserver(_: NSObjectProtocol) {}
}

private actor FigmaSettingsTestService: FigmaMCPIntegrationManaging {
    static let authorizationURL = URL(string: "https://www.figma.com/oauth/mcp?response_type=code&client_id=codex&state=0123456789abcdef&code_challenge=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&code_challenge_method=S256&redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback%2Fopaque&scope=mcp%3Aconnect&resource=https%3A%2F%2Fmcp.figma.com%2Fmcp")!

    private var refreshSnapshot: FigmaMCPIntegrationSnapshot
    private var queuedRefreshSnapshots: [FigmaMCPIntegrationSnapshot]
    private var connectResult: FigmaMCPConnectResult
    private var authorizationRequestURL: URL?
    private var discoveryResult: FigmaMCPImportDiscovery
    private var disconnectResult: FigmaMCPDisconnectResult
    private var disconnectEffects: FigmaMCPServiceEffects?
    private var refreshes = 0
    private var connects = 0
    private var discoveries = 0
    private var settledHandoffs: [FigmaMCPAuthorizationHandoffDisposition] = []
    private var cancellations = 0
    private let operationDelayNanoseconds: UInt64
    private let discoveryDelayNanoseconds: UInt64
    private let handoffSettlementDelayNanoseconds: UInt64

    init(
        refreshSnapshot: FigmaMCPIntegrationSnapshot = .notConfigured,
        refreshSnapshots: [FigmaMCPIntegrationSnapshot] = [],
        connectResult: FigmaMCPConnectResult = .failed,
        authorizationRequestURL: URL? = FigmaSettingsTestService.authorizationURL,
        discoveryResult: FigmaMCPImportDiscovery = .absent,
        disconnectResult: FigmaMCPDisconnectResult = .disconnected,
        disconnectEffects: FigmaMCPServiceEffects? = nil,
        operationDelayNanoseconds: UInt64 = 0,
        discoveryDelayNanoseconds: UInt64 = 0,
        handoffSettlementDelayNanoseconds: UInt64 = 0
    ) {
        self.refreshSnapshot = refreshSnapshot
        queuedRefreshSnapshots = refreshSnapshots
        self.connectResult = connectResult
        self.authorizationRequestURL = authorizationRequestURL
        self.discoveryResult = discoveryResult
        self.disconnectResult = disconnectResult
        self.disconnectEffects = disconnectEffects
        self.operationDelayNanoseconds = operationDelayNanoseconds
        self.discoveryDelayNanoseconds = discoveryDelayNanoseconds
        self.handoffSettlementDelayNanoseconds = handoffSettlementDelayNanoseconds
    }

    func refresh(definition _: ExternalMCPIntegrationDefinition?) async -> FigmaMCPIntegrationSnapshot {
        if operationDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: operationDelayNanoseconds)
        }
        refreshes += 1
        if !queuedRefreshSnapshots.isEmpty {
            return queuedRefreshSnapshots.removeFirst()
        }
        return refreshSnapshot
    }

    func cancelStatusRefresh() {}
    func snapshot() -> FigmaMCPIntegrationSnapshot {
        refreshSnapshot
    }

    func discoverExistingImport() async -> FigmaMCPImportDiscovery {
        var remainingDelay = discoveryDelayNanoseconds
        while remainingDelay > 0, cancellations == 0 {
            let interval = min(remainingDelay, 10_000_000)
            try? await Task.sleep(nanoseconds: interval)
            remainingDelay -= interval
        }
        discoveries += 1
        return cancellations > 0 ? .cancelled : discoveryResult
    }

    func connect(definition _: ExternalMCPIntegrationDefinition) async -> (FigmaMCPConnectResult, FigmaMCPAuthorizationRequest?) {
        connects += 1
        switch connectResult {
        case .authorizationRequired:
            return (.authorizationRequired, authorizationRequestURL.map { .init(id: UUID(), url: $0) })
        default:
            return (connectResult, nil)
        }
    }

    func disconnect(definition _: ExternalMCPIntegrationDefinition) async -> FigmaMCPDisconnectResult {
        disconnectResult
    }

    func disconnectWithEffects(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPDisconnectServiceResult {
        let effects = disconnectEffects ?? (
            definition.origin == .settingsManaged && disconnectResult == .disconnected
                ? .init(
                    configuration: .verifiedAbsent,
                    appServer: .init(reload: .settled, oauthListener: .notRequested),
                    credentialLogout: .init(settlement: .settled, outcome: .credentialAbsent)
                )
                : .none
        )
        return .init(result: disconnectResult, effects: effects)
    }

    func invalidatePresentationSnapshot() {}
    func settleAuthorizationHandoff(id _: UUID, disposition: FigmaMCPAuthorizationHandoffDisposition) async {
        if handoffSettlementDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: handoffSettlementDelayNanoseconds)
        }
        settledHandoffs.append(disposition)
    }

    func cancelCurrentOperation() {
        cancellations += 1
    }

    func cancellationCount() -> Int {
        cancellations
    }

    func refreshCount() -> Int {
        refreshes
    }

    func connectCount() -> Int {
        connects
    }

    func discoveryCount() -> Int {
        discoveries
    }

    func handoffDispositions() -> [FigmaMCPAuthorizationHandoffDisposition] {
        settledHandoffs
    }

    func setRefreshSnapshot(_ value: FigmaMCPIntegrationSnapshot) {
        refreshSnapshot = value
    }

    func setRefreshSnapshots(_ values: [FigmaMCPIntegrationSnapshot]) {
        queuedRefreshSnapshots = values
    }
}
