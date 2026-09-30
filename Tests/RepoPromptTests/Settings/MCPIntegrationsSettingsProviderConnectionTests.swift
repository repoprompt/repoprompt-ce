import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class MCPIntegrationsSettingsProviderConnectionTests: XCTestCase {
    func testSharedRowTimestampLabelsDistinguishObservedFromVerified() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let validUntil = observedAt.addingTimeInterval(5 * 60)

        let verified = FigmaMCPProviderRowTimestampPresentation.lastVerified.labels(for: observedAt)
        let observed = FigmaMCPProviderRowTimestampPresentation.observed(validUntil: validUntil).labels(for: observedAt)

        XCTAssertTrue(verified.display.hasPrefix("Last verified "))
        XCTAssertTrue(verified.accessibility.hasPrefix("Last verified "))
        XCTAssertTrue(observed.display.hasPrefix("Observed "))
        XCTAssertTrue(observed.display.contains("Valid until "))
        XCTAssertTrue(observed.accessibility.hasPrefix("Observed "))
        XCTAssertTrue(observed.accessibility.contains("valid until "))
        XCTAssertFalse(observed.display.contains("Last verified"))
        XCTAssertFalse(observed.accessibility.contains("Last verified"))
    }

    func testUnverifiedProviderRowsRemainActionlessAndUnsupportedProviderStaysUnsupported() async throws {
        let providerCoordinator = try makeProviderCoordinator(registrations: [
            unverifiedRegistration(provider: .openCode),
            unverifiedRegistration(provider: .cursor),
            unsupportedRegistration(provider: .grokBuild)
        ])
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: store,
            providerConnectionCoordinator: providerCoordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }

        try await waitUntil {
            self.rowStatus(.openCode, in: model) == .needsLogin
                && self.rowActions(.openCode, in: model).isEmpty
                && self.rowStatus(.cursor, in: model) == .needsLogin
                && self.rowActions(.cursor, in: model).isEmpty
                && self.rowStatus(.grokBuild, in: model) == .currentlyUnsupported
                && self.rowActions(.grokBuild, in: model).isEmpty
        }

        XCTAssertEqual(rowStatus(.openCode, in: model)?.label, "Needs login")
        XCTAssertEqual(rowStatus(.openCode, in: model)?.capsuleStatus, .notConnected)
        XCTAssertEqual(
            model.providerRows.first { $0.id == .openCode }?.message,
            "Figma MCP login is currently pending verification for this provider"
        )
        XCTAssertFalse(model.providerRows.first { $0.id == .openCode }?.isError ?? true)
        let openCodeLogin = await providerCoordinator.beginLogin(provider: .openCode)
        XCTAssertNil(openCodeLogin)
        XCTAssertFalse(providerCoordinator.recheckStatus(provider: .openCode))
        XCTAssertEqual(rowStatus(.cursor, in: model), .needsLogin)
        XCTAssertTrue(rowActions(.cursor, in: model).isEmpty)
        XCTAssertEqual(rowStatus(.grokBuild, in: model), .currentlyUnsupported)
    }

    func testSyntheticVerifiedProviderRowsProjectLoginActionsWithoutChangingProductionRegistration() async throws {
        let providerCoordinator = try makeProviderCoordinator(registrations: [
            registration(provider: .claudeCode),
            registration(provider: .openCode),
            registration(provider: .cursor)
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator
        )

        model.activateAndLoad()
        try await waitUntil {
            [ExternalMCPRuntimeProvider.claudeCode, .openCode].allSatisfy { provider in
                self.rowStatus(provider, in: model) == .needsLogin
                    && self.rowActions(provider, in: model).map(\.id) == [.connect]
                    && self.rowActions(provider, in: model).first?.title == "Connect"
            }
                && self.rowStatus(.cursor, in: model) == .needsLogin
                && self.rowActions(.cursor, in: model).isEmpty
        }
        XCTAssertEqual(
            model.providerRows.map(\.id),
            [.codex, .claudeCode, .openCode, .cursor, .grokBuild, .antigravity, .devin]
        )
        XCTAssertEqual(rowStatus(.grokBuild, in: model), .currentlyUnsupported)
        XCTAssertTrue(rowActions(.grokBuild, in: model).isEmpty)
        model.deactivate()
    }

    func testClaudeAuthorizationUsesSharedCoordinatorAndProjectsRetryAfterCancellation() async throws {
        let store = try makeStore()
        let driver = SettingsLoginDriver(provider: .claudeCode, waitsForCompletion: true)
        let providerCoordinator = try makeProviderCoordinator(registrations: [registration(provider: .claudeCode, driver: driver)])
        var navigationCount = 0
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: store,
            providerConnectionCoordinator: providerCoordinator,
            openCLIProviders: { navigationCount += 1 }
        )

        model.activateAndLoad()
        try await waitUntil { self.rowActions(.claudeCode, in: model).map(\.id) == [.connect] }
        model.startClaudeCodeFigmaAuthorization()
        try await waitUntil { await driver.beginCount == 1 }
        try await waitUntil {
            self.rowStatus(.claudeCode, in: model) == .authorizing
                && self.rowActions(.claudeCode, in: model).map(\.id) == [.cancelLogin]
                && model.integrationCardStatus == .connecting
                && model.integrationCardStatusLabelOverride == "Authorizing"
        }
        let cancelAction = try XCTUnwrap(rowActions(.claudeCode, in: model).first)
        XCTAssertTrue(cancelAction.isLoading)
        XCTAssertFalse(cancelAction.isDisabled)

        model.performProviderRowAction(provider: .claudeCode, action: .cancelLogin)
        try await waitUntil { await driver.cancelCount == 1 }
        try await waitUntil {
            if case let .notVerified(_, notice) = providerCoordinator.state(for: .claudeCode) {
                return notice == .cancelledAuthenticationStateUnknown
            }
            return false
        }
        let retryAction = try XCTUnwrap(model.providerRows.first { $0.id == .claudeCode }?.actions.first)
        XCTAssertEqual(retryAction.id, .connect)
        XCTAssertEqual(retryAction.title, "Retry Connection")
        XCTAssertEqual(retryAction.systemImage, "arrow.clockwise")
        XCTAssertEqual(navigationCount, 0)
        XCTAssertNil(store.externalMCPIntegration(for: .figma))
        model.deactivate()
    }

    func testOpenCodeAuthorizationShowsEnabledLoadingCancelAndCancelsSharedCoordinator() async throws {
        let driver = SettingsLoginDriver(provider: .openCode, waitsForCompletion: true)
        let providerCoordinator = try makeProviderCoordinator(registrations: [
            registration(provider: .openCode, driver: driver)
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.rowActions(.openCode, in: model).map(\.id) == [.connect] }

        model.performProviderRowAction(provider: .openCode, action: .connect)
        try await waitUntil {
            self.rowStatus(.openCode, in: model) == .authorizing
                && self.rowActions(.openCode, in: model).map(\.id) == [.cancelLogin]
        }
        let cancelAction = try XCTUnwrap(rowActions(.openCode, in: model).first)
        XCTAssertTrue(cancelAction.isLoading)
        XCTAssertFalse(cancelAction.isDisabled)

        model.updateCLIAvailability(.none)
        let unavailableRow = try XCTUnwrap(model.providerRows.first { $0.id == .openCode })
        XCTAssertFalse(unavailableRow.isCLIAvailable)
        XCTAssertFalse(unavailableRow.canExpand)
        XCTAssertEqual(unavailableRow.actions.map(\.id), [.cancelLogin])
        XCTAssertFalse(unavailableRow.actions[0].isDisabled)
        let cancellationsAfterReadinessLoss = await driver.cancelCount
        XCTAssertEqual(cancellationsAfterReadinessLoss, 0, "Readiness loss must not cancel an admitted login")
        model.performProviderRowAction(provider: .openCode, action: .connect)
        let cancellationsAfterRejectedConnect = await driver.cancelCount
        XCTAssertEqual(cancellationsAfterRejectedConnect, 0)

        model.performProviderRowAction(provider: .openCode, action: .cancelLogin)
        try await waitUntil { await driver.cancelCount == 1 }
        try await waitUntil {
            if case let .notVerified(_, notice) = providerCoordinator.state(for: .openCode) {
                return notice == .cancelledAuthenticationStateUnknown
            }
            return false
        }
    }

    func testClaudeAndOpenCodeShowConnectingOnlyDuringPostAuthorizationVerification() async throws {
        for provider in [ExternalMCPRuntimeProvider.claudeCode, .openCode] {
            let driver = SettingsLoginDriver(provider: provider, waitsForRelease: true)
            let statusGate = SettingsStructuredStatusGate()
            let providerCoordinator = try makeProviderCoordinator(registrations: [
                registration(provider: provider, driver: driver, statusGate: statusGate)
            ])
            let model = try MCPIntegrationsSettingsViewModel(
                externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
                settingsStore: makeStore(),
                providerConnectionCoordinator: providerCoordinator
            )

            model.activateAndLoad()
            try await waitUntil {
                await statusGate.callCount == 1
                    && self.rowActions(provider, in: model).map(\.id) == [.connect]
            }
            model.performProviderRowAction(provider: provider, action: .connect)
            try await waitUntil { self.rowStatus(provider, in: model) == .authorizing }
            guard case let .authorizing(authorizingAttempt) = providerCoordinator.state(for: provider) else {
                return XCTFail("Expected an authorizing attempt for \(provider)")
            }

            await driver.releaseLogin()
            try await waitUntil {
                await statusGate.verificationEntered
                    && self.rowStatus(provider, in: model) == .connecting
            }
            guard case let .verifyingAfterAuthorization(verifyingAttempt) = providerCoordinator.state(for: provider) else {
                return XCTFail("Expected post-authorization verification for \(provider)")
            }
            XCTAssertEqual(verifyingAttempt.attemptID, authorizingAttempt.attemptID)
            let connectingRow = try XCTUnwrap(model.providerRows.first { $0.id == provider })
            XCTAssertEqual(connectingRow.status.label, "Connecting…")
            XCTAssertEqual(connectingRow.status.capsuleStatus, .connecting)
            XCTAssertNil(connectingRow.verifiedAt)
            XCTAssertNil(connectingRow.connectionSummary)
            XCTAssertEqual(connectingRow.actions.map(\.id), [.cancelLogin])
            XCTAssertTrue(connectingRow.actions.first?.isLoading == true)
            XCTAssertFalse(connectingRow.actions.first?.isDisabled ?? true)
            XCTAssertEqual(model.integrationCardStatus, .connecting)
            XCTAssertEqual(model.integrationCardStatusLabelOverride, "Connecting…")

            await statusGate.release()
            try await waitUntil { self.rowStatus(provider, in: model) == .connected }
            model.deactivate()
        }
    }

    func testCancellingPostAuthorizationVerificationTargetsOriginalAttempt() async throws {
        let provider: ExternalMCPRuntimeProvider = .openCode
        let driver = SettingsLoginDriver(provider: provider, waitsForRelease: true)
        let statusGate = SettingsStructuredStatusGate()
        let providerCoordinator = try makeProviderCoordinator(registrations: [
            registration(provider: provider, driver: driver, statusGate: statusGate)
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil {
            await statusGate.callCount == 1
                && self.rowActions(provider, in: model).map(\.id) == [.connect]
        }
        model.performProviderRowAction(provider: provider, action: .connect)
        try await waitUntil { self.rowStatus(provider, in: model) == .authorizing }
        guard case let .authorizing(authorizingAttempt) = providerCoordinator.state(for: provider) else {
            return XCTFail("Expected an authorizing attempt")
        }

        await driver.releaseLogin()
        try await waitUntil {
            await statusGate.verificationEntered
                && self.rowStatus(provider, in: model) == .connecting
        }
        guard case let .verifyingAfterAuthorization(verifyingAttempt) = providerCoordinator.state(for: provider) else {
            return XCTFail("Expected post-authorization verification")
        }
        XCTAssertEqual(verifyingAttempt.attemptID, authorizingAttempt.attemptID)

        model.performProviderRowAction(provider: provider, action: .cancelLogin)
        try await waitUntil { await driver.cancelCount == 1 }
        let cancelledAttemptID = await driver.lastCancelledAttemptID
        XCTAssertEqual(cancelledAttemptID, authorizingAttempt.attemptID)
        try await waitUntil {
            if case let .notVerified(_, notice) = providerCoordinator.state(for: provider) {
                return notice == .cancelledAuthenticationStateUnknown
            }
            return false
        }
    }

    func testClaudeAuthorizationTerminalCloseImmediatelyReturnsNeedsLogin() async throws {
        let driver = SettingsLoginDriver(provider: .claudeCode, result: .authorizationSessionClosed)
        let providerCoordinator = try makeProviderCoordinator(registrations: [
            registration(provider: .claudeCode, driver: driver)
        ])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.rowActions(.claudeCode, in: model).map(\.id) == [.connect] }

        model.performProviderRowAction(provider: .claudeCode, action: .connect)

        try await waitUntil {
            self.rowStatus(.claudeCode, in: model) == .needsLogin
                && self.rowActions(.claudeCode, in: model).map(\.id) == [.connect]
                && model.providerRows.first(where: { $0.id == .claudeCode })?.message
                == "The Claude Code CLI Figma authorization terminal was closed."
        }
        XCTAssertEqual(model.integrationCardStatus, .notConnected)
    }

    func testAggregateUsesOnlyCurrentStructuredProofAndOtherProviderActivityIsIsolated() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.setExternalMCPIntegration(.figma()))
        let providerCoordinator = try makeProviderCoordinator(registrations: [
            registration(provider: .openCode, proofAuthentication: .providerOwned),
            registration(provider: .cursor),
            registration(provider: .claudeCode)
        ])
        let model = MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: store,
            providerConnectionCoordinator: providerCoordinator
        )

        model.activateAndLoad()
        try await waitUntil { self.rowStatus(.openCode, in: model) == .connected }
        XCTAssertEqual(rowActions(.openCode, in: model).map(\.id), [.testConnection])
        XCTAssertEqual(model.providerRows.first { $0.id == .openCode }?.connectionSummary?.rows, [
            .connection("Figma MCP"),
            .authentication("Figma sign-in verified through OpenCode CLI"),
            .credentialOwner("Managed by OpenCode CLI")
        ])
        XCTAssertEqual(model.integrationCardStatus, .connected)
        XCTAssertEqual(rowStatus(.cursor, in: model), .needsLogin)
        XCTAssertEqual(rowStatus(.claudeCode, in: model), .needsLogin)
        XCTAssertEqual(model.integrationCardStatus, .connected)
        model.deactivate()
    }

    func testCursorFigmaMCPConnectRunsSafeLoginAndRequiresFreshObservationBeforeConnected() async throws {
        let providerCoordinator = try makeProviderCoordinator(registrations: [registration(provider: .cursor)])
        let firstObservedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let firstExpiresAt = firstObservedAt.addingTimeInterval(60)
        let secondObservedAt = Date(timeIntervalSince1970: 1_800_000_030)
        let secondExpiresAt = secondObservedAt.addingTimeInterval(60)
        let observer = SettingsCursorToolSurfaceSequenceObserver(outcomes: [
            .candidate(.init(
                observedAt: firstObservedAt,
                expiresAt: firstExpiresAt,
                executableBuild: CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild,
                targetIdentifier: CursorFigmaMCPToolSurfaceDescriptor.targetIdentifier
            )),
            .candidate(.init(
                observedAt: secondObservedAt,
                expiresAt: secondExpiresAt,
                executableBuild: CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild,
                targetIdentifier: CursorFigmaMCPToolSurfaceDescriptor.targetIdentifier
            ))
        ], delayNanoseconds: 100_000_000)
        let recorder = SettingsCursorLoginInvocationRecorder()
        let disableExecutor = SettingsCursorDisableExecutor(outcome: .disabled)
        let (components, driver) = try makeCursorLoginDriver(recorder: recorder)
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator,
            cursorFigmaToolSurfaceObserver: observer,
            cursorFigmaLoginComponents: components,
            cursorFigmaLoginDriver: driver,
            cursorFigmaDisableExecutor: disableExecutor
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil {
            self.rowStatus(.cursor, in: model) == .needsLogin
                && self.rowActions(.cursor, in: model).map(\.id) == [.connect]
        }

        model.performProviderRowAction(provider: .cursor, action: .connect)
        try await waitUntil { await recorder.invocation?.arguments == ["mcp", "login", "reviewed-figma"] }
        try await waitUntil { self.rowStatus(.cursor, in: model) == .connecting }
        let connectingRow = try XCTUnwrap(model.providerRows.first { $0.id == .cursor })
        XCTAssertEqual(connectingRow.status.label, "Connecting…")
        XCTAssertEqual(connectingRow.status.capsuleStatus, .connecting)
        XCTAssertTrue(connectingRow.actions.isEmpty)
        XCTAssertEqual(model.integrationCardStatus, .connecting)
        XCTAssertEqual(model.integrationCardStatusLabelOverride, "Connecting…")
        try await waitUntil { self.rowStatus(.cursor, in: model) == .connected }
        let observationCount = await observer.observationCount
        let observedLaunch = await observer.launches.first
        let loginInvocation = await recorder.invocation
        XCTAssertEqual(observationCount, 1)
        let initialRequiresEnableRequests = await observer.requiresEnableRequests
        let initialCachePolicyRequests = await observer.cachePolicyRequests
        XCTAssertEqual(initialRequiresEnableRequests, [true])
        XCTAssertEqual(initialCachePolicyRequests, [.requireFreshObservation])
        XCTAssertEqual(observedLaunch?.executableIdentity.canonicalPath, loginInvocation?.configuration.command)
        XCTAssertEqual(observedLaunch?.environment, loginInvocation?.configuration.environment)
        XCTAssertEqual(rowActions(.cursor, in: model).map(\.id), [.testConnection, .disconnect])
        XCTAssertEqual(rowActions(.cursor, in: model).map(\.title), ["Test Connection", "Disconnect"])
        XCTAssertEqual(model.providerRows.first { $0.id == .cursor }?.connectionSummary?.rows, [
            .connection("Figma MCP"),
            .authentication("Figma sign-in not independently verified by RepoPrompt CE"),
            .credentialOwner("Managed by Cursor CLI")
        ])
        XCTAssertEqual(model.providerRows.first { $0.id == .cursor }?.message, "Figma is connected.")
        XCTAssertEqual(
            model.providerRows.first { $0.id == .cursor }?.timestampPresentation,
            .observed(validUntil: firstExpiresAt)
        )
        let connectedRow = try XCTUnwrap(model.providerRows.first { $0.id == .cursor })

        model.performProviderRowAction(provider: .cursor, action: .testConnection)
        try await waitUntil { self.rowStatus(.cursor, in: model) == .checking }
        let testingRow = try XCTUnwrap(model.providerRows.first { $0.id == .cursor })
        XCTAssertTrue(testingRow.isTestingConnection)
        XCTAssertEqual(testingRow.verifiedAt, firstObservedAt)
        XCTAssertEqual(testingRow.verifiedAt, connectedRow.verifiedAt)
        XCTAssertEqual(testingRow.timestampPresentation, .observed(validUntil: firstExpiresAt))
        XCTAssertEqual(testingRow.connectionSummary?.rows, [
            .connection("Figma MCP"),
            .authentication("Checking Cursor's documented Figma MCP tool surface"),
            .credentialOwner("Managed by Cursor CLI")
        ])
        XCTAssertEqual(testingRow.actions.map(\.id), [.testConnection, .disconnect])
        XCTAssertTrue(testingRow.actions.allSatisfy(\.isDisabled))
        XCTAssertEqual(testingRow.actions.first?.isLoading, true)
        try await waitUntil { await observer.observationCount == 2 && self.rowStatus(.cursor, in: model) == .connected }
        let requiresEnableRequests = await observer.requiresEnableRequests
        let cachePolicyRequests = await observer.cachePolicyRequests
        let launches = await observer.launches
        XCTAssertEqual(requiresEnableRequests, [true, false])
        XCTAssertEqual(cachePolicyRequests, [.requireFreshObservation, .requireFreshObservation])
        XCTAssertEqual(launches.first?.executableIdentity, launches.last?.executableIdentity)
        XCTAssertEqual(launches.first?.environment, launches.last?.environment)
        let refreshedRow = try XCTUnwrap(model.providerRows.first { $0.id == .cursor })
        XCTAssertEqual(refreshedRow.verifiedAt, secondObservedAt)
        XCTAssertEqual(refreshedRow.timestampPresentation, .observed(validUntil: secondExpiresAt))
        XCTAssertFalse(refreshedRow.isTestingConnection)
        XCTAssertEqual(refreshedRow.actions.map(\.id), [.testConnection, .disconnect])
        XCTAssertTrue(refreshedRow.actions.allSatisfy { !$0.isDisabled && !$0.isLoading })

        model.performProviderRowAction(provider: .cursor, action: .disconnect)
        try await waitUntil {
            self.rowStatus(.cursor, in: model) == .needsLogin
                && self.rowActions(.cursor, in: model).map(\.id) == [.connect]
        }
        XCTAssertNil(model.cursorFigmaToolSurfaceObservation)
        let disableCount = await disableExecutor.disableCount
        let disabledLaunch = await disableExecutor.launches.first
        XCTAssertEqual(disableCount, 1)
        XCTAssertEqual(disabledLaunch?.executableIdentity, observedLaunch?.executableIdentity)
        XCTAssertFalse(model.recheckProviderStatus(provider: .cursor))
        XCTAssertNil(providerCoordinator.state(for: .cursor))
    }

    func testCursorFigmaMCPConnectShowsAuthorizingAndCanBeCancelled() async throws {
        let providerCoordinator = try makeProviderCoordinator(registrations: [registration(provider: .cursor)])
        let observer = SettingsCursorToolSurfaceSequenceObserver(outcomes: [.unavailable(.executableUnavailable)])
        let recorder = SettingsCursorLoginInvocationRecorder(waitForCancellation: true)
        let (components, driver) = try makeCursorLoginDriver(recorder: recorder)
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator,
            cursorFigmaToolSurfaceObserver: observer,
            cursorFigmaLoginComponents: components,
            cursorFigmaLoginDriver: driver
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.rowActions(.cursor, in: model).map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .cursor, action: .connect)
        try await waitUntil {
            self.rowStatus(.cursor, in: model) == .authorizing
                && self.rowActions(.cursor, in: model).map(\.id) == [.cancelLogin]
        }
        try await waitUntil { await recorder.invocation != nil }

        model.performProviderRowAction(provider: .cursor, action: .cancelLogin)
        try await waitUntil {
            self.rowStatus(.cursor, in: model) == .needsLogin
                && self.rowActions(.cursor, in: model).map(\.id) == [.connect]
                && !model.isAuthorizingCursorFigma
        }
        try await waitUntil { await recorder.wasCancelled }
        let wasCancelled = await recorder.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testCursorFigmaMCPLoginExitOrFailureWithoutObservationRemainsNeedsLogin() async throws {
        for status in [Int32(0), 1] {
            let providerCoordinator = try makeProviderCoordinator(registrations: [registration(provider: .cursor)])
            let observer = SettingsCursorToolSurfaceSequenceObserver(outcomes: [.unavailable(.processFailed)])
            let recorder = SettingsCursorLoginInvocationRecorder(result: .init(status: status, timedOut: false))
            let (components, driver) = try makeCursorLoginDriver(recorder: recorder)
            let model = try MCPIntegrationsSettingsViewModel(
                externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
                settingsStore: makeStore(),
                providerConnectionCoordinator: providerCoordinator,
                cursorFigmaToolSurfaceObserver: observer,
                cursorFigmaLoginComponents: components,
                cursorFigmaLoginDriver: driver
            )
            model.activateAndLoad()
            defer { model.deactivate() }

            try await waitUntil { self.rowActions(.cursor, in: model).map(\.id) == [.connect] }
            model.performProviderRowAction(provider: .cursor, action: .connect)
            try await waitUntil {
                await recorder.completedRunCount == 1
                    && !model.isAuthorizingCursorFigma
                    && self.rowStatus(.cursor, in: model) == .needsLogin
            }
            let observationCount = await observer.observationCount
            XCTAssertEqual(observationCount, status == 0 ? 1 : 0)
            XCTAssertEqual(rowStatus(.cursor, in: model), .needsLogin)
        }
    }

    func testCursorFigmaMCPCancelRetiresAttemptBeforeLateProcessResult() async throws {
        let providerCoordinator = try makeProviderCoordinator(registrations: [registration(provider: .cursor)])
        let observer = SettingsCursorToolSurfaceSequenceObserver(outcomes: [.candidate(.init(
            observedAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            executableBuild: CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild,
            targetIdentifier: CursorFigmaMCPToolSurfaceDescriptor.targetIdentifier
        ))])
        let recorder = SettingsCursorLoginInvocationRecorder(waitForRelease: true)
        let (components, driver) = try makeCursorLoginDriver(recorder: recorder)
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator,
            cursorFigmaToolSurfaceObserver: observer,
            cursorFigmaLoginComponents: components,
            cursorFigmaLoginDriver: driver
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.rowActions(.cursor, in: model).map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .cursor, action: .connect)
        try await waitUntil { await recorder.invocation != nil }

        model.performProviderRowAction(provider: .cursor, action: .cancelLogin)
        XCTAssertEqual(rowStatus(.cursor, in: model), .needsLogin)
        XCTAssertFalse(model.isAuthorizingCursorFigma)
        await recorder.release()
        try await waitUntil { await recorder.completedRunCount == 1 }

        XCTAssertEqual(rowStatus(.cursor, in: model), .needsLogin)
        let observationCount = await observer.observationCount
        XCTAssertEqual(observationCount, 0)
    }

    func testCursorFigmaMCPLoginTimeoutRetiresStuckAuthorizingAttempt() async throws {
        let providerCoordinator = try makeProviderCoordinator(registrations: [registration(provider: .cursor)])
        let recorder = SettingsCursorLoginInvocationRecorder(waitForRelease: true)
        let (components, driver) = try makeCursorLoginDriver(recorder: recorder, loginTimeout: 0.05)
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator,
            cursorFigmaLoginComponents: components,
            cursorFigmaLoginDriver: driver
        )

        model.activateAndLoad()
        defer { model.deactivate() }
        try await waitUntil { self.rowActions(.cursor, in: model).map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .cursor, action: .connect)
        try await waitUntil {
            await recorder.invocation != nil
                && self.rowStatus(.cursor, in: model) == .needsLogin
                && !model.isAuthorizingCursorFigma
        }
        await recorder.release()
        try await waitUntil { await recorder.completedRunCount == 1 }
        XCTAssertEqual(rowStatus(.cursor, in: model), .needsLogin)
    }

    func testCursorFigmaMCPLoginLeaseIsSharedAcrossSettingsWindows() async throws {
        let providerCoordinator = try makeProviderCoordinator(registrations: [registration(provider: .cursor)])
        let firstRecorder = SettingsCursorLoginInvocationRecorder(waitForCancellation: true)
        let secondRecorder = SettingsCursorLoginInvocationRecorder()
        let (firstComponents, firstDriver) = try makeCursorLoginDriver(recorder: firstRecorder)
        let (secondComponents, secondDriver) = try makeCursorLoginDriver(recorder: secondRecorder)
        let firstModel = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator,
            cursorFigmaLoginComponents: firstComponents,
            cursorFigmaLoginDriver: firstDriver
        )
        let secondModel = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator,
            cursorFigmaLoginComponents: secondComponents,
            cursorFigmaLoginDriver: secondDriver
        )
        firstModel.activateAndLoad()
        secondModel.activateAndLoad()
        defer {
            firstModel.deactivate()
            secondModel.deactivate()
        }
        try await waitUntil {
            self.rowActions(.cursor, in: firstModel).map(\.id) == [.connect]
                && self.rowActions(.cursor, in: secondModel).map(\.id) == [.connect]
        }

        firstModel.performProviderRowAction(provider: .cursor, action: .connect)
        try await waitUntil { await firstRecorder.invocation != nil }
        secondModel.performProviderRowAction(provider: .cursor, action: .connect)

        try await waitUntil {
            self.rowStatus(.cursor, in: secondModel) == .needsLogin
                && self.rowActions(.cursor, in: secondModel).map(\.id) == [.connect]
        }
        let secondInvocation = await secondRecorder.invocation
        XCTAssertNil(secondInvocation)
        XCTAssertEqual(
            secondModel.providerRows.first(where: { $0.id == .cursor })?.message,
            CursorFigmaMCPToolSurfaceProbeDiagnostic.loginBusy.message
        )
    }

    func testCursorFigmaMCPDeactivationExplicitlyCancelsActiveDriverAttempt() async throws {
        let providerCoordinator = try makeProviderCoordinator(registrations: [registration(provider: .cursor)])
        let recorder = SettingsCursorLoginInvocationRecorder(waitForCancellation: true)
        let (components, driver) = try makeCursorLoginDriver(recorder: recorder)
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator,
            cursorFigmaToolSurfaceObserver: SettingsCursorToolSurfaceObserver(outcome: .unavailable(.processFailed)),
            cursorFigmaLoginComponents: components,
            cursorFigmaLoginDriver: driver
        )

        model.activateAndLoad()
        try await waitUntil { self.rowActions(.cursor, in: model).map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .cursor, action: .connect)
        try await waitUntil { await recorder.invocation != nil }

        model.deactivate()

        try await waitUntil { await recorder.wasCancelled }
        XCTAssertNil(providerCoordinator.state(for: .cursor))
    }

    func testTypedNegativeOutcomesUseNeedsLoginPresentation() async throws {
        for outcome in [FigmaMCPProviderStructuredStatusOutcome.unauthenticated, .expired] {
            let coordinator = try makeProviderCoordinator(registrations: [registration(provider: .openCode, outcome: outcome)])
            let model = try MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex, settingsStore: makeStore(), providerConnectionCoordinator: coordinator)
            model.activateAndLoad()
            try await waitUntil { self.rowStatus(.openCode, in: model) == .needsLogin }
            model.deactivate()
        }
        for outcome in [FigmaMCPProviderStructuredStatusOutcome.unknown, .stale] {
            let coordinator = try makeProviderCoordinator(registrations: [registration(provider: .openCode, outcome: outcome)])
            let model = try MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex, settingsStore: makeStore(), providerConnectionCoordinator: coordinator)
            model.activateAndLoad()
            try await waitUntil { self.rowStatus(.openCode, in: model) == .needsLogin }
            model.deactivate()
        }
    }

    func testDeactivatingSettingsObserverDoesNotCancelAppLifetimeLogin() async throws {
        let driver = SettingsLoginDriver(provider: .claudeCode, waitsForCompletion: true)
        let providerCoordinator = try makeProviderCoordinator(registrations: [registration(provider: .claudeCode, driver: driver)])
        let model = try MCPIntegrationsSettingsViewModel(
            externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.withoutCodex,
            settingsStore: makeStore(),
            providerConnectionCoordinator: providerCoordinator
        )
        model.activateAndLoad()
        try await waitUntil { self.rowActions(.claudeCode, in: model).map(\.id) == [.connect] }
        model.performProviderRowAction(provider: .claudeCode, action: .connect)
        try await waitUntil { await driver.beginCount == 1 }
        try await waitUntil { self.rowStatus(.claudeCode, in: model) == .authorizing }
        model.deactivate()
        XCTAssertFalse(providerCoordinator.observingSettings)
        let cancelCount = await driver.cancelCount
        XCTAssertEqual(cancelCount, 0)
        guard case let .authorizing(attempt) = providerCoordinator.state(for: .claudeCode) else {
            return XCTFail("The app-lifetime provider login should remain active after Settings deactivation")
        }
        await providerCoordinator.cancelLogin(provider: .claudeCode, attemptID: attempt.attemptID)
        let finalCancelCount = await driver.cancelCount
        XCTAssertEqual(finalCancelCount, 1)
    }

    private func registration(
        provider: ExternalMCPRuntimeProvider,
        driver: SettingsLoginDriver? = nil,
        outcome: FigmaMCPProviderStructuredStatusOutcome = .unknown,
        proofAuthentication: ExternalMCPAuthenticationState? = nil,
        statusGate: SettingsStructuredStatusGate? = nil
    ) -> ExternalMCPProviderRegistration {
        let evidence = evidence(for: provider)
        let resolvedDriver = driver ?? SettingsLoginDriver(provider: provider)
        return ExternalMCPProviderRegistration(
            provider: provider,
            adapter: SettingsFailClosedAdapter(runtimeProvider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: SettingsTargetResolver(runtimeProvider: provider),
            loginDriver: resolvedDriver,
            structuredStatusChecker: { target, _, context, generation in
                if let statusGate {
                    return await statusGate.check(
                        provider: provider,
                        target: target,
                        context: context,
                        generation: generation,
                        evidence: evidence
                    )
                }
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

    private func unverifiedRegistration(
        provider: ExternalMCPRuntimeProvider
    ) -> ExternalMCPProviderRegistration {
        .init(
            provider: provider,
            adapter: SettingsFailClosedAdapter(runtimeProvider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .unverified(.noStructuredProofContract),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            )
        )
    }

    private func unsupportedRegistration(
        provider: ExternalMCPRuntimeProvider
    ) -> ExternalMCPProviderRegistration {
        .init(
            provider: provider,
            adapter: SettingsFailClosedAdapter(runtimeProvider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .unsupported(.unsupportedProviderRoute),
                proofSupport: .unsupported(.unsupportedProviderRoute),
                revocationSupport: .unsupported(.unsupportedProviderRoute),
                runtimeBindingSupport: .unsupported(.unsupportedProviderRoute)
            )
        )
    }

    private func evidence(for provider: ExternalMCPRuntimeProvider) -> FigmaMCPProviderCapabilityEvidence {
        .init(provider: provider, evidenceID: "settings-test-\(provider.rawValue)", capabilityRevision: "revision-1")
    }

    private func makeProviderCoordinator(registrations: [ExternalMCPProviderRegistration]) throws -> FigmaMCPProviderConnectionCoordinator {
        let registry = try ExternalMCPAdapterRegistry(registrations: registrations)
        return FigmaMCPProviderConnectionCoordinator(registry: registry, sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }), terminationObserver: SettingsTerminationObserver())
    }

    private func makeCursorLoginDriver(
        recorder: SettingsCursorLoginInvocationRecorder,
        loginTimeout: TimeInterval = 5 * 60
    ) throws -> (CursorFigmaMCPLoginComponents, FigmaMCPProviderSubprocessLoginDriver) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPIntegrationsSettingsCursorLogin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("cursor-agent")
        guard FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8)
        ) else {
            throw NSError(domain: "MCPIntegrationsSettingsProviderConnectionTests", code: 1)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let components = CursorFigmaMCPLoginFactory.makeComponents(
            sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }),
            targetDataLoader: { _ in
                Data(#"{"mcpServers":{"reviewed-figma":{"url":"https://mcp.figma.com/mcp"}}}"#.utf8)
            },
            timeout: loginTimeout
        )
        let driver = FigmaMCPProviderSubprocessLoginDriver(
            descriptor: components.subprocessDescriptor,
            inheritedEnvironment: ["PATH": directory.path, "TERM": "xterm-256color"],
            environmentBuilder: { request in
                .init(
                    environment: request.inheritedEnvironment,
                    launchContext: .detect(from: request.inheritedEnvironment),
                    shellEnvironmentSource: .inheritedRichEnvironment
                )
            },
            executableVersionResolver: {
                CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild
            },
            processRunner: { invocation in
                await recorder.run(invocation)
            }
        )
        return (components, driver)
    }

    private func makeStore() throws -> GlobalSettingsStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MCPIntegrationsSettingsProviderConnectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "MCPIntegrationsSettingsProviderConnectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: directory.appendingPathComponent("globalSettings.json")))
    }

    private func rowStatus(_ provider: ExternalMCPRuntimeProvider, in model: MCPIntegrationsSettingsViewModel) -> FigmaMCPProviderRowStatus? {
        model.providerRows.first(where: { $0.id == provider })?.status
    }

    private func rowActions(_ provider: ExternalMCPRuntimeProvider, in model: MCPIntegrationsSettingsViewModel) -> [FigmaMCPProviderRowActionPresentation] {
        model.providerRows.first(where: { $0.id == provider })?.actions ?? []
    }

    private func waitUntil(timeoutNanoseconds: UInt64 = 2_000_000_000, condition: @escaping @MainActor () async -> Bool) async throws {
        let step: UInt64 = 10_000_000
        var waited: UInt64 = 0
        while await !condition(), waited < timeoutNanoseconds {
            try await Task.sleep(nanoseconds: step)
            waited += step
        }
        let finalCondition = await condition()
        XCTAssertTrue(finalCondition, "Condition did not become true before timeout")
    }
}

private struct SettingsCursorToolSurfaceObserver: CursorFigmaMCPToolSurfaceObserving {
    let outcome: CursorFigmaMCPToolSurfaceProbeOutcome

    func observe(
        launch _: FigmaMCPProviderResolvedLoginLaunch,
        requiresEnable _: Bool,
        cachePolicy _: CursorFigmaMCPToolSurfaceCachePolicy
    ) async -> CursorFigmaMCPToolSurfaceProbeOutcome {
        outcome
    }
}

private actor SettingsCursorToolSurfaceSequenceObserver: CursorFigmaMCPToolSurfaceObserving {
    private var outcomes: [CursorFigmaMCPToolSurfaceProbeOutcome]
    private let delayNanoseconds: UInt64
    private(set) var observationCount = 0
    private(set) var launches: [FigmaMCPProviderResolvedLoginLaunch] = []
    private(set) var requiresEnableRequests: [Bool] = []
    private(set) var cachePolicyRequests: [CursorFigmaMCPToolSurfaceCachePolicy] = []

    init(
        outcomes: [CursorFigmaMCPToolSurfaceProbeOutcome],
        delayNanoseconds: UInt64 = 0
    ) {
        self.outcomes = outcomes
        self.delayNanoseconds = delayNanoseconds
    }

    func observe(
        launch: FigmaMCPProviderResolvedLoginLaunch,
        requiresEnable: Bool,
        cachePolicy: CursorFigmaMCPToolSurfaceCachePolicy
    ) async -> CursorFigmaMCPToolSurfaceProbeOutcome {
        observationCount += 1
        launches.append(launch)
        requiresEnableRequests.append(requiresEnable)
        cachePolicyRequests.append(cachePolicy)
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard !outcomes.isEmpty else { return .unavailable(.processFailed) }
        return outcomes.removeFirst()
    }
}

private actor SettingsCursorDisableExecutor: CursorFigmaMCPDisableExecuting {
    let outcome: CursorFigmaMCPDisableOutcome
    private(set) var disableCount = 0

    init(outcome: CursorFigmaMCPDisableOutcome) {
        self.outcome = outcome
    }

    private(set) var launches: [FigmaMCPProviderResolvedLoginLaunch] = []

    func disable(
        retainedLaunch launch: FigmaMCPProviderResolvedLoginLaunch
    ) async -> CursorFigmaMCPDisableOutcome {
        disableCount += 1
        launches.append(launch)
        return outcome
    }
}

private actor SettingsCursorLoginInvocationRecorder {
    private(set) var invocation: FigmaMCPProviderLoginProcessInvocation?
    private(set) var wasCancelled = false
    private(set) var completedRunCount = 0
    private let result: FigmaMCPProviderLoginProcessResult
    private let waitForCancellation: Bool
    private let waitForRelease: Bool
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(
        result: FigmaMCPProviderLoginProcessResult = .init(status: 0, timedOut: false),
        waitForCancellation: Bool = false,
        waitForRelease: Bool = false
    ) {
        self.result = result
        self.waitForCancellation = waitForCancellation
        self.waitForRelease = waitForRelease
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func run(
        _ invocation: FigmaMCPProviderLoginProcessInvocation
    ) async -> FigmaMCPProviderLoginProcessResult {
        self.invocation = invocation
        if waitForRelease {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        } else if waitForCancellation {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                wasCancelled = true
            }
        }
        completedRunCount += 1
        return result
    }
}

private struct SettingsFailClosedAdapter: ExternalMCPFailClosedProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider
}

private struct SettingsTargetResolver: FigmaMCPProviderTargetResolving {
    let runtimeProvider: ExternalMCPRuntimeProvider

    func resolveTarget(for _: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        .resolved(providerTargetIdentifier: "figma-\(runtimeProvider.rawValue)", source: .reviewedFixedIdentifier, credentialContext: .providerDefaultUserProfile)
    }
}

private actor SettingsLoginDriverCounts {
    var beginCount = 0
    var cancelCount = 0
    var lastCancelledAttemptID: UUID?
    private var loginReleaseRequested = false
    private var loginReleaseContinuation: CheckedContinuation<Void, Never>?

    func began() {
        beginCount += 1
    }

    func waitForLoginRelease() async {
        guard !loginReleaseRequested else { return }
        await withCheckedContinuation { continuation in
            loginReleaseContinuation = continuation
        }
    }

    func releaseLogin() {
        loginReleaseRequested = true
        loginReleaseContinuation?.resume()
        loginReleaseContinuation = nil
    }

    func cancelled(attemptID: UUID) {
        cancelCount += 1
        lastCancelledAttemptID = attemptID
    }
}

private final class SettingsLoginDriver: FigmaMCPProviderLoginDriving, @unchecked Sendable {
    let runtimeProvider: ExternalMCPRuntimeProvider
    let result: FigmaMCPProviderLoginSettlement
    let waitsForCompletion: Bool
    let waitsForRelease: Bool
    private let counts = SettingsLoginDriverCounts()

    init(
        provider: ExternalMCPRuntimeProvider,
        result: FigmaMCPProviderLoginSettlement = .exited(status: 0),
        waitsForCompletion: Bool = false,
        waitsForRelease: Bool = false
    ) {
        runtimeProvider = provider
        self.result = result
        self.waitsForCompletion = waitsForCompletion
        self.waitsForRelease = waitsForRelease
    }

    func evaluateAvailability(provider _: ExternalMCPRuntimeProvider, target _: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderLoginAvailability {
        .available
    }

    func beginLogin(provider _: ExternalMCPRuntimeProvider, target _: ExternalMCPIntegrationTarget, attemptContext _: FigmaMCPProviderLoginAttemptContext) async -> FigmaMCPProviderLoginSettlement {
        await counts.began()
        if waitsForRelease {
            await counts.waitForLoginRelease()
        } else if waitsForCompletion {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return .cancelled
            }
        }
        return Task.isCancelled ? .cancelled : result
    }

    func cancelLogin(provider _: ExternalMCPRuntimeProvider, attemptID: UUID) async {
        await counts.cancelled(attemptID: attemptID)
    }

    func releaseLogin() async {
        await counts.releaseLogin()
    }

    var beginCount: Int {
        get async { await counts.beginCount }
    }

    var cancelCount: Int {
        get async { await counts.cancelCount }
    }

    var lastCancelledAttemptID: UUID? {
        get async { await counts.lastCancelledAttemptID }
    }
}

private actor SettingsStructuredStatusGate {
    private(set) var callCount = 0
    private var isReleased = false
    private(set) var verificationEntered = false

    func release() {
        isReleased = true
    }

    func check(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        context: ExternalMCPProviderRuntimeContext,
        generation: UInt64,
        evidence: FigmaMCPProviderCapabilityEvidence
    ) async -> FigmaMCPProviderStructuredStatusOutcome {
        callCount += 1
        guard callCount > 1 else { return .unauthenticated }
        verificationEntered = true
        while !isReleased {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return .stale
            }
        }
        return .verified(.init(
            runtimeProvider: provider,
            canonicalTarget: target,
            providerTargetIdentifier: "figma-\(provider.rawValue)",
            credentialContext: .providerDefaultUserProfile,
            sanitizedSnapshot: .init(
                integrationID: target.integrationID,
                connection: .connected,
                authentication: .providerOwned
            ),
            evidenceID: context.identity.provider == provider ? evidence.evidenceID : "wrong",
            capabilityRevision: evidence.capabilityRevision,
            operationGeneration: generation
        ))
    }
}

@MainActor
private final class SettingsTerminationObserver: ApplicationTerminationObserving {
    func observeApplicationTermination(_: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NSObject()
    }

    func removeApplicationTerminationObserver(_: NSObjectProtocol) {}
}
