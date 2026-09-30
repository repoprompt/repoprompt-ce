import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class FigmaMCPIntegrationCoordinatorTests: XCTestCase {
    func testSettingsOwnersAreSerializedAndCannotSupersedeEachOther() async throws {
        let service = CoordinatorFakeService()
        let coordinator = FigmaMCPIntegrationCoordinator(service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let first = coordinator.beginInteractive(ownerID: UUID(), windowID: 1, kind: .connect, expectedDefinition: nil)
        XCTAssertNotNil(first)
        XCTAssertNil(coordinator.beginInteractive(ownerID: UUID(), windowID: 2, kind: .connect, expectedDefinition: nil))
        XCTAssertTrue(try coordinator.requestCancellation(XCTUnwrap(first)))
        let available = expectation(description: "cancellation settled")
        coordinator.notifyWhenSettingsOperationAvailable(id: UUID()) { available.fulfill() }
        await fulfillment(of: [available], timeout: 1)
        XCTAssertNotNil(coordinator.beginInteractive(ownerID: UUID(), windowID: 2, kind: .connect, expectedDefinition: nil))
    }

    func testLaunchAndWakeCoalesceIntoOnePublishedRefresh() async throws {
        let store = try makeStore(definition: .figma())
        let service = CoordinatorFakeService()
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        let coordinator = FigmaMCPIntegrationCoordinator(
            settingsStore: store,
            service: service,
            runtimeAvailability: authority
        )

        coordinator.requestPassiveRefresh(trigger: .launchRefresh)
        coordinator.applicationDidWake()
        let result = await coordinator.refreshNow(trigger: .settingsRefresh)

        XCTAssertTrue(result)
        let refreshCount = await service.refreshCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(authority.hasAuthenticatedRuntime)
        XCTAssertEqual(coordinator.state.operation, nil)
        XCTAssertFalse(coordinator.state.passiveRefreshPending)
    }

    func testRevisionedAuthorityRejectsStaleAuthenticatedPublication() {
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        let definition = ExternalMCPIntegrationDefinition.figma()
        let stale = authority.beginAuthoritativeRefresh(expectedDefinition: definition, operation: .launchRefresh)
        let current = authority.beginAuthoritativeRefresh(expectedDefinition: definition, operation: .wakeRefresh)
        authority.publish(ticketGeneration: stale.generation, snapshot: CoordinatorFakeService.connectedSnapshot, definition: definition)
        XCTAssertFalse(authority.hasAuthenticatedRuntime)
        authority.publish(ticketGeneration: current.generation, snapshot: CoordinatorFakeService.connectedSnapshot, definition: definition)
        XCTAssertTrue(authority.hasAuthenticatedRuntime)
    }

    func testExplicitRevocationPublishesOneRevisionedNotification() {
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        let expectation = expectation(description: "revocation")
        var observedRevision: UInt64?
        let token = NotificationCenter.default.addObserver(forName: FigmaMCPRuntimeAvailabilityAuthority.explicitRevocationNotification, object: nil, queue: .main) { notification in
            observedRevision = notification.userInfo?["revision"] as? UInt64
            expectation.fulfill()
        }
        authority.publish(snapshot: CoordinatorFakeService.connectedSnapshot, definition: .figma())
        authority.revokeForExplicitDisconnect()
        wait(for: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(token)
        XCTAssertFalse(authority.hasAuthenticatedRuntime)
        XCTAssertEqual(observedRevision, authority.revision)
    }

    func testExplicitRevocationIDIsExactlyOnce() {
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        let center = NotificationCenter()
        let id = UUID()
        var notifications = 0
        let token = center.addObserver(
            forName: FigmaMCPRuntimeAvailabilityAuthority.explicitRevocationNotification,
            object: nil,
            queue: nil
        ) { _ in notifications += 1 }
        let first = authority.revokeForExplicitDisconnect(revocationID: id, notificationCenter: center)
        let repeated = authority.revokeForExplicitDisconnect(revocationID: id, notificationCenter: center)
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(notifications, 1)
        center.removeObserver(token)
    }

    func testExplicitRevocationIDRemainsExactlyOnceAfterAnotherID() {
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        let center = NotificationCenter()
        let firstID = UUID()
        let secondID = UUID()
        var notifications = 0
        let token = center.addObserver(
            forName: FigmaMCPRuntimeAvailabilityAuthority.explicitRevocationNotification,
            object: nil,
            queue: nil
        ) { _ in notifications += 1 }
        let first = authority.revokeForExplicitDisconnect(revocationID: firstID, notificationCenter: center)
        _ = authority.revokeForExplicitDisconnect(revocationID: secondID, notificationCenter: center)
        let repeated = authority.revokeForExplicitDisconnect(revocationID: firstID, notificationCenter: center)
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(notifications, 2)
        center.removeObserver(token)
    }

    func testSleepClearsAuthorityButDoesNotCancelInteractiveOperation() throws {
        let service = CoordinatorFakeService()
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        let coordinator = FigmaMCPIntegrationCoordinator(service: service, runtimeAvailability: authority)
        let lease = try XCTUnwrap(coordinator.beginInteractive(ownerID: UUID(), windowID: 1, kind: .connect, expectedDefinition: nil))
        coordinator.applicationWillSleep()
        XCTAssertTrue(coordinator.isOwned(lease))
        XCTAssertTrue(coordinator.hasInteractiveOperation)
        XCTAssertFalse(authority.hasAuthenticatedRuntime)
        coordinator.finish(lease, connection: .notConfigured)
    }

    func testCompatibilityDefaultsUseTheInjectedAppLifetimeCoordinatorAndInjectionStaysIsolated() throws {
        let graph = FigmaMCPTestGraph.make()
        let shared = graph.figmaCoordinator
        XCTAssertIdentical(MCPIntegrationsRuntime.coordinator(externalMCPComposition: graph), shared)
        XCTAssertIdentical(
            MCPIntegrationsRuntime.coordinator(
                externalMCPComposition: graph,
                settingsStore: shared.settingsStore,
                service: shared.service,
                runtimeAvailability: shared.runtimeAvailabilityAuthority
            ),
            shared
        )

        let injectedStore = try makeStore()
        let injectedService = CoordinatorFakeService()
        let injected = MCPIntegrationsRuntime.coordinator(
            externalMCPComposition: graph,
            settingsStore: injectedStore,
            service: injectedService,
            runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority()
        )
        XCTAssertFalse(injected === shared)
        let legacyInjected = MCPIntegrationsRuntime.coordinator(
            for: injectedStore,
            service: injectedService,
            runtimeAvailability: nil,
            externalMCPComposition: graph
        )
        XCTAssertFalse(legacyInjected === shared)
        XCTAssertIdentical(
            legacyInjected,
            MCPIntegrationsRuntime.coordinator(
                for: injectedStore,
                service: injectedService,
                runtimeAvailability: nil,
                externalMCPComposition: graph
            )
        )
        XCTAssertIdentical(
            MCPIntegrationsRuntime.coordinator(
                externalMCPComposition: graph,
                settingsStore: injectedStore,
                service: injectedService,
                runtimeAvailability: legacyInjected.runtimeAvailabilityAuthority
            ),
            legacyInjected
        )
        MCPIntegrationsRuntime.register(injected)
        XCTAssertIdentical(MCPIntegrationsRuntime.coordinator(externalMCPComposition: graph), shared)
    }

    func testTerminationSuppressesCompletionReceipt() async throws {
        let service = CoordinatorFakeService()
        await service.setBlockConnect(true)
        let coordinator = try FigmaMCPIntegrationCoordinator(settingsStore: makeStore(), service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let operation = Task {
            await coordinator.performSettingsAction(.connect, requestID: UUID(), ownerID: UUID(), windowID: 1)
        }
        var waited: UInt64 = 0
        while await !(service.connectStarted()), waited < 1_000_000_000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 10_000_000
        }
        let connectDidStart = await service.connectStarted()
        XCTAssertTrue(connectDidStart)
        coordinator.applicationWillTerminate()
        await service.releaseConnect()
        let response = await operation.value
        XCTAssertEqual(response.result, .cancelled)
        XCTAssertNil(response.receipt)
    }

    func testDefinitionChangeAbandonsAuthorizationRequestReturnedByStaleConnect() async throws {
        let store = try makeStore()
        let service = CoordinatorFakeService()
        await service.setBlockConnect(true)
        try await service.setConnectResult(.init(
            result: .authorizationRequired,
            authorizationRequest: .init(
                id: UUID(),
                url: XCTUnwrap(URL(string: "https://www.figma.com/oauth/mcp?stale=true"))
            ),
            effects: .none
        ))
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let operation = Task {
            await coordinator.performSettingsAction(
                .connect,
                requestID: UUID(),
                ownerID: UUID(),
                windowID: 1
            )
        }

        try await waitUntil { await service.connectStarted() }
        XCTAssertTrue(store.setExternalMCPIntegration(.adoptedFigmaImport()))
        try await waitUntil { await service.invalidationCount() > 0 }
        await service.releaseConnect()

        let response = await operation.value
        let settlements = await service.authorizationHandoffDispositions()
        XCTAssertEqual(response.result, .cancelled)
        XCTAssertNil(response.receipt)
        XCTAssertEqual(settlements, [.abandoned])
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), .adoptedFigmaImport())
    }

    func testWindowSettingsAdaptersUseTheSameCoordinator() {
        let coordinator = FigmaMCPIntegrationCoordinator(service: CoordinatorFakeService(), runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let first = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, windowID: 1, coordinator: coordinator)
        let second = MCPIntegrationsSettingsViewModel(externalMCPComposition: FigmaMCPTestGraph.make(), cliAvailability: FigmaSettingsTestCLIAvailability.ready, windowID: 2, coordinator: coordinator)

        XCTAssertIdentical(first.figmaMCPCoordinator, coordinator)
        XCTAssertIdentical(second.figmaMCPCoordinator, coordinator)
        XCTAssertIdentical(first.figmaMCPCoordinator, second.figmaMCPCoordinator)
    }

    func testBusyResponseHasNoLeaseReceipt() async throws {
        let coordinator = FigmaMCPIntegrationCoordinator(service: CoordinatorFakeService(), runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let lease = try XCTUnwrap(coordinator.beginInteractive(ownerID: UUID(), windowID: 1, kind: .connect, expectedDefinition: nil))

        let response = await coordinator.performSettingsAction(
            .refresh,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 2
        )

        XCTAssertEqual(response.result, .busy)
        XCTAssertNil(response.receipt)
        coordinator.finish(lease, connection: .notConfigured)
    }

    func testCancelledConnectHasNoCompletionReceipt() async {
        let service = CoordinatorFakeService()
        await service.setConnectResult(.init(result: .cancelled, authorizationRequest: nil, effects: .none))
        let coordinator = FigmaMCPIntegrationCoordinator(service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(
            .connect,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 1
        )

        XCTAssertEqual(response.result, .cancelled)
        XCTAssertNil(response.receipt)
    }

    func testVerifiedAuthenticationReturnsAuthoritativeRequestScopedReceipt() async throws {
        let definition = ExternalMCPIntegrationDefinition.figma()
        let store = try makeStore(definition: definition)
        let service = CoordinatorFakeService()
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: authority)
        let requestID = UUID()
        let ownerID = UUID()

        let response = await coordinator.performSettingsAction(
            .verifyAuthentication,
            requestID: requestID,
            ownerID: ownerID,
            windowID: 42
        )
        let receipt = try XCTUnwrap(response.receipt)

        XCTAssertEqual(response.requestID, requestID)
        XCTAssertEqual(receipt.requestID, requestID)
        XCTAssertEqual(receipt.ownerID, ownerID)
        XCTAssertEqual(receipt.windowID, 42)
        XCTAssertEqual(receipt.action, .verifyAuthentication)
        XCTAssertEqual(receipt.generation, coordinator.state.revision)
        XCTAssertEqual(receipt.completion, .loginCompleted)
        XCTAssertTrue(authority.hasAuthenticatedRuntime)
    }

    func testAutomaticAuthorizationCompletionUsesAuthoritativeRefreshAndReceipt() async throws {
        let definition = ExternalMCPIntegrationDefinition.figma()
        let store = try makeStore(definition: definition)
        let service = CoordinatorFakeService()
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: authority)

        let response = await coordinator.performSettingsAction(
            .awaitAuthorizationCompletion,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 7
        )

        XCTAssertEqual(response.receipt?.action, .awaitAuthorizationCompletion)
        XCTAssertEqual(response.receipt?.completion, .loginCompleted)
        XCTAssertTrue(authority.hasAuthenticatedRuntime)
        let refreshCount = await service.refreshCount()
        XCTAssertEqual(refreshCount, 1)
    }

    func testImmediateAuthenticatedConnectReturnsLoginCompletion() async throws {
        let service = CoordinatorFakeService()
        await service.setConnectResult(.init(
            result: .connected(CoordinatorFakeService.connectedSnapshot),
            authorizationRequest: nil,
            effects: .init(configuration: .verifiedPresent, appServer: .none)
        ))
        let store = try makeStore()
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(
            .connect,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 1
        )

        XCTAssertEqual(response.receipt?.completion, .loginCompleted)
        XCTAssertEqual(store.externalMCPIntegration(for: .figma)?.repoPromptActivation, .enabled)
    }

    func testAuthorizationHandoffAndPassiveRefreshNeverReturnLoginCompletion() async throws {
        let service = CoordinatorFakeService()
        try await service.setConnectResult(.init(
            result: .authorizationRequired,
            authorizationRequest: .init(id: UUID(), url: XCTUnwrap(URL(string: "https://www.figma.com/oauth/mcp?handoff=true"))),
            effects: .none
        ))
        let emptyStore = try makeStore()
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: emptyStore, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let handoff = await coordinator.performSettingsAction(
            .connect,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 1
        )
        XCTAssertEqual(handoff.result.snapshot.state, .authorizationRequired)
        XCTAssertNil(handoff.receipt?.completion)

        let passiveStore = try makeStore(definition: .figma())
        let passiveService = CoordinatorFakeService()
        let passiveCoordinator = FigmaMCPIntegrationCoordinator(settingsStore: passiveStore, service: passiveService, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let refresh = await passiveCoordinator.performSettingsAction(
            .refresh,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 1
        )
        XCTAssertNil(refresh.receipt?.completion)
    }

    func testDisabledDefinitionCannotReturnLoginCompletion() async throws {
        let store = try makeStore()
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: CoordinatorFakeService(), runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(
            .verifyAuthentication,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 1
        )

        XCTAssertEqual(response.result, .cancelled)
        XCTAssertNil(response.receipt?.completion)
        XCTAssertFalse(coordinator.runtimeAvailability.hasAuthenticatedRuntime)
    }

    func testAbsentSignOutIsIdempotentWithoutCleanupOrRetryState() async throws {
        let store = try makeStore()
        let service = CoordinatorFakeService()
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(
            .signOut,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 1
        )

        XCTAssertEqual(response.result.snapshot, .notConfigured)
        XCTAssertFalse(response.result.isError)
        XCTAssertNil(response.receipt?.completion)
        XCTAssertNil(store.externalMCPIntegration(for: .figma))

        let disconnectCount = await service.disconnectCount()
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertFalse(coordinator.runtimeAvailability.hasAuthenticatedRuntime)
    }

    func testManagedSignOutReceiptRequiresCompletedDurableCleanup() async throws {
        let store = try makeStore(definition: .figma())
        let service = CoordinatorFakeService()
        await service.setDisconnectResult(.init(result: .disconnected, effects: .init(
            configuration: .verifiedAbsent,
            appServer: .init(reload: .settled, oauthListener: .notRequested),
            credentialLogout: .init(settlement: .settled, outcome: .credentialAbsent)
        )))
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(
            .signOut,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 1
        )

        XCTAssertEqual(response.receipt?.completion, .signOutCompleted)
        XCTAssertNil(store.externalMCPIntegration(for: .figma))
        XCTAssertFalse(coordinator.runtimeAvailability.hasAuthenticatedRuntime)
    }

    func testAdoptedSignOutReceiptDoesNotMutateImportedConfiguration() async throws {
        let definition = ExternalMCPIntegrationDefinition.adoptedFigmaImport()
        let store = try makeStore(definition: definition)
        let service = CoordinatorFakeService()
        await service.setDisconnectResult(.init(result: .disconnected, effects: .none))
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(
            .signOut,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 1
        )

        XCTAssertEqual(response.receipt?.completion, .signOutCompleted)
        XCTAssertNil(store.externalMCPIntegration(for: .figma))
        let disconnectedDefinition = await service.lastDisconnectedDefinition()
        XCTAssertEqual(disconnectedDefinition?.origin, .adoptedImport)
    }

    func testServiceCleanupFailureLeavesFigmaLoggedOutWithoutRetryState() async throws {
        let store = try makeStore(definition: .figma())
        let service = CoordinatorFakeService()
        await service.setDisconnectResult(.init(result: .cancelled, effects: .none))
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(
            .signOut,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 1
        )

        XCTAssertNil(response.receipt?.completion)
        XCTAssertTrue(response.result.isError)
        XCTAssertTrue(response.result.notice?.contains("did not confirm credential removal") == true)
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), .figma())
        XCTAssertTrue(coordinator.credentialRevocationRequired)
        XCTAssertFalse(coordinator.runtimeAvailability.hasAuthenticatedRuntime)
        XCTAssertNil(coordinator.beginInteractive(ownerID: UUID(), windowID: 2, kind: .settingsRefresh, expectedDefinition: .figma()))
    }

    func testUncertainServiceCleanupLeavesNoRegistrationOrRetryState() async throws {
        let store = try makeStore(definition: .figma())
        let service = CoordinatorFakeService()
        await service.setDisconnectResult(.init(result: .disconnected, effects: .init(configuration: .commitUncertain, appServer: .none)))
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(
            .signOut,
            requestID: UUID(),
            ownerID: UUID(),
            windowID: 1
        )

        XCTAssertNil(response.receipt?.completion)
        XCTAssertTrue(response.result.isError)
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), .figma())
        XCTAssertTrue(coordinator.credentialRevocationRequired)
        XCTAssertFalse(response.result.notice?.contains("Retry Sign Out") == true)
    }

    func testManagedSignOutWaitsForFigmaBoundSessionTerminalTeardown() async throws {
        let store = try makeStore(definition: .figma())
        let service = CoordinatorFakeService()
        await service.setBlockDisconnect(true)
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: authority)
        var participant: FigmaMCPRuntimeRevocationBarrier.Participant?
        let observer = NotificationCenter.default.addObserver(
            forName: FigmaMCPRuntimeAvailabilityAuthority.explicitRevocationNotification,
            object: nil,
            queue: .main
        ) { [authority] notification in
            participant = authority.explicitRevocationBarrier.registerParticipant(
                for: notification.userInfo?["revision"] as? UInt64 ?? authority.revision
            )
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let operation = Task {
            await coordinator.performSettingsAction(.signOut, requestID: UUID(), ownerID: UUID(), windowID: 1)
        }
        try await waitUntil { participant != nil }
        let disconnectStartedBeforeTeardown = await service.disconnectStarted()
        XCTAssertFalse(disconnectStartedBeforeTeardown)
        XCTAssertFalse(authority.hasAuthenticatedRuntime)

        if let participant {
            authority.explicitRevocationBarrier.complete(participant)
        } else {
            XCTFail("Figma revocation participant was not registered")
        }
        try await waitUntil { await service.disconnectStarted() }
        await service.setDisconnectResult(.init(result: .disconnected, effects: .init(
            configuration: .verifiedAbsent,
            appServer: .init(reload: .settled, oauthListener: .notRequested),
            credentialLogout: .init(settlement: .settled, outcome: .credentialAbsent)
        )))
        await service.releaseDisconnect()
        let response = await operation.value
        XCTAssertEqual(response.receipt?.completion, .signOutCompleted)
    }

    func testRevocationPrecedesManagedCleanupSettlement() async throws {
        let store = try makeStore(definition: .figma())
        let service = CoordinatorFakeService()
        await service.setBlockDisconnect(true)
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        authority.publish(snapshot: CoordinatorFakeService.connectedSnapshot, definition: .figma())
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: authority)
        let operation = Task {
            await coordinator.performSettingsAction(
                .signOut,
                requestID: UUID(),
                ownerID: UUID(),
                windowID: 1
            )
        }
        var waited: UInt64 = 0
        var disconnectDidStart = await service.disconnectStarted()
        while !disconnectDidStart, waited < 1_000_000_000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 10_000_000
            disconnectDidStart = await service.disconnectStarted()
        }
        XCTAssertTrue(disconnectDidStart)
        XCTAssertFalse(authority.hasAuthenticatedRuntime)
        await service.setDisconnectResult(.init(result: .disconnected, effects: .init(
            configuration: .verifiedAbsent,
            appServer: .init(reload: .settled, oauthListener: .notRequested),
            credentialLogout: .init(settlement: .settled, outcome: .credentialAbsent)
        )))
        await service.releaseDisconnect()
        let response = await operation.value
        XCTAssertEqual(response.receipt?.completion, .signOutCompleted)
    }

    func testManagedSignOutSaveFailureClearsCredentialFenceWithoutReceipt() async throws {
        let definition = ExternalMCPIntegrationDefinition.figma()
        let fileStore = FailingGlobalSettingsFileStore(document: GlobalSettingsDocument(externalMCPConnections: [definition]))
        let store = try makeStore(fileStore: fileStore)
        fileStore.failNextSave = true
        let service = CoordinatorFakeService()
        await service.setDisconnectResult(.init(result: .disconnected, effects: .init(
            configuration: .verifiedAbsent,
            appServer: .init(reload: .settled, oauthListener: .notRequested),
            credentialLogout: .init(settlement: .settled, outcome: .credentialAbsent)
        )))
        let authority = FigmaMCPRuntimeAvailabilityAuthority()
        authority.publish(snapshot: CoordinatorFakeService.connectedSnapshot, definition: definition)
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: authority)

        let response = await coordinator.performSettingsAction(.signOut, requestID: UUID(), ownerID: UUID(), windowID: 1)

        XCTAssertTrue(response.result.isError)
        XCTAssertNil(response.receipt?.completion)
        XCTAssertTrue(response.result.notice?.contains("credentials were removed") == true)
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), definition)
        XCTAssertFalse(coordinator.credentialRevocationRequired)
        XCTAssertFalse(authority.hasAuthenticatedRuntime)
        let recoveryLease = coordinator.beginInteractive(
            ownerID: UUID(),
            windowID: 2,
            kind: .reauthenticate,
            expectedDefinition: definition
        )
        XCTAssertNotNil(recoveryLease)
        if let recoveryLease {
            coordinator.finish(recoveryLease, connection: .notConfigured)
        }
    }

    func testAdoptedSignOutRemovalFailureIsFailClosedWithoutManagedMutation() async throws {
        let definition = ExternalMCPIntegrationDefinition.adoptedFigmaImport()
        let fileStore = FailingGlobalSettingsFileStore(document: GlobalSettingsDocument(externalMCPConnections: [definition]))
        let store = try makeStore(fileStore: fileStore)
        fileStore.failNextSave = true
        let service = CoordinatorFakeService()
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(.signOut, requestID: UUID(), ownerID: UUID(), windowID: 1)

        XCTAssertTrue(response.result.isError)
        XCTAssertFalse(response.result.notice?.contains("Retry Sign Out") == true)
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), definition)
        XCTAssertFalse(coordinator.credentialRevocationRequired)
        let reconnectLease = coordinator.beginInteractive(ownerID: UUID(), windowID: 2, kind: .settingsRefresh, expectedDefinition: definition)
        XCTAssertNotNil(reconnectLease)
        if let reconnectLease { coordinator.finish(reconnectLease, connection: .notConfigured) }
        let disconnectedDefinition = await service.lastDisconnectedDefinition()
        XCTAssertNil(disconnectedDefinition)
        coordinator.applicationDidWake()
        let refreshCount = await service.refreshCount()
        XCTAssertEqual(refreshCount, 0)
    }

    func testAdoptedSignOutFinalizationFailureOffersOrdinaryReconnection() async throws {
        let definition = ExternalMCPIntegrationDefinition.adoptedFigmaImport()
        let store = try makeStore(definition: definition)
        let service = CoordinatorFakeService()
        await service.setDisconnectResult(.init(result: .failed, effects: .none))
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(.signOut, requestID: UUID(), ownerID: UUID(), windowID: 1)

        XCTAssertNil(response.receipt?.completion)
        XCTAssertNil(store.externalMCPIntegration(for: .figma))
        XCTAssertFalse(coordinator.credentialRevocationRequired)
        XCTAssertEqual(response.result.snapshot, .notConfigured)
    }

    func testManagedSignOutDoesNotMutateAdoptedReplacementAfterInvalidation() async throws {
        let original = ExternalMCPIntegrationDefinition.figma()
        let replacement = ExternalMCPIntegrationDefinition.adoptedFigmaImport()
        let store = try makeStore(definition: original)
        let service = CoordinatorFakeService()
        await service.setBlockInvalidation(true)
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let operation = Task {
            await coordinator.performSettingsAction(.signOut, requestID: UUID(), ownerID: UUID(), windowID: 1)
        }

        try await waitUntil { await service.invalidationStarted() }
        XCTAssertTrue(store.setExternalMCPIntegration(replacement))
        await service.setBlockInvalidation(false)
        await service.releaseInvalidation()

        let response = await operation.value
        XCTAssertEqual(response.result, .cancelled)
        XCTAssertNil(response.receipt)
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), replacement)
        let disconnectCount = await service.disconnectCount()
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertFalse(coordinator.credentialRevocationRequired)
    }

    func testAdoptedSignOutDoesNotMutateManagedReplacementAfterInvalidation() async throws {
        let original = ExternalMCPIntegrationDefinition.adoptedFigmaImport()
        let replacement = ExternalMCPIntegrationDefinition.figma()
        let store = try makeStore(definition: original)
        let service = CoordinatorFakeService()
        await service.setBlockInvalidation(true)
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let operation = Task {
            await coordinator.performSettingsAction(.signOut, requestID: UUID(), ownerID: UUID(), windowID: 1)
        }

        try await waitUntil { await service.invalidationStarted() }
        XCTAssertTrue(store.setExternalMCPIntegration(replacement))
        await service.setBlockInvalidation(false)
        await service.releaseInvalidation()

        let response = await operation.value
        XCTAssertEqual(response.result, .cancelled)
        XCTAssertNil(response.receipt)
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), replacement)
        let disconnectCount = await service.disconnectCount()
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertFalse(coordinator.credentialRevocationRequired)
    }

    func testManagedSignOutRemovalFailureClearsCredentialFenceWithoutReceipt() async throws {
        let definition = ExternalMCPIntegrationDefinition.figma()
        let fileStore = FailingGlobalSettingsFileStore(document: GlobalSettingsDocument(externalMCPConnections: [definition]))
        let store = try makeStore(fileStore: fileStore)
        fileStore.failOnSaveNumber = fileStore.saveCount + 1
        let service = CoordinatorFakeService()
        await service.setDisconnectResult(.init(result: .disconnected, effects: .init(
            configuration: .verifiedAbsent,
            appServer: .init(reload: .settled, oauthListener: .notRequested),
            credentialLogout: .init(settlement: .settled, outcome: .credentialAbsent)
        )))
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(.signOut, requestID: UUID(), ownerID: UUID(), windowID: 1)
        XCTAssertEqual(store.externalMCPIntegration(for: .figma), definition)

        XCTAssertTrue(response.result.isError)
        XCTAssertTrue(response.result.notice?.contains("credentials were removed") == true)
        XCTAssertNil(response.receipt?.completion)
        XCTAssertFalse(coordinator.credentialRevocationRequired)
        XCTAssertFalse(coordinator.runtimeAvailability.hasAuthenticatedRuntime)
        let recoveryLease = coordinator.beginInteractive(
            ownerID: UUID(),
            windowID: 2,
            kind: .reauthenticate,
            expectedDefinition: definition
        )
        XCTAssertNotNil(recoveryLease)
        if let recoveryLease {
            coordinator.finish(recoveryLease, connection: .notConfigured)
        }
    }

    func testReauthenticationConnectedRequiresAuthenticatedState() async throws {
        let store = try makeStore(definition: .figma())
        let service = CoordinatorFakeService()
        let unauthenticated = FigmaMCPIntegrationSnapshot(state: .connected, authentication: .notLoggedIn, tools: [FigmaMCPToolCatalogEntry(name: "unsafe")], lastSuccessfulCheck: Date(), failureMessage: nil)
        await service.setConnectResult(.init(result: .connected(unauthenticated), authorizationRequest: nil, effects: .none))
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())

        let response = await coordinator.performSettingsAction(.reauthenticate, requestID: UUID(), ownerID: UUID(), windowID: 1)

        XCTAssertTrue(response.result.isError)
        XCTAssertEqual(response.result.snapshot.state, .failed)
        XCTAssertNil(response.receipt?.completion)
        XCTAssertFalse(coordinator.runtimeAvailability.hasAuthenticatedRuntime)
    }

    func testCancelledFreshConnectCompensatesBeforeWaiterRelease() async throws {
        let service = CoordinatorFakeService()
        let effects = FigmaMCPServiceEffects(configuration: .verifiedPresent, appServer: .init(reload: .settled, oauthListener: .settled))
        await service.setConnectResult(.init(result: .authorizationRequired, authorizationRequest: nil, effects: effects))
        await service.setDisconnectResult(.init(result: .failed, effects: .init(configuration: .commitUncertain, appServer: .none)))
        await service.setBlockConnect(true)
        await service.setBlockDisconnect(true)
        let store = try makeStore()
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        let ownerID = UUID()
        let operation = Task { await coordinator.performSettingsAction(.connect, requestID: UUID(), ownerID: ownerID, windowID: 1) }
        try await waitUntil { await service.connectStarted() }
        let waiter = expectation(description: "waiter released after compensation")
        var waiterCalled = false
        coordinator.notifyWhenSettingsOperationAvailable(id: UUID()) {
            waiterCalled = true
            waiter.fulfill()
        }

        await service.setBlockInvalidation(true)
        coordinator.cancelSettingsOperation(ownerID: ownerID)
        try await waitUntil { await service.disconnectStarted() }
        XCTAssertFalse(waiterCalled)
        XCTAssertNil(coordinator.beginInteractive(ownerID: UUID(), windowID: 2, kind: .connect, expectedDefinition: nil))
        let disconnectedDefinition = await service.lastDisconnectedDefinition()
        XCTAssertEqual(disconnectedDefinition?.origin, .settingsManaged)
        await service.releaseDisconnect()
        try await waitUntil { await service.invalidationStarted() }
        XCTAssertFalse(waiterCalled)
        XCTAssertNil(coordinator.beginInteractive(ownerID: UUID(), windowID: 2, kind: .connect, expectedDefinition: nil))
        await service.releaseInvalidation()
        await fulfillment(of: [waiter], timeout: 1)
        XCTAssertTrue(waiterCalled)
        let invalidationCount = await service.invalidationCount()
        XCTAssertEqual(invalidationCount, 1)
        XCTAssertNil(store.externalMCPIntegration(for: .figma))
        await service.releaseConnect()
        let response = await operation.value
        XCTAssertNil(response.receipt)
    }

    func testSleepCancelsPassiveRefreshExactlyOnce() async throws {
        let service = CoordinatorFakeService()
        await service.setBlockRefresh(true)
        let store = try makeStore(definition: .figma())
        let coordinator = FigmaMCPIntegrationCoordinator(settingsStore: store, service: service, runtimeAvailability: FigmaMCPRuntimeAvailabilityAuthority())
        coordinator.requestPassiveRefresh()
        try await waitUntil { await service.refreshStarted() }
        coordinator.applicationWillSleep()
        try await waitUntil { await service.statusCancellationCount() == 1 }
        let statusCancellationCount = await service.statusCancellationCount()
        XCTAssertEqual(statusCancellationCount, 1)
        await service.releaseRefresh()
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let step: UInt64 = 10_000_000
        var waited: UInt64 = 0
        while waited < timeoutNanoseconds {
            if await condition() { break }
            try await Task.sleep(nanoseconds: step)
            waited += step
        }
        let completed = await condition()
        XCTAssertTrue(completed, "Condition did not become true before timeout")
    }

    private func makeStore(
        definition: ExternalMCPIntegrationDefinition? = nil,
        fileStore: GlobalSettingsFileStoring? = nil
    ) throws -> GlobalSettingsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FigmaMCPIntegrationCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "FigmaMCPIntegrationCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: fileStore ?? GlobalSettingsFileStore(fileURL: directory.appendingPathComponent("globalSettings.json"))
        )
        if let definition {
            XCTAssertTrue(store.setExternalMCPIntegration(definition))
        }
        return store
    }
}

private final class FailingGlobalSettingsFileStore: GlobalSettingsFileStoring {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("FigmaMCPFailing-\(UUID().uuidString).json")
    var document: GlobalSettingsDocument
    var saveCount = 0
    var failNextSave = false
    var failOnSaveNumber: Int?
    var blockReason: GlobalSettingsPersistenceBlockReason?
    var hasPendingStartupMigration: Bool {
        false
    }

    init(document: GlobalSettingsDocument) {
        self.document = document
    }

    func load() throws -> GlobalSettingsDocument {
        document
    }

    func loadOrCreateDefault() -> GlobalSettingsDocument {
        document
    }

    func save(_ document: GlobalSettingsDocument) throws {
        saveCount += 1
        if failNextSave || failOnSaveNumber == saveCount {
            failNextSave = false
            blockReason = .saveFailed
            throw NSError(domain: "FigmaMCPIntegrationCoordinatorTests", code: 1)
        }
        self.document = document
    }

    func saveStartupMigrationPreservingUnknownFields(_ document: GlobalSettingsDocument, includeModelSelectionRepair _: Bool) throws {
        try save(document)
    }

    func retryStartupMigrationPreservingUnknownFields(_ document: GlobalSettingsDocument) throws {
        try save(document)
    }

    func performUserInitiatedRecovery(replacementDocument _: GlobalSettingsDocument) -> Bool {
        false
    }

    func performUserInitiatedCompatibleImport() -> Bool {
        false
    }
}

private actor CoordinatorFakeService: FigmaMCPIntegrationManaging {
    static let connectedSnapshot = FigmaMCPIntegrationSnapshot(state: .connected, authentication: .authenticated, tools: [], lastSuccessfulCheck: Date(timeIntervalSince1970: 1), failureMessage: nil)
    private var refreshes = 0
    private var connectResult = FigmaMCPConnectServiceResult(result: .failed, authorizationRequest: nil, effects: .none)
    private var disconnectResult = FigmaMCPDisconnectServiceResult(result: .disconnected, effects: .none)
    private var disconnectedDefinition: ExternalMCPIntegrationDefinition?
    private var disconnects = 0
    private var blockDisconnect = false
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private var hasStartedDisconnect = false
    private var blockConnect = false
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var hasStartedConnect = false
    private var blockRefresh = false
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var hasStartedRefresh = false
    private var statusCancellations = 0
    private var invalidations = 0
    private var blockInvalidation = false
    private var invalidationContinuation: CheckedContinuation<Void, Never>?
    private var authorizationSettlements: [FigmaMCPAuthorizationHandoffDisposition] = []
    private var hasStartedInvalidation = false

    func refreshCount() -> Int {
        refreshes
    }

    func snapshot() -> FigmaMCPIntegrationSnapshot {
        .notConfigured
    }

    func discoverExistingImport() async -> FigmaMCPImportDiscovery {
        .absent
    }

    func connect(definition _: ExternalMCPIntegrationDefinition) async -> (FigmaMCPConnectResult, FigmaMCPAuthorizationRequest?) {
        (.failed, nil)
    }

    func disconnect(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPDisconnectResult {
        let response = await disconnectWithEffects(definition: definition)
        return response.result
    }

    func connectWithEffects(definition _: ExternalMCPIntegrationDefinition) async -> FigmaMCPConnectServiceResult {
        hasStartedConnect = true
        if blockConnect {
            await withCheckedContinuation { continuation in
                connectContinuation = continuation
            }
        }
        return connectResult
    }

    func disconnectWithEffects(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPDisconnectServiceResult {
        disconnectedDefinition = definition
        disconnects += 1
        hasStartedDisconnect = true
        if blockDisconnect {
            await withCheckedContinuation { continuation in
                disconnectContinuation = continuation
            }
        }
        return disconnectResult
    }

    func removeManagedConfiguration(definition: ExternalMCPIntegrationDefinition) async -> FigmaMCPDisconnectServiceResult {
        await disconnectWithEffects(definition: definition)
    }

    func setBlockDisconnect(_ value: Bool) {
        blockDisconnect = value
    }

    func setBlockConnect(_ value: Bool) {
        blockConnect = value
    }

    func connectStarted() -> Bool {
        hasStartedConnect
    }

    func releaseConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func disconnectStarted() -> Bool {
        hasStartedDisconnect
    }

    func releaseDisconnect() {
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }

    func setConnectResult(_ result: FigmaMCPConnectServiceResult) {
        connectResult = result
    }

    func setDisconnectResult(_ result: FigmaMCPDisconnectServiceResult) {
        disconnectResult = result
    }

    func lastDisconnectedDefinition() -> ExternalMCPIntegrationDefinition? {
        disconnectedDefinition
    }

    func disconnectCount() -> Int {
        disconnects
    }

    func setBlockRefresh(_ value: Bool) {
        blockRefresh = value
    }

    func refreshStarted() -> Bool {
        hasStartedRefresh
    }

    func releaseRefresh() {
        refreshContinuation?.resume()
        refreshContinuation = nil
    }

    func statusCancellationCount() -> Int {
        statusCancellations
    }

    func invalidationCount() -> Int {
        invalidations
    }

    func setBlockInvalidation(_ value: Bool) {
        blockInvalidation = value
    }

    func invalidationStarted() -> Bool {
        hasStartedInvalidation
    }

    func releaseInvalidation() {
        invalidationContinuation?.resume()
        invalidationContinuation = nil
    }

    func settleAuthorizationHandoff(id _: UUID, disposition: FigmaMCPAuthorizationHandoffDisposition) {
        authorizationSettlements.append(disposition)
    }

    func authorizationHandoffDispositions() -> [FigmaMCPAuthorizationHandoffDisposition] {
        authorizationSettlements
    }

    func invalidatePresentationSnapshot() async {
        invalidations += 1
        hasStartedInvalidation = true
        if blockInvalidation {
            await withCheckedContinuation { continuation in
                invalidationContinuation = continuation
            }
        }
    }

    func cancelCurrentOperation() {}

    func cancelStatusRefresh() {
        statusCancellations += 1
    }

    func refresh(definition _: ExternalMCPIntegrationDefinition?) async -> FigmaMCPIntegrationSnapshot {
        refreshes += 1
        hasStartedRefresh = true
        if blockRefresh {
            await withCheckedContinuation { continuation in
                refreshContinuation = continuation
            }
        }
        return Self.connectedSnapshot
    }
}
