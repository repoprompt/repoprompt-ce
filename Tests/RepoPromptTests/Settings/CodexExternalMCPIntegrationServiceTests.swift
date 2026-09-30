import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class CodexExternalMCPIntegrationServiceTests: XCTestCase {
    func testRefreshAggregatesPaginatedStatusBeforeProjectingFigma() async {
        let server = FakeCodexExternalMCPAppServer(
            statusPages: [
                ["data": [["name": "other", "authStatus": "oAuth", "tools": [:]]], "nextCursor": "page-2"],
                ["data": [[
                    "name": CodexIntegrationConfiguration.settingsManagedFigmaServerName,
                    "authStatus": "oAuth",
                    "tools": ["whoami": [:]]
                ]], "nextCursor": NSNull()]
            ]
        )
        let snapshot = await makeService(server: server).refresh(definition: .figma())
        XCTAssertEqual(snapshot.state, .connected)
        XCTAssertEqual(snapshot.tools, [FigmaMCPToolCatalogEntry(name: "whoami")])
    }

    func testServiceEffectsSeparateConfigurationAndAppServerSettlement() async {
        let server = FakeCodexExternalMCPAppServer(
            statusResponse: ["data": []],
            loginResponse: ["authorizationUrl": validAuthorizationURL]
        )
        let service = makeService(server: server)
        let outcome = await service.connectWithEffects(definition: .figma())
        XCTAssertEqual(outcome.result, .authorizationRequired)
        XCTAssertEqual(outcome.effects.configuration, .verifiedPresent)
        XCTAssertEqual(outcome.effects.appServer.reload, .settled)
        XCTAssertEqual(outcome.effects.appServer.oauthListener, .settled)
    }

    func testConfigurationCleanupNeverInvokesCredentialLogout() async {
        let server = FakeCodexExternalMCPAppServer(statusResponse: ["data": []])
        let executor = CountingFigmaCredentialLogoutExecutor()
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { _, _ in
                .init(status: .updated, hasSettingsManagedFigma: false)
            },
            credentialLogoutExecutor: executor
        )

        let outcome = await service.removeManagedConfiguration(definition: .figma())

        XCTAssertEqual(outcome.result, .disconnected)
        XCTAssertEqual(outcome.effects.configuration, .verifiedAbsent)
        XCTAssertEqual(outcome.effects.credentialLogout, .none)
        XCTAssertEqual(outcome.effects.appServer.reload, .settled)
        let logoutCallCount = await executor.callCount()
        XCTAssertEqual(logoutCallCount, 0)
        XCTAssertEqual(server.requestedMethods, ["config/mcpServer/reload"])
    }

    func testRecreatedServiceRequiresFreshOAuthAfterCodexFigmaCredentialLogout() async throws {
        let credentialStore = StatefulCodexFigmaCredentialStore()
        let firstServer = StatefulCredentialFigmaAppServer(
            credentialStore: credentialStore,
            authorizationURL: validAuthorizationURL
        )
        let firstService = makeStatefulCredentialService(
            server: firstServer,
            credentialStore: credentialStore
        )

        let initiallyConnected = await firstService.refresh(definition: .figma())
        XCTAssertEqual(initiallyConnected.state, .connected)
        XCTAssertEqual(initiallyConnected.authentication, .authenticated)

        let disconnected = await firstService.disconnectWithEffects(definition: .figma())
        XCTAssertEqual(disconnected.result, .disconnected)
        XCTAssertEqual(
            disconnected.effects.credentialLogout,
            .init(settlement: .settled, outcome: .credentialAbsent)
        )
        let logoutCount = await credentialStore.logoutCount()
        let credentialPresent = await credentialStore.hasCredential()
        XCTAssertEqual(logoutCount, 1)
        XCTAssertFalse(credentialPresent)

        let secondServer = StatefulCredentialFigmaAppServer(
            credentialStore: credentialStore,
            authorizationURL: validAuthorizationURL
        )
        let recreatedService = makeStatefulCredentialService(
            server: secondServer,
            credentialStore: credentialStore
        )

        let afterRecreation = await recreatedService.refresh(definition: .figma())
        XCTAssertEqual(afterRecreation.state, .authorizationRequired)
        XCTAssertEqual(afterRecreation.authentication, .notLoggedIn)

        let login = await recreatedService.connect(definition: .figma())
        XCTAssertEqual(login.0, .authorizationRequired)
        let request = try XCTUnwrap(login.1)
        XCTAssertEqual(request.url, URL(string: validAuthorizationURL))
        XCTAssertTrue(FigmaMCPOAuthAuthorizationURL.isValid(request.url))
        let logoutCountAfterRecreation = await credentialStore.logoutCount()
        let secondServerMethods = await secondServer.requestedMethodsSnapshot()
        XCTAssertEqual(logoutCountAfterRecreation, 1)
        XCTAssertEqual(
            secondServerMethods,
            ["config/mcpServer/reload", "mcpServerStatus/list", "config/mcpServer/reload", "mcpServer/oauth/login"]
        )
    }

    func testManagedDisconnectTreatsAlreadyAbsentCredentialAsSuccessBeforeConfigurationRemovalAndReload() async {
        let recorder = FigmaLogoutMatrixRecorder()
        let server = RecordingCodexExternalMCPAppServer(recorder: recorder)
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { definition, _ in
                XCTAssertNil(definition)
                recorder.append("provision")
                return .init(status: .updated, hasSettingsManagedFigma: false)
            },
            credentialLogoutExecutor: TestFigmaCredentialLogoutExecutor(
                outcome: .credentialAbsent,
                recorder: recorder
            )
        )

        let outcome = await service.disconnectWithEffects(definition: .figma())

        XCTAssertEqual(outcome.result, .disconnected)
        XCTAssertEqual(
            outcome.effects,
            .init(
                configuration: .verifiedAbsent,
                appServer: .init(reload: .settled, oauthListener: .notRequested),
                credentialLogout: .init(settlement: .settled, outcome: .credentialAbsent)
            )
        )
        XCTAssertEqual(recorder.events, ["logout", "provision", "config/mcpServer/reload"])
    }

    func testManagedDisconnectCredentialFailurePreventsConfigurationRemovalAndReload() async {
        await assertManagedDisconnectStopsAfterCredentialLogout(
            outcome: .failed,
            result: .failed,
            credentialSettlement: .settled
        )
    }

    func testManagedDisconnectIndeterminateLogoutPreventsConfigurationRemovalAndReload() async {
        await assertManagedDisconnectStopsAfterCredentialLogout(
            outcome: .indeterminate,
            result: .cancelled,
            credentialSettlement: .unknown
        )
    }

    func testRefreshProjectsAuthenticatedDynamicCatalog() async {
        let server = FakeCodexExternalMCPAppServer(
            statusResponse: [
                "data": [[
                    "name": CodexIntegrationConfiguration.settingsManagedFigmaServerName,
                    "authStatus": "oAuth",
                    "tools": ["whoami": [:], "get_design_context": [:]]
                ]]
            ]
        )
        let service = makeService(server: server)

        let snapshot = await service.refresh(definition: .figma())

        XCTAssertEqual(snapshot.state, .connected)
        XCTAssertEqual(snapshot.authentication, .authenticated)
        XCTAssertEqual(snapshot.tools.map(\.name), ["get_design_context", "whoami"])
        XCTAssertNotNil(snapshot.lastSuccessfulCheck)
        XCTAssertNil(snapshot.failureMessage)
        XCTAssertEqual(server.requestedMethods, ["config/mcpServer/reload", "mcpServerStatus/list"])
    }

    func testSleepCancellationRestoresLastSettledStatusWithoutCancellingInteractiveWork() async throws {
        let server = BlockingStatusCodexExternalMCPAppServer()
        let service = makeService(server: server)

        let refreshTask = Task { await service.refreshWithReceipt(definition: .figma()) }
        try await waitUntil { await server.isWaitingForStatusResponse() }
        await service.cancelStatusRefresh()
        await server.finishStatusRequest()
        let returned = await refreshTask.value
        let current = await service.snapshot()

        XCTAssertFalse(returned.isAuthoritative)
        XCTAssertEqual(returned.snapshot, .notConfigured)
        XCTAssertEqual(current, .notConfigured)
    }

    func testAdoptedRefreshAndReconnectDoNotRequireOrCreateASettingsManagedMarker() async {
        let server = FakeCodexExternalMCPAppServer(
            statusResponse: [
                "data": [[
                    "name": "figma",
                    "authStatus": "oAuth",
                    "tools": ["whoami": [:]]
                ]]
            ],
            loginResponse: ["authorizationUrl": validAuthorizationURL]
        )
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { _, _ in
                XCTFail("adopted Figma must not require a Settings-managed marker")
                return .init(status: .failed(.serverNameConflict), hasSettingsManagedFigma: false)
            }
        )

        let refreshed = await service.refresh(definition: .adoptedFigmaImport())
        XCTAssertEqual(refreshed.state, .connected)
        XCTAssertEqual(refreshed.authentication, .authenticated)

        let reconnected = await service.connect(definition: .adoptedFigmaImport())
        XCTAssertEqual(reconnected.0, .authorizationRequired)
        XCTAssertEqual(server.requestedMethods, [
            "config/mcpServer/reload", "mcpServerStatus/list",
            "config/mcpServer/reload", "mcpServer/oauth/login"
        ])
    }

    func testRefreshProjectsExpiredAuthenticationAsExpired() async {
        let server = FakeCodexExternalMCPAppServer(statusResponse: [
            "data": [[
                "name": "figma",
                "authStatus": "oAuthExpired",
                "tools": [:]
            ]]
        ])
        let service = makeService(server: server)

        let snapshot = await service.refresh(definition: .figma())

        XCTAssertEqual(snapshot.state, .expired)
        XCTAssertEqual(snapshot.authentication, .expired)
    }

    func testRefreshTreatsMalformedCatalogAsUnavailableWithoutExposingResponse() async {
        let server = FakeCodexExternalMCPAppServer(statusResponse: ["data": "access_token=not-for-display"])
        let service = makeService(server: server)

        let snapshot = await service.refresh(definition: .figma())

        XCTAssertEqual(snapshot.state, .serverUnavailable)
        XCTAssertEqual(snapshot.authentication, .unknown)
        XCTAssertTrue(snapshot.tools.isEmpty)
        XCTAssertFalse(snapshot.failureMessage?.contains("access_token") ?? true)
        XCTAssertFalse(snapshot.failureMessage?.contains("not-for-display") ?? true)
    }

    func testConnectReturnsAuthorizationHandoffWithoutPersistingItInSnapshot() async {
        let server = FakeCodexExternalMCPAppServer(
            statusResponse: [:],
            loginResponse: ["authorizationUrl": validAuthorizationURL]
        )
        let service = makeService(server: server)

        let result = await service.connect(definition: .figma())

        XCTAssertEqual(result.0, .authorizationRequired)
        XCTAssertEqual(result.1?.url, URL(string: validAuthorizationURL))
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.state, .authorizationRequired)
        XCTAssertTrue(snapshot.tools.isEmpty)
        XCTAssertNil(snapshot.failureMessage)
    }

    func testOAuthCallbackOwnerLivesUntilCancellationOrMatchingBrowserHandoffAbandonsIt() async throws {
        let tracker = OAuthListenerLifetimeTracker(authorizationURL: validAuthorizationURL)
        let service = CodexExternalMCPIntegrationService(
            factory: { tracker.makeServer() },
            provisioner: { _, _ in
                .init(status: .updated, hasSettingsManagedFigma: true)
            }
        )

        let outcome = await service.connectWithEffects(definition: .figma())
        let request = try XCTUnwrap(outcome.authorizationRequest)
        XCTAssertTrue(tracker.hasLiveServer)

        await service.settleAuthorizationHandoff(id: UUID(), disposition: .abandoned)
        XCTAssertTrue(tracker.hasLiveServer, "A stale handoff must not release the current callback listener")

        await service.settleAuthorizationHandoff(id: request.id, disposition: .opened)
        XCTAssertTrue(tracker.hasLiveServer, "The callback listener must survive after the browser opens")

        await service.cancelCurrentOperation()
        XCTAssertFalse(tracker.hasLiveServer, "Explicit cancellation must release an already-issued callback listener")

        let replacement = await service.connectWithEffects(definition: .figma())
        let replacementRequest = try XCTUnwrap(replacement.authorizationRequest)
        XCTAssertTrue(tracker.hasLiveServer)
        await service.settleAuthorizationHandoff(id: replacementRequest.id, disposition: .abandoned)
        XCTAssertFalse(tracker.hasLiveServer)
    }

    func testProvisioningFailureReleasesPendingOAuthCallbackOwner() async throws {
        let tracker = OAuthListenerLifetimeTracker(authorizationURL: validAuthorizationURL)
        let provisioning = FigmaProvisioningSequence()
        let service = CodexExternalMCPIntegrationService(
            factory: { tracker.makeServer() },
            provisioner: { _, _ in provisioning.next() }
        )

        let outcome = await service.connectWithEffects(definition: .figma())
        _ = try XCTUnwrap(outcome.authorizationRequest)
        XCTAssertTrue(tracker.hasLiveServer)

        let snapshot = await service.refresh(definition: .figma())
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertFalse(tracker.hasLiveServer)
    }

    func testAuthorizationURLRejectsNonCanonicalOriginPathAndCallback() throws {
        XCTAssertTrue(try FigmaMCPOAuthAuthorizationURL.isValid(XCTUnwrap(URL(string: validAuthorizationURL))))
        XCTAssertFalse(try FigmaMCPOAuthAuthorizationURL.isValid(XCTUnwrap(URL(string: validAuthorizationURL.replacingOccurrences(of: "/oauth/mcp", with: "/oauth")))))
        XCTAssertFalse(try FigmaMCPOAuthAuthorizationURL.isValid(XCTUnwrap(URL(string: validAuthorizationURL.replacingOccurrences(of: "resource=https%3A%2F%2Fmcp.figma.com%2Fmcp", with: "resource=https%3A%2F%2Fevil.example%2Fmcp")))))
        XCTAssertFalse(try FigmaMCPOAuthAuthorizationURL.isValid(XCTUnwrap(URL(string: validAuthorizationURL.replacingOccurrences(of: "&resource=https%3A%2F%2Fmcp.figma.com%2Fmcp", with: "")))))
        XCTAssertFalse(try FigmaMCPOAuthAuthorizationURL.isValid(XCTUnwrap(URL(string: validAuthorizationURL + "&resource=https%3A%2F%2Fmcp.figma.com%2Fmcp"))))
        XCTAssertFalse(try FigmaMCPOAuthAuthorizationURL.isValid(XCTUnwrap(URL(string: "https://evil.figma.com/oauth?client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback&state=x&response_type=code"))))
        XCTAssertFalse(try FigmaMCPOAuthAuthorizationURL.isValid(XCTUnwrap(URL(string: "https://www.figma.com/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback&state=x&response_type=code"))))
        XCTAssertFalse(try FigmaMCPOAuthAuthorizationURL.isValid(XCTUnwrap(URL(string: "https://www.figma.com/oauth?client_id=x&redirect_uri=https%3A%2F%2Fexample.invalid%2Fcallback&state=x&response_type=code"))))
        XCTAssertFalse(try FigmaMCPOAuthAuthorizationURL.isValid(XCTUnwrap(URL(string: "https://www.figma.com/oauth?client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback&state=x&response_type=token"))))
    }

    func testConnectRejectsNonFigmaOAuthHandoffURL() async {
        let server = FakeCodexExternalMCPAppServer(
            statusResponse: [:],
            loginResponse: ["authorizationUrl": "https://example.invalid/authorize?state=secret"]
        )
        let service = makeService(server: server)

        let result = await service.connect(definition: .figma())

        XCTAssertEqual(result.0, .failed)
        XCTAssertNil(result.1)
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertFalse(snapshot.failureMessage?.contains("secret") ?? true)
    }

    func testDiscoveryReadsExistingImportWithoutWritingASettingsManagedBlock() async {
        let server = FakeCodexExternalMCPAppServer(
            statusResponse: [
                "data": [[
                    "name": "figma",
                    "authStatus": "oAuth",
                    "tools": ["whoami": [:]]
                ]]
            ]
        )
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { _, _ in
                XCTFail("adoption discovery must not reconcile a managed registration")
                return .init(status: .failed(.serverNameConflict), hasSettingsManagedFigma: false)
            },
            importInspector: { _ in .imported }
        )

        let discovery = await service.discoverExistingImport()

        guard case let .available(snapshot) = discovery else {
            return XCTFail("Expected discovered Figma import, got \(discovery)")
        }
        XCTAssertEqual(snapshot.state, .connected)
        XCTAssertEqual(snapshot.authentication, .authenticated)
        XCTAssertEqual(snapshot.tools, [FigmaMCPToolCatalogEntry(name: "whoami")])
        XCTAssertNotNil(snapshot.lastSuccessfulCheck)
        XCTAssertEqual(server.requestedMethods, ["config/mcpServer/reload", "mcpServerStatus/list"])
    }

    func testAdoptedDisconnectNeverInvokesProvisioningOrMutatesUserConfiguration() async {
        let server = FakeCodexExternalMCPAppServer(statusResponse: [:])
        let executor = CountingFigmaCredentialLogoutExecutor()
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { _, _ in
                XCTFail("adopted disconnect must not remove a Settings-managed block")
                return .init(status: .failed(.serverNameConflict), hasSettingsManagedFigma: false)
            },
            credentialLogoutExecutor: executor
        )

        let result = await service.disconnect(
            definition: .adoptedFigmaImport(repoPromptActivation: .disabled)
        )

        XCTAssertEqual(result, .disconnected)
        XCTAssertEqual(server.startCount, 0)
        XCTAssertTrue(server.requestedMethods.isEmpty)
        let logoutCallCount = await executor.callCount()
        XCTAssertEqual(logoutCallCount, 0)
    }

    func testCancelledDisconnectDoesNotStartOrReloadCodex() async {
        let server = FakeCodexExternalMCPAppServer(statusResponse: [:])
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { _, _ in
                .init(status: .cancelled, hasSettingsManagedFigma: true)
            },
            credentialLogoutExecutor: TestFigmaCredentialLogoutExecutor()
        )

        let result = await service.disconnect(definition: .figma())

        let snapshot = await service.snapshot()
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(snapshot, .notConfigured)
        XCTAssertEqual(server.startCount, 0)
        XCTAssertTrue(server.requestedMethods.isEmpty)
    }

    func testManagedDisconnectExposesCommitUncertainEffect() async {
        let server = FakeCodexExternalMCPAppServer(statusResponse: [:])
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { definition, _ in
                if definition == nil {
                    return .init(
                        status: .failed(.readBack),
                        hasSettingsManagedFigma: true,
                        recovery: .replacementMayHaveCommitted
                    )
                }
                return .init(status: .updated, hasSettingsManagedFigma: true)
            },
            credentialLogoutExecutor: TestFigmaCredentialLogoutExecutor()
        )

        let outcome = await service.disconnectWithEffects(definition: .figma())

        XCTAssertEqual(outcome.result, .failed)
        XCTAssertEqual(
            outcome.effects,
            .init(
                configuration: .commitUncertain,
                appServer: .none,
                credentialLogout: .init(settlement: .settled, outcome: .credentialAbsent)
            )
        )
    }

    func testProvisioningFailureDuringDisconnectMapsToFailedAndClearsSnapshot() async {
        let server = FakeCodexExternalMCPAppServer(statusResponse: [:])
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { definition, _ in
                if definition == nil {
                    return .init(
                        status: .failed(.managedWrite),
                        hasSettingsManagedFigma: true
                    )
                }
                return .init(status: .updated, hasSettingsManagedFigma: true)
            },
            credentialLogoutExecutor: TestFigmaCredentialLogoutExecutor()
        )
        _ = await service.refresh(definition: .figma())

        let result = await service.disconnect(definition: .figma())

        let snapshot = await service.snapshot()
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(snapshot, .notConfigured)
        XCTAssertEqual(
            server.requestedMethods,
            ["config/mcpServer/reload", "mcpServerStatus/list"]
        )
    }

    func testDisconnectClearsCatalogAndTimestampBeforeReloadSettles() async throws {
        let server = BlockingDisconnectReloadCodexExternalMCPAppServer()
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { definition, _ in
                .init(
                    status: .updated,
                    hasSettingsManagedFigma: definition != nil
                )
            },
            credentialLogoutExecutor: TestFigmaCredentialLogoutExecutor()
        )
        let connected = await service.refresh(definition: .figma())
        XCTAssertEqual(connected.state, .connected)
        XCTAssertFalse(connected.tools.isEmpty)
        XCTAssertNotNil(connected.lastSuccessfulCheck)

        let disconnectTask = Task { await service.disconnect(definition: .figma()) }
        try await waitUntil { await server.isWaitingForDisconnectReload() }

        let duringDisconnect = await service.snapshot()
        XCTAssertEqual(duringDisconnect.state, .connecting)
        XCTAssertEqual(duringDisconnect.authentication, .unknown)
        XCTAssertTrue(duringDisconnect.tools.isEmpty)
        XCTAssertNil(duringDisconnect.lastSuccessfulCheck)

        await server.finishDisconnectReload()
        let result = await disconnectTask.value
        let settledSnapshot = await service.snapshot()
        XCTAssertEqual(result, .disconnected)
        XCTAssertEqual(settledSnapshot, .notConfigured)
    }

    func testCancelledDisconnectCannotRestorePreviousConnectedCatalog() async throws {
        let server = BlockingDisconnectReloadCodexExternalMCPAppServer()
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { definition, _ in
                .init(
                    status: .updated,
                    hasSettingsManagedFigma: definition != nil
                )
            },
            credentialLogoutExecutor: TestFigmaCredentialLogoutExecutor()
        )
        _ = await service.refresh(definition: .figma())

        let disconnectTask = Task { await service.disconnectWithEffects(definition: .figma()) }
        try await waitUntil { await server.isWaitingForDisconnectReload() }
        await service.cancelCurrentOperation()
        await server.finishDisconnectReload()

        let outcome = await disconnectTask.value
        let snapshot = await service.snapshot()
        XCTAssertEqual(outcome.result, .cancelled)
        XCTAssertEqual(outcome.effects.appServer.reload, .unknown)
        XCTAssertEqual(snapshot, .notConfigured)
    }

    func testDisabledDefinitionIsHardNoOpForConnectAndRefresh() async {
        let server = FakeCodexExternalMCPAppServer(
            statusResponse: [:],
            loginResponse: ["authorizationUrl": validAuthorizationURL]
        )
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { _, _ in
                XCTFail("disabled definitions must not provision configuration")
                return .init(status: .failed(.managedWrite), hasSettingsManagedFigma: false)
            },
            credentialLogoutExecutor: TestFigmaCredentialLogoutExecutor()
        )
        let disabledDefinition = ExternalMCPIntegrationDefinition.figma(
            repoPromptActivation: .disabled
        )

        let connectResult = await service.connect(definition: disabledDefinition)
        let refreshResult = await service.refresh(definition: disabledDefinition)

        let snapshot = await service.snapshot()
        XCTAssertEqual(connectResult.0, .cancelled)
        XCTAssertNil(connectResult.1)
        XCTAssertEqual(refreshResult, .notConfigured)
        XCTAssertEqual(snapshot, .notConfigured)
        XCTAssertEqual(server.startCount, 0)
        XCTAssertTrue(server.requestedMethods.isEmpty)
    }

    func testDisabledSettingsManagedDefinitionStillAllowsDisconnectRetry() async {
        let server = FakeCodexExternalMCPAppServer(statusResponse: [:])
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { definition, _ in
                XCTAssertNil(definition)
                return .init(status: .updated, hasSettingsManagedFigma: false)
            },
            credentialLogoutExecutor: TestFigmaCredentialLogoutExecutor()
        )
        let disabledDefinition = ExternalMCPIntegrationDefinition.figma(
            repoPromptActivation: .disabled
        )

        let result = await service.disconnect(definition: disabledDefinition)

        let snapshot = await service.snapshot()
        XCTAssertEqual(result, .disconnected)
        XCTAssertEqual(snapshot, .notConfigured)
        XCTAssertEqual(server.requestedMethods, ["config/mcpServer/reload"])
    }

    func testInvalidationClearsSnapshotWithoutProvisioningOrAppServerWork() async {
        let server = FakeCodexExternalMCPAppServer(statusResponse: [
            "data": [[
                "name": "figma",
                "authStatus": "oAuth",
                "tools": ["whoami": [:]]
            ]]
        ])
        let service = makeService(server: server)
        _ = await service.refresh(definition: .figma())
        let methodsBeforeInvalidation = server.requestedMethods
        let startsBeforeInvalidation = server.startCount

        await service.invalidatePresentationSnapshot()

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot, .notConfigured)
        XCTAssertEqual(server.startCount, startsBeforeInvalidation)
        XCTAssertEqual(server.requestedMethods, methodsBeforeInvalidation)
    }

    func testDelayedStatusCannotOverwriteNewerInvalidationGeneration() async throws {
        let server = BlockingStatusCodexExternalMCPAppServer()
        let service = makeService(server: server)
        let refreshTask = Task { await service.refresh(definition: .figma()) }
        try await waitUntil { await server.isWaitingForStatusResponse() }

        await service.invalidatePresentationSnapshot()
        await server.finishStatusRequest(
            response: [
                "data": [[
                    "name": "figma",
                    "authStatus": "oAuth",
                    "tools": ["stale_tool": [:]]
                ]]
            ]
        )

        let returnedSnapshot = await refreshTask.value
        let currentSnapshot = await service.snapshot()
        XCTAssertEqual(returnedSnapshot, .notConfigured)
        XCTAssertEqual(currentSnapshot, .notConfigured)
    }

    private var validAuthorizationURL: String {
        "https://www.figma.com/oauth/mcp?response_type=code&client_id=codex&state=0123456789abcdef&code_challenge=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&code_challenge_method=S256&redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback%2Fopaque&scope=mcp%3Aconnect&resource=https%3A%2F%2Fmcp.figma.com%2Fmcp"
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let step: UInt64 = 10_000_000
        var waited: UInt64 = 0
        while await !condition(), waited < timeoutNanoseconds {
            try await Task.sleep(nanoseconds: step)
            waited += step
        }
        let completed = await condition()
        XCTAssertTrue(completed, "Condition did not become true before timeout")
    }

    private func makeStatefulCredentialService(
        server: some CodexExternalMCPAppServer,
        credentialStore: StatefulCodexFigmaCredentialStore
    ) -> CodexExternalMCPIntegrationService {
        let runtime = CodexRuntimeAuthority.Runtime(
            executableURL: URL(fileURLWithPath: "/tmp/codex"),
            version: CodexRuntimeAuthority.bundledVersion,
            source: .bundled(target: "test"),
            statePaths: .init(
                codexHome: URL(fileURLWithPath: "/tmp/home"),
                sqliteHome: URL(fileURLWithPath: "/tmp/sqlite")
            )
        )
        let resolution = CodexProviderHelpers.CodexExecutableResolution(
            commandName: "codex",
            resolvedCommand: runtime.executableURL.path,
            status: .available,
            runtime: runtime,
            userMessage: "",
            debugMessage: ""
        )
        let credentialLogoutExecutor = CodexFigmaMCPCredentialLogoutExecutor(
            environmentBuilder: { request in
                .init(
                    environment: request.inheritedEnvironment,
                    launchContext: .detect(from: request.inheritedEnvironment),
                    shellEnvironmentSource: .capturedLoginShell
                )
            },
            runtimeResolver: { _ in resolution },
            runtimePreparer: { _ in },
            processRunner: { _ in
                await credentialStore.logout()
                return .init(status: 0, timedOut: false)
            }
        )
        return CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { definition, _ in
                .init(status: .updated, hasSettingsManagedFigma: definition != nil)
            },
            credentialLogoutExecutor: credentialLogoutExecutor
        )
    }

    private func assertManagedDisconnectStopsAfterCredentialLogout(
        outcome logoutOutcome: FigmaMCPCredentialLogoutOutcome,
        result expectedResult: FigmaMCPDisconnectResult,
        credentialSettlement expectedCredentialSettlement: FigmaMCPCredentialLogoutSettlement
    ) async {
        let recorder = FigmaLogoutMatrixRecorder()
        let server = RecordingCodexExternalMCPAppServer(recorder: recorder)
        let service = CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { _, _ in
                recorder.append("provision")
                return .init(status: .updated, hasSettingsManagedFigma: false)
            },
            credentialLogoutExecutor: TestFigmaCredentialLogoutExecutor(
                outcome: logoutOutcome,
                recorder: recorder
            )
        )

        let serviceOutcome = await service.disconnectWithEffects(definition: .figma())
        let snapshot = await service.snapshot()

        XCTAssertEqual(serviceOutcome.result, expectedResult)
        XCTAssertEqual(serviceOutcome.effects.configuration, .none)
        XCTAssertEqual(serviceOutcome.effects.appServer, .none)
        XCTAssertEqual(
            serviceOutcome.effects.credentialLogout,
            .init(settlement: expectedCredentialSettlement, outcome: logoutOutcome)
        )
        XCTAssertEqual(snapshot, .notConfigured)
        XCTAssertEqual(recorder.events, ["logout"])
    }

    private func makeService(
        server: some CodexExternalMCPAppServer
    ) -> CodexExternalMCPIntegrationService {
        CodexExternalMCPIntegrationService(
            factory: { server },
            provisioner: { _, _ in
                .init(status: .updated, hasSettingsManagedFigma: true)
            },
            credentialLogoutExecutor: TestFigmaCredentialLogoutExecutor()
        )
    }
}

private actor CountingFigmaCredentialLogoutExecutor: CodexFigmaMCPCredentialLogoutExecuting {
    private var calls = 0

    func logoutFigmaCredential() async -> FigmaMCPCredentialLogoutOutcome {
        calls += 1
        return .credentialAbsent
    }

    func callCount() -> Int {
        calls
    }
}

private actor TestFigmaCredentialLogoutExecutor: CodexFigmaMCPCredentialLogoutExecuting {
    private let outcome: FigmaMCPCredentialLogoutOutcome
    private let recorder: FigmaLogoutMatrixRecorder?

    init(
        outcome: FigmaMCPCredentialLogoutOutcome = .credentialAbsent,
        recorder: FigmaLogoutMatrixRecorder? = nil
    ) {
        self.outcome = outcome
        self.recorder = recorder
    }

    func logoutFigmaCredential() async -> FigmaMCPCredentialLogoutOutcome {
        recorder?.append("logout")
        return outcome
    }
}

private final class FigmaLogoutMatrixRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}

private final class RecordingCodexExternalMCPAppServer: @unchecked Sendable, CodexExternalMCPAppServer {
    private let recorder: FigmaLogoutMatrixRecorder

    init(recorder: FigmaLogoutMatrixRecorder) {
        self.recorder = recorder
    }

    func startIfNeeded() async throws {}

    func request(method _: String, params _: [String: Any]?, timeout _: TimeInterval?) async throws -> [String: Any] {
        [:]
    }

    func requestWithSettlementDeadline(
        method: String,
        params _: [String: Any]?,
        deadline _: TimeInterval
    ) async throws -> [String: Any] {
        recorder.append(method)
        return [:]
    }
}

private actor StatefulCodexFigmaCredentialStore {
    private var credentialPresent = true
    private var logoutCalls = 0

    func logout() {
        credentialPresent = false
        logoutCalls += 1
    }

    func hasCredential() -> Bool {
        credentialPresent
    }

    func logoutCount() -> Int {
        logoutCalls
    }

    func authStatus() -> String {
        credentialPresent ? "oAuth" : "notLoggedIn"
    }
}

private actor StatefulCredentialFigmaAppServer: CodexExternalMCPAppServer {
    private let credentialStore: StatefulCodexFigmaCredentialStore
    private let authorizationURL: String
    private var requestedMethods: [String] = []

    init(
        credentialStore: StatefulCodexFigmaCredentialStore,
        authorizationURL: String
    ) {
        self.credentialStore = credentialStore
        self.authorizationURL = authorizationURL
    }

    func startIfNeeded() async throws {}

    func request(
        method: String,
        params _: [String: Any]?,
        timeout _: TimeInterval?
    ) async throws -> [String: Any] {
        requestedMethods.append(method)
        switch method {
        case "mcpServerStatus/list":
            let authStatus = await credentialStore.authStatus()
            return [
                "data": [[
                    "name": "figma",
                    "authStatus": authStatus,
                    "tools": ["whoami": [:]]
                ]]
            ]
        case "mcpServer/oauth/login":
            return ["authorizationUrl": authorizationURL]
        default:
            return [:]
        }
    }

    func requestWithSettlementDeadline(
        method: String,
        params _: [String: Any]?,
        deadline _: TimeInterval
    ) async throws -> [String: Any] {
        requestedMethods.append(method)
        return [:]
    }

    func requestedMethodsSnapshot() -> [String] {
        requestedMethods
    }
}

private final class FigmaProvisioningSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func next() -> CodexIntegrationConfiguration.SettingsManagedMCPUpdateResult {
        lock.withLock {
            callCount += 1
            if callCount == 1 {
                return .init(status: .updated, hasSettingsManagedFigma: true)
            }
            return .init(status: .failed(.managedWrite), hasSettingsManagedFigma: true)
        }
    }
}

private final class OAuthListenerLifetimeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let authorizationURL: String
    private weak var liveServer: LifetimeTrackedFigmaAppServer?

    init(authorizationURL: String) {
        self.authorizationURL = authorizationURL
    }

    var hasLiveServer: Bool {
        lock.withLock { liveServer != nil }
    }

    func makeServer() -> any CodexExternalMCPAppServer {
        let server = LifetimeTrackedFigmaAppServer(authorizationURL: authorizationURL)
        lock.withLock { liveServer = server }
        return server
    }
}

private final class LifetimeTrackedFigmaAppServer: @unchecked Sendable, CodexExternalMCPAppServer {
    private let authorizationURL: String

    init(authorizationURL: String) {
        self.authorizationURL = authorizationURL
    }

    func startIfNeeded() async throws {}

    func request(method: String, params _: [String: Any]?, timeout _: TimeInterval?) async throws -> [String: Any] {
        method == "mcpServer/oauth/login" ? ["authorizationUrl": authorizationURL] : [:]
    }

    func requestWithSettlementDeadline(
        method _: String,
        params _: [String: Any]?,
        deadline _: TimeInterval
    ) async throws -> [String: Any] {
        [:]
    }
}

private actor BlockingStatusCodexExternalMCPAppServer: CodexExternalMCPAppServer {
    private var statusContinuation: CheckedContinuation<[String: Any], Never>?

    func startIfNeeded() async throws {}

    func request(method: String, params _: [String: Any]?, timeout _: TimeInterval?) async throws -> [String: Any] {
        guard method == "mcpServerStatus/list" else { return [:] }
        return await withCheckedContinuation { continuation in
            statusContinuation = continuation
        }
    }

    func requestWithSettlementDeadline(method _: String, params _: [String: Any]?, deadline _: TimeInterval) async throws -> [String: Any] {
        [:]
    }

    func isWaitingForStatusResponse() -> Bool {
        statusContinuation != nil
    }

    func finishStatusRequest(response: [String: Any] = ["data": []]) {
        statusContinuation?.resume(returning: response)
        statusContinuation = nil
    }
}

private actor BlockingDisconnectReloadCodexExternalMCPAppServer: CodexExternalMCPAppServer {
    private var reloadCount = 0
    private var disconnectReloadContinuation: CheckedContinuation<[String: Any], Never>?

    func startIfNeeded() async throws {}

    func request(
        method: String,
        params _: [String: Any]?,
        timeout _: TimeInterval?
    ) async throws -> [String: Any] {
        guard method == "mcpServerStatus/list" else { return [:] }
        return [
            "data": [[
                "name": "figma",
                "authStatus": "oAuth",
                "tools": ["whoami": [:]]
            ]]
        ]
    }

    func requestWithSettlementDeadline(
        method _: String,
        params _: [String: Any]?,
        deadline _: TimeInterval
    ) async throws -> [String: Any] {
        reloadCount += 1
        guard reloadCount > 1 else { return [:] }
        return await withCheckedContinuation { continuation in
            disconnectReloadContinuation = continuation
        }
    }

    func isWaitingForDisconnectReload() -> Bool {
        disconnectReloadContinuation != nil
    }

    func finishDisconnectReload() {
        disconnectReloadContinuation?.resume(returning: [:])
        disconnectReloadContinuation = nil
    }
}

private final class FakeCodexExternalMCPAppServer: @unchecked Sendable, CodexExternalMCPAppServer {
    private let lock = NSLock()
    private let statusResponse: [String: Any]
    private let statusPages: [[String: Any]]
    private let loginResponse: [String: Any]
    private var statusPageIndex = 0
    private(set) var startCount = 0
    private(set) var requestedMethods: [String] = []

    init(
        statusResponse: [String: Any] = [:],
        loginResponse: [String: Any] = [:],
        statusPages: [[String: Any]] = []
    ) {
        self.statusResponse = statusResponse
        self.statusPages = statusPages
        self.loginResponse = loginResponse
    }

    func startIfNeeded() async throws {
        lock.withLock { startCount += 1 }
    }

    func request(method: String, params _: [String: Any]?, timeout _: TimeInterval?) async throws -> [String: Any] {
        lock.withLock { requestedMethods.append(method) }
        switch method {
        case "mcpServerStatus/list":
            if !statusPages.isEmpty {
                let page = statusPages[min(statusPageIndex, statusPages.count - 1)]
                statusPageIndex += 1
                return page
            }
            return statusResponse
        case "mcpServer/oauth/login":
            return loginResponse
        default:
            return [:]
        }
    }

    func requestWithSettlementDeadline(method: String, params _: [String: Any]?, deadline _: TimeInterval) async throws -> [String: Any] {
        lock.withLock { requestedMethods.append(method) }
        return [:]
    }
}
