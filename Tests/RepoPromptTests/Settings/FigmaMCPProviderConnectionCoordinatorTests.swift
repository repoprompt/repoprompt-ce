import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class FigmaMCPProviderConnectionCoordinatorTests: XCTestCase {
    func testDuplicateLoginRequestsCoalescePerProvider() async throws {
        let driver = TestLoginDriver(provider: .claudeCode, waitsForCompletion: true)
        let coordinator = try makeCoordinator(registrations: [registration(provider: .claudeCode, driver: driver)])

        let first = await coordinator.beginLogin(provider: .claudeCode, ownerID: "window-a")
        let second = await coordinator.beginLogin(provider: .claudeCode, ownerID: "window-b")

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        await waitUntil { await driver.beginCount == 1 }
        let beginCount = await driver.beginCount
        let initialCancelCount = await driver.cancelCount
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(initialCancelCount, 0)

        let resolvedAttempt = await waitForAttempt(coordinator, provider: .claudeCode)
        let attempt = try XCTUnwrap(resolvedAttempt)
        let recordedContexts = await driver.attemptContexts
        let context = try XCTUnwrap(recordedContexts.first)
        XCTAssertEqual(context.provider, attempt.provider)
        XCTAssertEqual(context.target, attempt.target)
        XCTAssertEqual(context.providerTargetIdentifier, attempt.providerTargetIdentifier)
        XCTAssertEqual(context.credentialContext, attempt.credentialContext)
        XCTAssertEqual(context.attemptID, attempt.attemptID)
        XCTAssertEqual(context.evidenceID, attempt.evidenceID)
        XCTAssertEqual(context.capabilityRevision, attempt.capabilityRevision)
        XCTAssertEqual(context.executableIdentity, attempt.executableIdentity)
        XCTAssertEqual(context.executableVersion, attempt.executableVersion)
        XCTAssertEqual(context.operationGeneration, attempt.operationGeneration)

        await coordinator.cancelLogin(provider: .claudeCode, attemptID: UUID())
        let mismatchedCancelCount = await driver.cancelCount
        XCTAssertEqual(mismatchedCancelCount, 0)

        try await coordinator.cancelLogin(provider: .claudeCode, attemptID: XCTUnwrap(first))
        let cancelCount = await driver.cancelCount
        let cancellationAttemptIDs = await driver.cancellationAttemptIDs
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(cancellationAttemptIDs, [attempt.attemptID])
        assertNotVerified(coordinator.state(for: .claudeCode), notice: .cancelledAuthenticationStateUnknown)
    }

    func testDifferentProvidersCanAuthorizeConcurrentlyAndRemainIndependent() async throws {
        let claude = TestLoginDriver(provider: .claudeCode, waitsForCompletion: true)
        let openCode = TestLoginDriver(provider: .openCode, waitsForCompletion: true)
        let coordinator = try makeCoordinator(registrations: [
            registration(provider: .claudeCode, driver: claude),
            registration(provider: .openCode, driver: openCode)
        ])

        let claudeAttempt = await coordinator.beginLogin(provider: .claudeCode)
        let openCodeAttempt = await coordinator.beginLogin(provider: .openCode)

        XCTAssertNotNil(claudeAttempt)
        XCTAssertNotNil(openCodeAttempt)
        XCTAssertNotEqual(claudeAttempt, openCodeAttempt)
        await waitUntil {
            let claudeBeginCount = await claude.beginCount
            let openCodeBeginCount = await openCode.beginCount
            return claudeBeginCount == 1 && openCodeBeginCount == 1
        }
        let claudeBeginCount = await claude.beginCount
        let openCodeBeginCount = await openCode.beginCount
        XCTAssertEqual(claudeBeginCount, 1)
        XCTAssertEqual(openCodeBeginCount, 1)
        XCTAssertTrue(coordinator.isAuthorizing(.claudeCode))
        XCTAssertTrue(coordinator.isAuthorizing(.openCode))

        try await coordinator.cancelLogin(provider: .claudeCode, attemptID: XCTUnwrap(claudeAttempt))
        XCTAssertTrue(coordinator.isAuthorizing(.openCode))
        try await coordinator.cancelLogin(provider: .openCode, attemptID: XCTUnwrap(openCodeAttempt))
    }

    func testReservationAllowsCancellationBeforeBeginAndUsesTheReservedAttemptID() async throws {
        let resolver = TestHangingTargetResolver(runtimeProvider: .openCode)
        let driver = TestLoginDriver(provider: .openCode, waitsForCompletion: true)
        let coordinator = try makeCoordinator(
            registrations: [registration(provider: .openCode, driver: driver, resolver: resolver)]
        )

        let beginTask = Task { await coordinator.beginLogin(provider: .openCode) }
        await waitUntil { await driver.reservedAttemptID != nil }
        let reservedAttemptID = await driver.reservedAttemptID
        let attemptID = try XCTUnwrap(reservedAttemptID)

        await coordinator.cancelLogin(provider: .openCode, attemptID: attemptID)
        await resolver.release()
        let beginResult = await beginTask.value
        XCTAssertNil(beginResult)
        await waitUntil { await driver.cancellationAttemptIDs.count == 1 }

        let beginCount = await driver.beginCount
        let cancellationAttemptIDs = await driver.cancellationAttemptIDs
        XCTAssertEqual(beginCount, 0)
        XCTAssertEqual(cancellationAttemptIDs, [attemptID])
    }

    func testCodexIsNeverHandledByProviderLoginCoordinator() async throws {
        let driver = TestLoginDriver(provider: .codex, waitsForCompletion: true)
        let coordinator = try makeCoordinator(registrations: [registration(provider: .codex, driver: driver)])

        let attempt = await coordinator.beginLogin(provider: .codex)

        let beginCount = await driver.beginCount
        let cancelCount = await driver.cancelCount
        XCTAssertNil(attempt)
        XCTAssertNil(coordinator.state(for: .codex))
        XCTAssertEqual(beginCount, 0)
        XCTAssertEqual(cancelCount, 0)
    }

    func testSuccessfulProcessSettlementRemainsNotVerified() async throws {
        let driver = TestLoginDriver(provider: .openCode, result: .exited(status: 0))
        let coordinator = try makeCoordinator(registrations: [registration(provider: .openCode, driver: driver)])

        let attempt = await coordinator.beginLogin(provider: .openCode)
        XCTAssertNotNil(attempt)
        await waitUntil { !coordinator.isAuthorizing(.openCode) }

        assertNotVerified(coordinator.state(for: .openCode), notice: .processCompletedWithoutProof)
    }

    func testDevinLoginOnlyFakeCannotTurnProcessSettlementIntoProofOrSignOut() async throws {
        let driver = TestLoginDriver(provider: .devin, result: .exited(status: 0))
        let coordinator = try makeCoordinator(registrations: [registration(provider: .devin, driver: driver)])
        let attempt = await coordinator.beginLogin(provider: .devin)
        XCTAssertNotNil(attempt)
        await waitUntil { !coordinator.isAuthorizing(.devin) }
        assertNotVerified(coordinator.state(for: .devin), notice: .processCompletedWithoutProof)
        XCTAssertFalse(coordinator.canSignOut(provider: .devin))
        XCTAssertFalse(coordinator.signOut(provider: .devin))
    }

    func testNonzeroProcessSettlementNeverRunsStructuredProof() async throws {
        let driver = TestLoginDriver(provider: .openCode, result: .exited(status: 7))
        let checker = TestStructuredStatusCounter()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "nonzero-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: driver,
            structuredStatusChecker: { target, _, _, generation in
                await checker.increment()
                return .verified(.init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        _ = await coordinator.beginLogin(provider: .openCode)
        await waitUntil { coordinator.state(for: .openCode) == .notVerified(
            loginAvailability: .available,
            notice: .providerProcessFailed
        ) }

        let checkerValue = await checker.value
        XCTAssertEqual(checkerValue, 0)
        assertNotVerified(coordinator.state(for: .openCode), notice: .providerProcessFailed)
    }

    func testClaudeAuthorizationSessionCloseSettlesImmediatelyWithoutStatusCheck() async throws {
        let provider = ExternalMCPRuntimeProvider.claudeCode
        let driver = TestLoginDriver(provider: provider, result: .authorizationSessionClosed)
        let checker = TestStructuredStatusCounter()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: provider,
            evidenceID: "claude-terminal-close",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: provider,
            adapter: TestFailClosedAdapter(runtimeProvider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: provider),
            loginDriver: driver,
            structuredStatusChecker: { _, _, _, _ in
                await checker.increment()
                return .unknown
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        _ = await coordinator.beginLogin(provider: provider)
        await waitUntil {
            coordinator.state(for: provider) == .notVerified(
                loginAvailability: .available,
                notice: .authorizationSessionClosed
            )
        }

        let checkerValue = await checker.value
        XCTAssertEqual(checkerValue, 0)
        assertNotVerified(coordinator.state(for: provider), notice: .authorizationSessionClosed)
    }

    func testClaudeNonzeroProviderOwnedLoginExitRemainsNeutralWithoutProof() async throws {
        let driver = TestLoginDriver(provider: .claudeCode, result: .exited(status: 1))
        let coordinator = try makeCoordinator(registrations: [registration(provider: .claudeCode, driver: driver)])

        _ = await coordinator.beginLogin(provider: .claudeCode)
        await waitUntil {
            coordinator.state(for: .claudeCode) == .notVerified(
                loginAvailability: .available,
                notice: .processCompletedWithoutProof
            )
        }

        assertNotVerified(coordinator.state(for: .claudeCode), notice: .processCompletedWithoutProof)
    }

    func testClaudeNonzeroProcessSettlementCanPublishOnlyStructuredProof() async throws {
        let driver = TestLoginDriver(provider: .claudeCode, result: .exited(status: 1))
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .claudeCode,
            evidenceID: "claude-nonzero-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .claudeCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .claudeCode),
            figmaCapabilities: .init(
                provider: .claudeCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .claudeCode),
            loginDriver: driver,
            structuredStatusChecker: { target, _, _, generation in
                .verified(.init(
                    runtimeProvider: .claudeCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        _ = await coordinator.beginLogin(provider: .claudeCode)
        await waitUntil { coordinator.state(for: .claudeCode).isConnected }

        guard case let .connected(proof) = coordinator.state(for: .claudeCode) else {
            return XCTFail("Expected the exact structured Claude proof to publish Connected")
        }
        XCTAssertEqual(proof.evidenceID, evidence.evidenceID)
    }

    func testVerifiedProviderOwnedLogoutRechecksStatusBeforePublishingNeedsLogin() async throws {
        let provider = ExternalMCPRuntimeProvider.claudeCode
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: provider,
            evidenceID: "claude-status-proof",
            capabilityRevision: "revision-1"
        )
        let logoutEvidence = FigmaMCPProviderCapabilityEvidence(
            provider: provider,
            evidenceID: "claude-logout-proof",
            capabilityRevision: "revision-1"
        )
        let logoutState = TestProviderOwnedLogoutState()
        let registration = ExternalMCPProviderRegistration(
            provider: provider,
            adapter: TestProviderOwnedLogoutAdapter(runtimeProvider: provider, state: logoutState),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .verified(logoutEvidence),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: provider),
            loginDriver: TestLoginDriver(provider: provider),
            structuredStatusChecker: { target, _, _, generation in
                if await logoutState.didLogout {
                    return .unauthenticated
                }
                return .verified(.init(
                    runtimeProvider: provider,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])
        coordinator.activate(observerID: "window")
        await waitUntil { coordinator.state(for: provider).isConnected }

        XCTAssertTrue(coordinator.signOut(provider: provider))
        await waitUntil { coordinator.state(for: provider) == .needsLogin }

        let logoutCallCount = await logoutState.callCount
        XCTAssertEqual(logoutCallCount, 1)
        XCTAssertEqual(coordinator.state(for: provider), .needsLogin)
    }

    func testInconclusiveStatusAfterProviderLogoutRemainsRetryable() async throws {
        let provider = ExternalMCPRuntimeProvider.claudeCode
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: provider,
            evidenceID: "claude-status-proof",
            capabilityRevision: "revision-1"
        )
        let logoutState = TestProviderOwnedLogoutState()
        let registration = ExternalMCPProviderRegistration(
            provider: provider,
            adapter: TestProviderOwnedLogoutAdapter(runtimeProvider: provider, state: logoutState),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .verified(.init(
                    provider: provider,
                    evidenceID: "claude-logout-proof",
                    capabilityRevision: "revision-1"
                )),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: provider),
            loginDriver: TestLoginDriver(provider: provider),
            structuredStatusChecker: { target, _, _, generation in
                if await logoutState.didLogout { return .unknown }
                return .verified(.init(
                    runtimeProvider: provider,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])
        coordinator.activate(observerID: "window")
        await waitUntil { coordinator.state(for: provider).isConnected }

        XCTAssertTrue(coordinator.signOut(provider: provider))
        await waitUntil {
            coordinator.state(for: provider) == .notVerified(
                loginAvailability: .available,
                notice: .credentialLogoutUnverified
            )
        }

        XCTAssertTrue(coordinator.canSignOut(provider: provider))
    }

    func testLaunchFailurePublishesUnavailableState() async throws {
        let driver = TestLoginDriver(provider: .openCode, result: .launchFailed)
        let coordinator = try makeCoordinator(registrations: [registration(provider: .openCode, driver: driver)])

        _ = await coordinator.beginLogin(provider: .openCode)
        await waitUntil {
            coordinator.state(for: .openCode) == .unavailable("The provider Figma login could not be launched.")
        }

        XCTAssertEqual(
            coordinator.state(for: .openCode),
            .unavailable("The provider Figma login could not be launched.")
        )
    }

    func testStructuredRecheckUsesSharedCheckerAndMapsExpiredStatusToNeedsLogin() async throws {
        let checker = TestStructuredStatusCounter()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "recheck-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: TestLoginDriver(provider: .openCode),
            structuredStatusChecker: { target, _, _, generation in
                let checkNumber = await checker.incrementAndReturn()
                guard checkNumber > 1 else {
                    return .verified(.init(
                        runtimeProvider: .openCode,
                        canonicalTarget: target,
                        providerTargetIdentifier: "figma-server",
                        credentialContext: .providerDefaultUserProfile,
                        sanitizedSnapshot: .init(
                            integrationID: target.integrationID,
                            connection: .connected,
                            authentication: .providerOwned
                        ),
                        evidenceID: evidence.evidenceID,
                        capabilityRevision: evidence.capabilityRevision,
                        operationGeneration: generation
                    ))
                }
                return .expired
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        coordinator.activate(observerID: "window")
        await waitUntil { coordinator.state(for: .openCode).isConnected }
        XCTAssertTrue(coordinator.recheckStatus(provider: .openCode))
        await waitUntil { coordinator.state(for: .openCode) == .needsLogin }

        let checkerValue = await checker.value
        XCTAssertEqual(checkerValue, 2)
        coordinator.deactivate(observerID: "window")
    }

    func testStructuredRecheckObservesExternalAuthenticationFromNeedsLogin() async throws {
        let checker = TestStructuredStatusCounter()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .claudeCode,
            evidenceID: "external-auth-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .claudeCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .claudeCode),
            figmaCapabilities: .init(
                provider: .claudeCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .claudeCode),
            loginDriver: TestLoginDriver(provider: .claudeCode),
            structuredStatusChecker: { target, _, _, generation in
                let checkNumber = await checker.incrementAndReturn()
                guard checkNumber > 1 else { return .unauthenticated }
                return .verified(.init(
                    runtimeProvider: .claudeCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        coordinator.activate(observerID: "window")
        await waitUntil { coordinator.state(for: .claudeCode) == .needsLogin }
        XCTAssertTrue(coordinator.recheckStatus(provider: .claudeCode))
        await waitUntil { coordinator.state(for: .claudeCode).isConnected }

        let checkerValue = await checker.value
        XCTAssertEqual(checkerValue, 2)
        coordinator.deactivate(observerID: "window")
    }

    func testReturnDuringActiveStatusCheckCoalescesOneFollowUpRecheck() async throws {
        let checker = TestStructuredStatusCounter()
        let secondCheckGate = TestSleepGate()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .claudeCode,
            evidenceID: "coalesced-return-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .claudeCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .claudeCode),
            figmaCapabilities: .init(
                provider: .claudeCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .claudeCode),
            loginDriver: TestLoginDriver(provider: .claudeCode),
            structuredStatusChecker: { target, _, _, generation in
                let checkNumber = await checker.incrementAndReturn()
                if checkNumber == 1 { return .unauthenticated }
                if checkNumber == 2 {
                    await secondCheckGate.sleep()
                    return .unauthenticated
                }
                return .verified(.init(
                    runtimeProvider: .claudeCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        coordinator.activate(observerID: "window")
        await waitUntil { coordinator.state(for: .claudeCode) == .needsLogin }
        XCTAssertTrue(coordinator.recheckStatus(provider: .claudeCode))
        await waitUntil { await checker.value == 2 }
        XCTAssertTrue(coordinator.recheckStatus(provider: .claudeCode))

        await secondCheckGate.fire()
        await waitUntil { coordinator.state(for: .claudeCode).isConnected }

        let checkerValue = await checker.value
        XCTAssertEqual(checkerValue, 3)
        coordinator.deactivate(observerID: "window")
    }

    func testConnectedProofExpiryClearsWhileNoSettingsObserverIsActive() async throws {
        let expiryGate = TestSleepGate()
        let checker = TestStructuredStatusCounter()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "expiry-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noStructuredProofContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: TestLoginDriver(provider: .openCode),
            structuredStatusChecker: { target, _, _, generation in
                let checkNumber = await checker.incrementAndReturn()
                guard checkNumber == 1 else { return .unknown }
                return .verified(.init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(
            registrations: [registration],
            timing: .init(sleep: { _ in await expiryGate.sleep() }, terminationDrainTimeoutNanoseconds: 1)
        )

        coordinator.activate(observerID: "window")
        await waitUntil { coordinator.state(for: .openCode).isConnected }
        await waitUntil { await expiryGate.isWaiting() }
        coordinator.deactivate(observerID: "window")
        await expiryGate.fire()
        await waitUntil { coordinator.state(for: .openCode) == .notVerified(loginAvailability: .available, notice: nil) }

        let checkerValue = await checker.value
        XCTAssertEqual(checkerValue, 1)
        XCTAssertEqual(
            coordinator.state(for: .openCode),
            .notVerified(loginAvailability: .available, notice: nil)
        )
    }

    func testConnectedProofExpiryRenewsProofWhenStructuredRecheckStillReportsConnected() async throws {
        let firstExpiryGate = TestSleepGate()
        let renewedExpiryGate = TestSleepGate()
        let sleepCounter = TestStructuredStatusCounter()
        let checker = TestStructuredStatusCounter()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .claudeCode,
            evidenceID: "renewed-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .claudeCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .claudeCode),
            figmaCapabilities: .init(
                provider: .claudeCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .claudeCode),
            loginDriver: TestLoginDriver(provider: .claudeCode),
            structuredStatusChecker: { target, _, _, generation in
                _ = await checker.incrementAndReturn()
                return .verified(.init(
                    runtimeProvider: .claudeCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(
            registrations: [registration],
            timing: .init(
                sleep: { _ in
                    let sleepNumber = await sleepCounter.incrementAndReturn()
                    if sleepNumber == 1 {
                        await firstExpiryGate.sleep()
                    } else {
                        await renewedExpiryGate.sleep()
                    }
                },
                terminationDrainTimeoutNanoseconds: 1
            )
        )

        coordinator.activate(observerID: "window")
        await waitUntil { coordinator.state(for: .claudeCode).isConnected }
        await waitUntil { await firstExpiryGate.isWaiting() }
        await firstExpiryGate.fire()
        await waitUntil { await checker.value == 2 && coordinator.state(for: .claudeCode).isConnected }
        await waitUntil { await sleepCounter.value >= 2 }

        XCTAssertTrue(coordinator.state(for: .claudeCode).isConnected)
        coordinator.deactivate(observerID: "window")
        await renewedExpiryGate.fire()
    }

    func testConnectedProofWithDistantFutureExpiryUsesClampedSleepSchedule() async throws {
        let proofExpiryGate = TestSleepGate()
        let sleepProbe = TestSleepProbe()
        let checker = TestStructuredStatusCounter()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "distant-expiry-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noStructuredProofContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: TestLoginDriver(provider: .openCode),
            structuredStatusChecker: { target, _, _, generation in
                let checkNumber = await checker.incrementAndReturn()
                guard checkNumber == 1 else { return .unknown }
                return .verified(.init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    validUntil: Date.distantFuture,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(
            registrations: [registration],
            timing: .init(
                sleep: { nanoseconds in
                    await sleepProbe.record(nanoseconds)
                    await proofExpiryGate.sleep()
                },
                terminationDrainTimeoutNanoseconds: 1
            )
        )

        coordinator.activate(observerID: "window")
        await waitUntil { await sleepProbe.valueCount() > 0 }
        let lastSleep = await sleepProbe.lastValue()
        XCTAssertEqual(lastSleep, UInt64.max)
        await waitUntil { coordinator.state(for: .openCode).isConnected }

        await proofExpiryGate.fire()
        await waitUntil { coordinator.state(for: .openCode) == .notVerified(loginAvailability: .available, notice: nil) }
        let checkerValue = await checker.value
        XCTAssertEqual(checkerValue, 2)
        coordinator.deactivate(observerID: "window")
    }

    func testStructuredStatusCancellationTokenIsCancelledOnObserverDeactivation() async throws {
        let structuredGate = TestSleepGate()
        let tokenProbe = TestStructuredStatusTokenProbe()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "deactivation-token-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noStructuredProofContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: TestLoginDriver(provider: .openCode),
            structuredStatusChecker: { target, _, context, generation in
                await tokenProbe.capture(context.cancellationToken)
                await structuredGate.sleep()
                return .verified(.init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        coordinator.activate(observerID: "window")
        await waitUntil { await tokenProbe.isCaptured() }
        coordinator.deactivate(observerID: "window")
        await tokenProbe.waitUntilCancelled()

        await structuredGate.fire()
        XCTAssertFalse(coordinator.state(for: .openCode).isConnected)
    }

    func testStructuredCheckerResultIsRejectedWhenCoordinatorRevisionChanges() async throws {
        let structuredGate = TestSleepGate()
        let checker = TestStructuredStatusCounter()
        let neutralCoordinator = ExternalMCPIntegrationCoordinator()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "revision-race-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: TestLoginDriver(provider: .openCode),
            structuredStatusChecker: { target, _, _, generation in
                await checker.increment()
                await structuredGate.sleep()
                return .verified(.init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(
            registrations: [registration],
            statusCoordinator: neutralCoordinator
        )

        coordinator.activate(observerID: "window")
        await waitUntil { await checker.value == 1 }
        let capturedRevision = await neutralCoordinator.currentRevision()
        _ = neutralCoordinator.invalidateRevision()
        await structuredGate.fire()
        await waitUntil {
            coordinator.state(for: .openCode) == .notVerified(loginAvailability: .available, notice: nil)
        }

        XCTAssertFalse(coordinator.state(for: .openCode).isConnected)
        let currentRevision = await neutralCoordinator.currentRevision()
        XCTAssertGreaterThan(currentRevision, capturedRevision)
        coordinator.deactivate(observerID: "window")
    }

    func testRegistrationReplacementCannotTerminateNewerLoginAttempt() async throws {
        let structuredGate = TestSleepGate()
        let tokenProbe = TestStructuredStatusTokenProbe()
        let oldDriver = TestLoginDriver(provider: .openCode)
        let newDriver = TestLateSettlementDriver(provider: .openCode)
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "replacement-race-proof",
            capabilityRevision: "revision-1"
        )
        let initial = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: oldDriver,
            structuredStatusChecker: { target, _, context, generation in
                await tokenProbe.capture(context.cancellationToken)
                await structuredGate.sleep()
                return .verified(.init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let replacement = registration(
            provider: .openCode,
            driver: newDriver,
            proofSupportVerified: true,
            evidenceRevision: "revision-2"
        )
        let coordinator = try makeCoordinator(registrations: [initial])
        coordinator.activate(observerID: "window")
        await waitUntil { await tokenProbe.isCaptured() }

        try coordinator.registry.replace(replacement)
        let newerAttempt = await coordinator.beginLogin(provider: .openCode)

        XCTAssertNotNil(newerAttempt)
        XCTAssertTrue(coordinator.isAuthorizing(.openCode))
        let newDriverCancelCount = await newDriver.cancelCount
        XCTAssertEqual(newDriverCancelCount, 0)

        await tokenProbe.waitUntilCancelled()
        await structuredGate.fire()
        try await coordinator.cancelLogin(provider: .openCode, attemptID: XCTUnwrap(newerAttempt))
        coordinator.deactivate(observerID: "window")
    }

    func testStructuredStatusCancellationTokenIsCancelledOnProviderReplacement() async throws {
        let structuredGate = TestSleepGate()
        let tokenProbe = TestStructuredStatusTokenProbe()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "replacement-token-proof",
            capabilityRevision: "revision-1"
        )
        let driver = TestLoginDriver(provider: .openCode)
        let initial = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: driver,
            structuredStatusChecker: { target, _, context, generation in
                await tokenProbe.capture(context.cancellationToken)
                await structuredGate.sleep()
                return .verified(.init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let box = TestRegistrationBox()
        let replacement = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: initial.figmaCapabilities,
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: driver,
            structuredStatusChecker: { _, _, _, _ in
                .unknown
            }
        )
        box.registration = initial

        let coordinator = try makeCoordinator(
            registrations: [initial],
            registrationLookup: { _ in box.registration }
        )
        coordinator.activate(observerID: "window")

        await waitUntil { await tokenProbe.isCaptured() }
        box.registration = replacement

        _ = await coordinator.beginLogin(provider: .openCode)

        await tokenProbe.waitUntilCancelled()
        await structuredGate.fire()
        coordinator.deactivate(observerID: "window")
        XCTAssertFalse(coordinator.state(for: .openCode).isConnected)
    }

    func testStructuredStatusCancellationTokenIsCancelledOnApplicationTermination() async throws {
        let structuredGate = TestSleepGate()
        let tokenProbe = TestStructuredStatusTokenProbe()
        let observer = TestTerminationObserver()
        let driver = TestLateSettlementDriver(provider: .openCode)
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "termination-token-proof",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: driver,
            structuredStatusChecker: { target, _, context, generation in
                await tokenProbe.capture(context.cancellationToken)
                await structuredGate.sleep()
                return .verified(.init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(
            registrations: [registration],
            terminationObserver: observer
        )

        _ = await coordinator.beginLogin(provider: .openCode)
        await waitUntil { await driver.beginCount == 1 }
        await driver.finish(.exited(status: 0))
        await waitUntil { await tokenProbe.isCaptured() }
        observer.trigger()

        await tokenProbe.waitUntilCancelled()
        await structuredGate.fire()
        await coordinator.awaitApplicationTermination()
        XCTAssertFalse(coordinator.state(for: .openCode).isConnected)
    }

    func testRegistrationReplacementImmediatelyInvalidatesProviderProof() async throws {
        let driver = TestLoginDriver(provider: .openCode)
        let original = registration(provider: .openCode, driver: driver, proofSupportVerified: true)
        let coordinator = try makeCoordinator(registrations: [original])
        let proof = FigmaMCPVerifiedProviderStatus(
            runtimeProvider: .openCode,
            canonicalTarget: .figma,
            providerTargetIdentifier: "figma-server",
            credentialContext: .providerDefaultUserProfile,
            sanitizedSnapshot: .init(
                integrationID: ExternalMCPIntegrationTarget.figma.integrationID,
                connection: .connected,
                authentication: .providerOwned
            ),
            evidenceID: "evidence-openCode",
            capabilityRevision: "revision-1",
            operationGeneration: 0
        )
        XCTAssertTrue(coordinator.applyVerifiedStatus(
            proof,
            provider: .openCode,
            targetResolution: .resolved(
                providerTargetIdentifier: "figma-server",
                source: .reviewedFixedIdentifier,
                credentialContext: .providerDefaultUserProfile
            ),
            operationGeneration: 0
        ))

        let replacement = registration(
            provider: .openCode,
            driver: TestLoginDriver(provider: .openCode),
            proofSupportVerified: true,
            evidenceRevision: "revision-2"
        )
        try coordinator.registry.replace(replacement)
        await waitUntil { !coordinator.state(for: .openCode).isConnected }
        XCTAssertFalse(coordinator.state(for: .openCode).isConnected)
    }

    func testNonCodexCodexManagedCapabilityIsRejected() throws {
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "evidence-openCode",
            capabilityRevision: "revision-1"
        )
        let invalid = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .unverified(.liveGatePending),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .codexManaged
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            structuredProofChecker: { _, _, _, _ in nil }
        )
        XCTAssertThrowsError(try ExternalMCPAdapterRegistry(registrations: [invalid])) { error in
            XCTAssertEqual(error as? ExternalMCPAdapterRegistry.RegistrationError, .nonCodexCodexManagedCapability(.openCode))
        }
    }

    func testSnapshotFromAnotherIntegrationCannotBecomeProviderProof() throws {
        let coordinator = try makeCoordinator(
            registrations: [registration(provider: .openCode, driver: TestLoginDriver(provider: .openCode), proofSupportVerified: true)]
        )
        let proof = FigmaMCPVerifiedProviderStatus(
            runtimeProvider: .openCode,
            canonicalTarget: .figma,
            providerTargetIdentifier: "figma-server",
            credentialContext: .providerDefaultUserProfile,
            sanitizedSnapshot: .init(
                integrationID: "another:integration",
                connection: .connected,
                authentication: .providerOwned
            ),
            evidenceID: "evidence-openCode",
            capabilityRevision: "revision-1",
            operationGeneration: 0
        )

        XCTAssertFalse(coordinator.applyVerifiedStatus(
            proof,
            provider: .openCode,
            targetResolution: .resolved(
                providerTargetIdentifier: "figma-server",
                source: .reviewedFixedIdentifier,
                credentialContext: .providerDefaultUserProfile
            ),
            operationGeneration: 0
        ))
    }

    func testProviderMismatchCannotPublishProviderAProofIntoProviderB() throws {
        let providerA = ExternalMCPRuntimeProvider.claudeCode
        let providerB = ExternalMCPRuntimeProvider.openCode
        let coordinator = try makeCoordinator(registrations: [
            registration(provider: providerA, driver: TestLoginDriver(provider: providerA), proofSupportVerified: true),
            registration(provider: providerB, driver: TestLoginDriver(provider: providerB), proofSupportVerified: true)
        ])
        let proof = makeProof(provider: providerA, evidenceID: "evidence-\(providerA.rawValue)")

        XCTAssertFalse(coordinator.applyVerifiedStatus(
            proof,
            provider: providerB,
            targetResolution: resolvedFigmaTarget(),
            operationGeneration: 0
        ))
        XCTAssertFalse(coordinator.state(for: providerB).isConnected)
    }

    func testEvidenceMismatchCannotPublishProviderAProofIntoProviderB() throws {
        let providerA = ExternalMCPRuntimeProvider.claudeCode
        let providerB = ExternalMCPRuntimeProvider.openCode
        let coordinator = try makeCoordinator(registrations: [
            registration(provider: providerA, driver: TestLoginDriver(provider: providerA), proofSupportVerified: true),
            registration(provider: providerB, driver: TestLoginDriver(provider: providerB), proofSupportVerified: true)
        ])
        let proof = makeProof(provider: providerB, evidenceID: "evidence-\(providerA.rawValue)")

        XCTAssertFalse(coordinator.applyVerifiedStatus(
            proof,
            provider: providerB,
            targetResolution: resolvedFigmaTarget(),
            operationGeneration: 0
        ))
        XCTAssertFalse(coordinator.state(for: providerB).isConnected)
    }

    func testTargetMismatchCannotPublishProviderAProofIntoProviderB() throws {
        let providerA = ExternalMCPRuntimeProvider.claudeCode
        let providerB = ExternalMCPRuntimeProvider.openCode
        let coordinator = try makeCoordinator(registrations: [
            registration(provider: providerA, driver: TestLoginDriver(provider: providerA), proofSupportVerified: true),
            registration(provider: providerB, driver: TestLoginDriver(provider: providerB), proofSupportVerified: true)
        ])
        let proof = makeProof(provider: providerB, evidenceID: "evidence-\(providerB.rawValue)")

        XCTAssertFalse(coordinator.applyVerifiedStatus(
            proof,
            provider: providerB,
            targetResolution: .resolved(
                providerTargetIdentifier: "provider-a-figma",
                source: .reviewedFixedIdentifier,
                credentialContext: .providerDefaultUserProfile
            ),
            operationGeneration: 0
        ))
        XCTAssertFalse(coordinator.state(for: providerB).isConnected)
    }

    func testExecutableMismatchCannotPublishProviderProof() async throws {
        let provider = ExternalMCPRuntimeProvider.openCode
        let driver = TestVersionedLoginDriver(provider: provider, version: "2.1.186")
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: provider,
            evidenceID: "evidence-\(provider.rawValue)",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: provider,
            adapter: TestFailClosedAdapter(runtimeProvider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: provider),
            loginDriver: driver,
            structuredStatusChecker: { target, _, _, generation in
                .verified(.init(
                    runtimeProvider: provider,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    executableIdentity: "/usr/bin/provider-a",
                    executableVersion: "2.1.186",
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        _ = await coordinator.beginLogin(provider: provider)
        await waitUntil { !coordinator.isAuthorizing(provider) }

        XCTAssertFalse(coordinator.state(for: provider).isConnected)
        assertNotVerified(coordinator.state(for: provider), notice: .processCompletedWithoutProof)
    }

    func testProviderProofPublicationAndTerminationAdvanceNeutralRevision() async throws {
        let neutralCoordinator = ExternalMCPIntegrationCoordinator()
        let observer = TestTerminationObserver()
        let connectionCoordinator = try makeCoordinator(
            registrations: [registration(
                provider: .openCode,
                driver: TestLoginDriver(provider: .openCode),
                proofSupportVerified: true
            )],
            terminationObserver: observer,
            statusCoordinator: neutralCoordinator
        )
        let initialRevision = await neutralCoordinator.activeRevision()
        let proof = FigmaMCPVerifiedProviderStatus(
            runtimeProvider: .openCode,
            canonicalTarget: .figma,
            providerTargetIdentifier: "figma-server",
            credentialContext: .providerDefaultUserProfile,
            sanitizedSnapshot: .init(
                integrationID: ExternalMCPIntegrationTarget.figma.integrationID,
                connection: .connected,
                authentication: .providerOwned
            ),
            evidenceID: "evidence-openCode",
            capabilityRevision: "revision-1",
            operationGeneration: 0
        )

        XCTAssertTrue(connectionCoordinator.applyVerifiedStatus(
            proof,
            provider: .openCode,
            targetResolution: .resolved(
                providerTargetIdentifier: "figma-server",
                source: .reviewedFixedIdentifier,
                credentialContext: .providerDefaultUserProfile
            ),
            operationGeneration: 0
        ))
        let publishedRevision = await neutralCoordinator.currentRevision()
        XCTAssertGreaterThan(publishedRevision, initialRevision)

        observer.trigger()
        let terminationRevision = await neutralCoordinator.currentRevision()
        XCTAssertGreaterThan(terminationRevision, publishedRevision)
    }

    func testDeactivatingLastObserverDoesNotCancelActiveLogin() async throws {
        let driver = TestLoginDriver(provider: .claudeCode, waitsForCompletion: true)
        let coordinator = try makeCoordinator(registrations: [registration(provider: .claudeCode, driver: driver)])

        let attempt = await coordinator.beginLogin(provider: .claudeCode, ownerID: "window-a")
        coordinator.activate(observerID: "window-a")
        coordinator.deactivate(observerID: "window-a")

        XCTAssertNotNil(attempt)
        XCTAssertFalse(coordinator.observingSettings)
        let cancelCount = await driver.cancelCount
        XCTAssertEqual(cancelCount, 0)

        try await coordinator.cancelLogin(provider: .claudeCode, attemptID: XCTUnwrap(attempt))
    }

    func testApplicationTerminationCancelsAllProviderAttemptsThroughInjectedObserver() async throws {
        let observer = TestTerminationObserver()
        let driver = TestLoginDriver(provider: .openCode, waitsForCompletion: true)
        let coordinator = try makeCoordinator(
            registrations: [registration(provider: .openCode, driver: driver)],
            terminationObserver: observer
        )
        let attempt = await coordinator.beginLogin(provider: .openCode)

        observer.trigger()
        await waitUntil { await driver.cancelCount == 1 }

        XCTAssertNotNil(attempt)
        let cancelCount = await driver.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testConcurrentObserversShareOneAttemptAndBothReleaseOnTimeout() async throws {
        let timeoutGate = TestSleepGate()
        let resolver = TestHangingTargetResolver(runtimeProvider: .claudeCode)
        let driver = TestLoginDriver(provider: .claudeCode, waitsForCompletion: true)
        let coordinator = try makeCoordinator(
            registrations: [registration(provider: .claudeCode, driver: driver, resolver: resolver)],
            timing: .init(sleep: { _ in await timeoutGate.sleep() }, terminationDrainTimeoutNanoseconds: 1)
        )

        let first = Task { await coordinator.beginLogin(provider: .claudeCode, ownerID: "window-a") }
        await waitUntil { coordinator.state(for: .claudeCode) == .checking }
        let second = Task { await coordinator.beginLogin(provider: .claudeCode, ownerID: "window-b") }
        await timeoutGate.fire()

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertNil(firstResult)
        XCTAssertNil(secondResult)
        assertNotVerified(coordinator.state(for: .claudeCode), notice: .timedOutAuthenticationStateUnknown)
        await resolver.release()
    }

    func testCoordinatorDeadlineWinsWhenDriverBeginHangs() async throws {
        let timeoutGate = TestSleepGate()
        let driver = TestLoginDriver(provider: .claudeCode, waitsForCompletion: true)
        let coordinator = try makeCoordinator(
            registrations: [registration(provider: .claudeCode, driver: driver)],
            timing: .init(sleep: { _ in await timeoutGate.sleep() }, terminationDrainTimeoutNanoseconds: 1)
        )

        let begin = Task { await coordinator.beginLogin(provider: .claudeCode) }
        await waitUntil { await driver.beginCount == 1 }
        let active = await waitForAttempt(coordinator, provider: .claudeCode)
        await waitUntil { await timeoutGate.isWaiting() }
        await timeoutGate.fire()
        await waitUntil { coordinator.state(for: .claudeCode).isTimedOutNotice }

        let beginResult = await begin.value
        XCTAssertNotNil(beginResult)
        XCTAssertNotNil(active)
        assertNotVerified(coordinator.state(for: .claudeCode), notice: .timedOutAuthenticationStateUnknown)
        await waitUntil { await driver.cancelCount == 1 }
        let finalCancelCount = await driver.cancelCount
        XCTAssertEqual(finalCancelCount, 1)
    }

    func testCancellationIntentWinsAgainstLateSuccessfulExit() async throws {
        let driver = TestLateSettlementDriver(provider: .claudeCode)
        let coordinator = try makeCoordinator(registrations: [registration(provider: .claudeCode, driver: driver)])
        let attempt = await coordinator.beginLogin(provider: .claudeCode)
        let cancellation = Task { await coordinator.cancelLogin(provider: .claudeCode, attemptID: attempt!) }
        await waitUntil { coordinator.state(for: .claudeCode).isCancelledNotice }
        await driver.finish(.exited(status: 0))
        await cancellation.value

        assertNotVerified(coordinator.state(for: .claudeCode), notice: .cancelledAuthenticationStateUnknown)
    }

    func testTimeoutIntentWinsAgainstLateSuccessfulExit() async throws {
        let timeoutGate = TestSleepGate()
        let driver = TestLateSettlementDriver(provider: .claudeCode)
        let coordinator = try makeCoordinator(
            registrations: [registration(provider: .claudeCode, driver: driver)],
            timing: .init(sleep: { _ in await timeoutGate.sleep() }, terminationDrainTimeoutNanoseconds: 1)
        )
        _ = await coordinator.beginLogin(provider: .claudeCode)
        await timeoutGate.fire()
        await waitUntil { coordinator.state(for: .claudeCode).isTimedOutNotice }
        await driver.finish(.exited(status: 0))

        assertNotVerified(coordinator.state(for: .claudeCode), notice: .timedOutAuthenticationStateUnknown)
    }

    func testCurrentEvidenceReplacementBeforeExitSettlesAsStale() async throws {
        let driver = TestLateSettlementDriver(provider: .openCode)
        let box = TestRegistrationBox()
        let original = registration(provider: .openCode, driver: driver)
        box.registration = original
        let coordinator = try makeCoordinator(
            registrations: [original],
            registrationLookup: { _ in box.registration }
        )
        _ = await coordinator.beginLogin(provider: .openCode)
        box.registration = registration(provider: .openCode, driver: driver, evidenceRevision: "revision-2")
        await driver.finish(.exited(status: 0))
        await waitUntil { coordinator.state(for: .openCode) == .failed(.staleAttempt) }
        XCTAssertEqual(coordinator.state(for: .openCode), .failed(.staleAttempt))
    }

    func testCurrentDriverReplacementBeforeExitSettlesAsStale() async throws {
        let originalDriver = TestLateSettlementDriver(provider: .openCode)
        let replacementDriver = TestLateSettlementDriver(provider: .openCode)
        let box = TestRegistrationBox()
        let original = registration(provider: .openCode, driver: originalDriver)
        box.registration = original
        let coordinator = try makeCoordinator(
            registrations: [original],
            registrationLookup: { _ in box.registration }
        )
        _ = await coordinator.beginLogin(provider: .openCode)
        box.registration = registration(provider: .openCode, driver: replacementDriver)
        await originalDriver.finish(.exited(status: 0))
        await waitUntil { coordinator.state(for: .openCode) == .failed(.staleAttempt) }
        XCTAssertEqual(coordinator.state(for: .openCode), .failed(.staleAttempt))
    }

    func testTerminationDrainIsBoundedAndRepeatedTerminationIsIdempotent() async throws {
        let cancellationGate = TestSleepGate()
        let drainGate = TestSleepGate()
        let driver = TestLateSettlementDriver(provider: .openCode, cancellationGate: cancellationGate)
        let observer = TestTerminationObserver()
        let coordinator = try makeCoordinator(
            registrations: [registration(provider: .openCode, driver: driver)],
            terminationObserver: observer,
            timing: .init(sleep: { _ in await drainGate.sleep() }, terminationDrainTimeoutNanoseconds: 1)
        )
        _ = await coordinator.beginLogin(provider: .openCode)
        observer.trigger()
        coordinator.applicationWillTerminate()
        let waiting = Task { await coordinator.awaitApplicationTermination() }
        await drainGate.fire()
        await waiting.value
        let cancelCount = await driver.cancelCount
        XCTAssertEqual(cancelCount, 1)
        await cancellationGate.fire()
        await driver.finish(.cancelled)
        await coordinator.awaitApplicationTermination()
    }

    func testLateProofAfterTimeoutIsRejectedByRetiredGeneration() async throws {
        let timeoutGate = TestSleepGate()
        let driver = TestLateSettlementDriver(provider: .openCode)
        let coordinator = try makeCoordinator(
            registrations: [registration(provider: .openCode, driver: driver, proofSupportVerified: true)],
            timing: .init(sleep: { _ in await timeoutGate.sleep() }, terminationDrainTimeoutNanoseconds: 1)
        )
        _ = await coordinator.beginLogin(provider: .openCode)
        let resolvedAttempt = await waitForAttempt(coordinator, provider: .openCode)
        let attempt = try XCTUnwrap(resolvedAttempt)
        await timeoutGate.fire()
        await waitUntil { coordinator.state(for: .openCode).isTimedOutNotice }

        let proof = FigmaMCPVerifiedProviderStatus(
            runtimeProvider: .openCode,
            canonicalTarget: .figma,
            providerTargetIdentifier: attempt.providerTargetIdentifier,
            credentialContext: attempt.credentialContext,
            sanitizedSnapshot: ExternalMCPRuntimeSnapshot(
                integrationID: "figma:figma",
                connection: .connected,
                authentication: .providerOwned,
                verifiedAt: Date()
            ),
            evidenceID: attempt.evidenceID,
            capabilityRevision: attempt.capabilityRevision,
            operationGeneration: attempt.operationGeneration
        )
        XCTAssertFalse(coordinator.applyVerifiedStatus(
            proof,
            provider: .openCode,
            targetResolution: .resolved(
                providerTargetIdentifier: attempt.providerTargetIdentifier,
                source: .reviewedFixedIdentifier,
                credentialContext: attempt.credentialContext
            ),
            operationGeneration: attempt.operationGeneration
        ))
        await driver.finish(.exited(status: 0))
    }

    func testLateProofAfterCancellationIsRejectedByRetiredGeneration() async throws {
        let driver = TestLoginDriver(provider: .openCode, waitsForCompletion: true)
        let coordinator = try makeCoordinator(
            registrations: [registration(provider: .openCode, driver: driver, proofSupportVerified: true)]
        )
        let startedAttemptID = await coordinator.beginLogin(provider: .openCode)
        let attemptID = try XCTUnwrap(startedAttemptID)
        let resolvedAttempt = await waitForAttempt(coordinator, provider: .openCode)
        let attempt = try XCTUnwrap(resolvedAttempt)
        await coordinator.cancelLogin(provider: .openCode, attemptID: attemptID)

        let proof = FigmaMCPVerifiedProviderStatus(
            runtimeProvider: .openCode,
            canonicalTarget: .figma,
            providerTargetIdentifier: attempt.providerTargetIdentifier,
            credentialContext: attempt.credentialContext,
            sanitizedSnapshot: ExternalMCPRuntimeSnapshot(
                integrationID: "figma:figma",
                connection: .connected,
                authentication: .providerOwned,
                verifiedAt: Date()
            ),
            evidenceID: attempt.evidenceID,
            capabilityRevision: attempt.capabilityRevision,
            operationGeneration: attempt.operationGeneration
        )
        XCTAssertFalse(coordinator.applyVerifiedStatus(
            proof,
            provider: .openCode,
            targetResolution: .resolved(
                providerTargetIdentifier: attempt.providerTargetIdentifier,
                source: .reviewedFixedIdentifier,
                credentialContext: attempt.credentialContext
            ),
            operationGeneration: attempt.operationGeneration
        ))
    }

    func testSuccessfulFakeLoginThenStructuredProofPublishesConnected() async throws {
        let driver = TestLoginDriver(provider: .openCode, result: .exited(status: 0))
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "proof-evidence",
            capabilityRevision: "proof-revision"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: driver,
            structuredStatusChecker: { target, _, context, generation in
                .verified(.init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned,
                        verifiedAt: Date()
                    ),
                    evidenceID: context.identity.provider == .openCode ? evidence.evidenceID : "wrong",
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        _ = await coordinator.beginLogin(provider: .openCode)
        await waitUntil { coordinator.state(for: .openCode).isConnected }

        guard case let .connected(proof) = coordinator.state(for: .openCode) else {
            return XCTFail("Expected a fresh structured proof to publish Connected")
        }
        XCTAssertEqual(proof.evidenceID, evidence.evidenceID)
        XCTAssertEqual(proof.sanitizedSnapshot.authentication, .providerOwned)
    }

    func testUnauthenticatedAndExpiredStructuredOutcomesPublishNeedsLogin() async throws {
        for outcome in [FigmaMCPProviderStructuredStatusOutcome.unauthenticated, .expired] {
            let driver = TestLoginDriver(provider: .openCode, result: .exited(status: 0))
            let evidence = FigmaMCPProviderCapabilityEvidence(
                provider: .openCode,
                evidenceID: "negative-\(outcome)",
                capabilityRevision: "revision-1"
            )
            let registration = ExternalMCPProviderRegistration(
                provider: .openCode,
                adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
                figmaCapabilities: .init(
                    provider: .openCode,
                    loginSupport: .verified(evidence),
                    proofSupport: .verified(evidence),
                    revocationSupport: .unverified(.noRevocationContract),
                    runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
                ),
                targetResolver: TestTargetResolver(runtimeProvider: .openCode),
                loginDriver: driver,
                structuredStatusChecker: { _, _, _, _ in outcome }
            )
            let coordinator = try makeCoordinator(registrations: [registration])

            _ = await coordinator.beginLogin(provider: .openCode)
            await waitUntil { coordinator.state(for: .openCode) == .needsLogin }

            XCTAssertEqual(coordinator.state(for: .openCode), .needsLogin)
        }
    }

    func testMultipleSettingsObserversShareOneActivationProofCheck() async throws {
        let driver = TestLoginDriver(provider: .openCode)
        let checker = TestStructuredStatusCounter()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "shared-evidence",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .openCode),
            loginDriver: driver,
            structuredStatusChecker: { _, _, _, _ in
                await checker.increment()
                return .unknown
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        coordinator.activate(observerID: "window-a")
        coordinator.activate(observerID: "window-b")
        await waitUntil { await checker.value == 1 }

        let checkerValue = await checker.value
        XCTAssertEqual(checkerValue, 1)
        XCTAssertTrue(coordinator.observingSettings)
        coordinator.deactivate(observerID: "window-a")
        XCTAssertTrue(coordinator.observingSettings)
        coordinator.deactivate(observerID: "window-b")
        XCTAssertFalse(coordinator.observingSettings)
    }

    func testExecutableVersionDriftBeforeProofPublicationNeverConnects() async throws {
        let driver = TestVersionedLoginDriver(provider: .claudeCode, version: "2.1.186")
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .claudeCode,
            evidenceID: "versioned-evidence",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .claudeCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .claudeCode),
            figmaCapabilities: .init(
                provider: .claudeCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: TestTargetResolver(runtimeProvider: .claudeCode),
            loginDriver: driver,
            structuredStatusChecker: { target, _, _, generation in
                await driver.setVersion("2.1.187")
                return .verified(.init(
                    runtimeProvider: .claudeCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        _ = await coordinator.beginLogin(provider: .claudeCode)
        await waitUntil { coordinator.state(for: .claudeCode) == .failed(.staleAttempt) }

        XCTAssertEqual(coordinator.state(for: .claudeCode), .failed(.staleAttempt))
    }

    func testMutableTargetResolutionChangeDuringLoginSettlementFailsClosed() async throws {
        let resolverGate = TestSleepGate()
        let initialResolution = resolvedFigmaTarget()
        let changedResolution = FigmaMCPProviderTargetResolution.resolved(
            providerTargetIdentifier: "figma-rebound",
            source: .providerStandardUserMetadata,
            credentialContext: .providerDefaultUserProfile
        )
        let resolver = TestSuspendedMutableTargetResolver(
            runtimeProvider: .openCode,
            initialResolution: initialResolution,
            suspendedCall: 2,
            suspensionGate: resolverGate
        )
        let driver = TestLateSettlementDriver(provider: .openCode)
        let checker = TestStructuredStatusCounter()
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "mutable-login-resolution",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: resolver,
            loginDriver: driver,
            structuredStatusChecker: { _, _, _, _ in
                await checker.increment()
                return .unknown
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        _ = await coordinator.beginLogin(provider: .openCode)
        await waitUntil { await driver.beginCount == 1 }
        await resolver.setResolution(changedResolution)
        await driver.finish(.exited(status: 0))
        await waitUntil { await resolver.isSuspendedCallWaiting() }
        let resolverIsSuspended = await resolver.isSuspendedCallWaiting()
        XCTAssertTrue(resolverIsSuspended)

        await resolverGate.fire()
        await waitUntil { coordinator.state(for: .openCode) == .failed(.staleAttempt) }

        XCTAssertEqual(coordinator.state(for: .openCode), .failed(.staleAttempt))
        XCTAssertFalse(coordinator.state(for: .openCode).isConnected)
        let checkerValue = await checker.value
        XCTAssertEqual(checkerValue, 0)
    }

    func testMutableTargetResolutionChangeDuringStructuredProofApplicationFailsClosed() async throws {
        let resolverGate = TestSleepGate()
        let checkerGate = TestSleepGate()
        let checker = TestStructuredStatusCounter()
        let initialResolution = resolvedFigmaTarget()
        let changedResolution = FigmaMCPProviderTargetResolution.resolved(
            providerTargetIdentifier: "figma-rebound",
            source: .providerStandardUserMetadata,
            credentialContext: .providerDefaultUserProfile
        )
        let resolver = TestSuspendedMutableTargetResolver(
            runtimeProvider: .openCode,
            initialResolution: initialResolution,
            suspendedCall: 3,
            suspensionGate: resolverGate
        )
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: .openCode,
            evidenceID: "mutable-proof-resolution",
            capabilityRevision: "revision-1"
        )
        let registration = ExternalMCPProviderRegistration(
            provider: .openCode,
            adapter: TestFailClosedAdapter(runtimeProvider: .openCode),
            figmaCapabilities: .init(
                provider: .openCode,
                loginSupport: .verified(evidence),
                proofSupport: .verified(evidence),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: resolver,
            loginDriver: TestLoginDriver(provider: .openCode),
            structuredStatusChecker: { target, _, _, generation in
                await checker.increment()
                await checkerGate.sleep()
                return .verified(.init(
                    runtimeProvider: .openCode,
                    canonicalTarget: target,
                    providerTargetIdentifier: "figma-server",
                    credentialContext: .providerDefaultUserProfile,
                    sanitizedSnapshot: .init(
                        integrationID: target.integrationID,
                        connection: .connected,
                        authentication: .providerOwned
                    ),
                    evidenceID: evidence.evidenceID,
                    capabilityRevision: evidence.capabilityRevision,
                    operationGeneration: generation
                ))
            }
        )
        let coordinator = try makeCoordinator(registrations: [registration])

        coordinator.activate(observerID: "window")
        await waitUntil {
            let checkerStarted = await checker.value == 1
            let checkerSuspended = await checkerGate.isWaiting()
            return checkerStarted && checkerSuspended
        }
        await resolver.setResolution(changedResolution)
        await checkerGate.fire()
        await waitUntil { await resolver.isSuspendedCallWaiting() }
        let resolverIsSuspended = await resolver.isSuspendedCallWaiting()
        XCTAssertTrue(resolverIsSuspended)

        await resolverGate.fire()
        await waitUntil {
            coordinator.state(for: .openCode) == .notVerified(loginAvailability: .available, notice: nil)
        }

        XCTAssertEqual(
            coordinator.state(for: .openCode),
            .notVerified(loginAvailability: .available, notice: nil)
        )
        XCTAssertFalse(coordinator.state(for: .openCode).isConnected)
        coordinator.deactivate(observerID: "window")
    }

    func testUnverifiedProofCapabilityDoesNotProbeOnActivation() async throws {
        let driver = TestLoginDriver(provider: .openCode)
        let registration = registration(
            provider: .openCode,
            driver: driver,
            proofSupportVerified: false
        )
        let coordinator = try makeCoordinator(
            registrations: [registration]
        )

        coordinator.activate(observerID: "window")
        await Task.yield()

        let beginCount = await driver.beginCount
        XCTAssertEqual(beginCount, 0)
        if case .connected = coordinator.state(for: .openCode) {
            XCTFail("An unverified capability must not publish Connected")
        }
    }

    private func makeProof(
        provider: ExternalMCPRuntimeProvider,
        evidenceID: String,
        capabilityRevision: String = "revision-1",
        providerTargetIdentifier: String = "figma-server"
    ) -> FigmaMCPVerifiedProviderStatus {
        FigmaMCPVerifiedProviderStatus(
            runtimeProvider: provider,
            canonicalTarget: .figma,
            providerTargetIdentifier: providerTargetIdentifier,
            credentialContext: .providerDefaultUserProfile,
            sanitizedSnapshot: .init(
                integrationID: ExternalMCPIntegrationTarget.figma.integrationID,
                connection: .connected,
                authentication: .providerOwned
            ),
            evidenceID: evidenceID,
            capabilityRevision: capabilityRevision,
            operationGeneration: 0
        )
    }

    private func resolvedFigmaTarget() -> FigmaMCPProviderTargetResolution {
        .resolved(
            providerTargetIdentifier: "figma-server",
            source: .reviewedFixedIdentifier,
            credentialContext: .providerDefaultUserProfile
        )
    }

    private func registration(
        provider: ExternalMCPRuntimeProvider,
        driver: any FigmaMCPProviderLoginDriving,
        resolver: (any FigmaMCPProviderTargetResolving)? = nil,
        proofSupportVerified: Bool = false,
        evidenceRevision: String = "revision-1"
    ) -> ExternalMCPProviderRegistration {
        let evidence = FigmaMCPProviderCapabilityEvidence(
            provider: provider,
            evidenceID: "evidence-\(provider.rawValue)",
            capabilityRevision: evidenceRevision
        )
        return ExternalMCPProviderRegistration(
            provider: provider,
            adapter: TestFailClosedAdapter(runtimeProvider: provider),
            figmaCapabilities: .init(
                provider: provider,
                loginSupport: .verified(evidence),
                proofSupport: proofSupportVerified ? .verified(evidence) : .unverified(.noStructuredProofContract),
                revocationSupport: .unverified(.noRevocationContract),
                runtimeBindingSupport: .unverified(.noRuntimeBindingContract)
            ),
            targetResolver: resolver ?? TestTargetResolver(runtimeProvider: provider),
            loginDriver: driver,
            structuredProofChecker: proofSupportVerified ? { _, _, _, _ in nil } : nil
        )
    }

    private func makeCoordinator(
        registrations: [ExternalMCPProviderRegistration],
        terminationObserver: (any ApplicationTerminationObserving)? = nil,
        timing: FigmaMCPProviderConnectionCoordinatorTiming = .init(),
        statusCoordinator: ExternalMCPIntegrationCoordinator? = nil,
        registrationLookup: (@MainActor (ExternalMCPRuntimeProvider) -> ExternalMCPProviderRegistration?)? = nil
    ) throws -> FigmaMCPProviderConnectionCoordinator {
        let registry = try ExternalMCPAdapterRegistry(registrations: registrations)
        return FigmaMCPProviderConnectionCoordinator(
            registry: registry, sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }),
            terminationObserver: terminationObserver ?? TestTerminationObserver(),
            timing: timing,
            statusCoordinator: statusCoordinator,
            registrationLookup: registrationLookup
        )
    }

    private func assertNotVerified(
        _ state: FigmaMCPProviderConnectionState?,
        notice: FigmaMCPProviderLoginNotice
    ) {
        guard case let .notVerified(_, actualNotice) = state else {
            XCTFail("Expected Not verified state, got \(String(describing: state))")
            return
        }
        XCTAssertEqual(actualNotice, notice)
    }
}

private extension FigmaMCPProviderConnectionCoordinator {
    func isAuthorizing(_ provider: ExternalMCPRuntimeProvider) -> Bool {
        if case .authorizing = state(for: provider) { return true }
        return false
    }
}

private extension FigmaMCPProviderConnectionState? {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isCancelledNotice: Bool {
        guard case let .notVerified(_, notice) = self else { return false }
        return notice == .cancelledAuthenticationStateUnknown
    }

    var isTimedOutNotice: Bool {
        guard case let .notVerified(_, notice) = self else { return false }
        return notice == .timedOutAuthenticationStateUnknown
    }
}

@MainActor
private func waitForAttempt(
    _ coordinator: FigmaMCPProviderConnectionCoordinator,
    provider: ExternalMCPRuntimeProvider
) async -> FigmaMCPProviderLoginAttempt? {
    for _ in 0 ..< 100 {
        if let attempt = coordinator.activeAttempt(for: provider) { return attempt }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return nil
}

private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool
) async {
    for _ in 0 ..< 100 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

private actor TestProviderOwnedLogoutState {
    private(set) var callCount = 0
    private(set) var didLogout = false

    func logout() {
        callCount += 1
        didLogout = true
    }
}

private struct TestProviderOwnedLogoutAdapter: ExternalMCPFailClosedProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider
    let state: TestProviderOwnedLogoutState

    func disconnect(
        in _: ExternalMCPProviderRuntimeContext,
        integration: ExternalMCPIntegrationDefinition
    ) async -> ExternalMCPDisconnectResult {
        await state.logout()
        return .init(
            receipt: .init(outcome: .completed, detail: "provider-owned logout"),
            snapshot: .disconnected(integrationID: integration.integrationID)
        )
    }
}

private actor TestSleepGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep() async {
        if released { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func isWaiting() -> Bool {
        !waiters.isEmpty
    }

    func fire() {
        released = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor TestSleepProbe {
    private var values: [UInt64] = []

    func record(_ value: UInt64) {
        values.append(value)
    }

    func valueCount() -> Int {
        values.count
    }

    func lastValue() -> UInt64 {
        values.last ?? 0
    }
}

private actor TestStructuredStatusTokenProbe {
    private var token: ExternalMCPCancellationToken?
    private var waiters: [CheckedContinuation<ExternalMCPCancellationToken, Never>] = []

    func capture(_ token: ExternalMCPCancellationToken) {
        self.token = token
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: token) }
    }

    func isCaptured() -> Bool {
        token != nil
    }

    func isCancelled() -> Bool {
        token?.isCancelled == true
    }

    func waitUntilCancelled() async {
        let token = await waitForToken()
        while !token.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func waitForToken() async -> ExternalMCPCancellationToken {
        if let token { return token }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor TestSuspendedMutableTargetResolver: FigmaMCPProviderTargetResolving {
    let runtimeProvider: ExternalMCPRuntimeProvider
    private var resolution: FigmaMCPProviderTargetResolution
    private let suspendedCall: Int
    private let suspensionGate: TestSleepGate
    private var callCount = 0

    init(
        runtimeProvider: ExternalMCPRuntimeProvider,
        initialResolution: FigmaMCPProviderTargetResolution,
        suspendedCall: Int,
        suspensionGate: TestSleepGate
    ) {
        self.runtimeProvider = runtimeProvider
        resolution = initialResolution
        self.suspendedCall = suspendedCall
        self.suspensionGate = suspensionGate
    }

    func resolveTarget(for _: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        callCount += 1
        if callCount == suspendedCall {
            await suspensionGate.sleep()
        }
        return resolution
    }

    func setResolution(_ resolution: FigmaMCPProviderTargetResolution) {
        self.resolution = resolution
    }

    func isSuspendedCallWaiting() async -> Bool {
        guard callCount >= suspendedCall else { return false }
        return await suspensionGate.isWaiting()
    }
}

private actor TestHangingTargetResolver: FigmaMCPProviderTargetResolving {
    let runtimeProvider: ExternalMCPRuntimeProvider
    private var continuation: CheckedContinuation<FigmaMCPProviderTargetResolution, Never>?

    init(runtimeProvider: ExternalMCPRuntimeProvider) {
        self.runtimeProvider = runtimeProvider
    }

    func resolveTarget(for _: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume(returning: .resolved(
            providerTargetIdentifier: "figma-server",
            source: .reviewedFixedIdentifier,
            credentialContext: .providerDefaultUserProfile
        ))
        continuation = nil
    }
}

private actor TestLateSettlementDriver: FigmaMCPProviderLoginDriving, FigmaMCPProviderSubprocessAttemptReserving {
    let runtimeProvider: ExternalMCPRuntimeProvider
    private(set) var beginCount = 0
    private(set) var cancelCount = 0
    private(set) var attemptContexts: [FigmaMCPProviderLoginAttemptContext] = []
    private(set) var cancellationAttemptIDs: [UUID] = []
    private var reservedAttemptIDs = Set<UUID>()
    private var activeAttemptID: UUID?
    private var continuation: CheckedContinuation<FigmaMCPProviderLoginSettlement, Never>?
    private let cancellationGate: TestSleepGate?

    init(provider: ExternalMCPRuntimeProvider, cancellationGate: TestSleepGate? = nil) {
        runtimeProvider = provider
        self.cancellationGate = cancellationGate
    }

    func evaluateAvailability(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget
    ) async -> FigmaMCPProviderLoginAvailability {
        provider == runtimeProvider && target == .figma ? .available : .unavailable("mismatch")
    }

    func beginLogin(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        attemptContext: FigmaMCPProviderLoginAttemptContext
    ) async -> FigmaMCPProviderLoginSettlement {
        guard provider == runtimeProvider, target == .figma else { return .launchFailed }
        attemptContexts.append(attemptContext)
        activeAttemptID = attemptContext.attemptID
        reservedAttemptIDs.remove(attemptContext.attemptID)
        beginCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func reserveAttempt(_ attemptID: UUID) async -> FigmaMCPProviderSubprocessAttemptReservation {
        reservedAttemptIDs.insert(attemptID)
        return .reserved
    }

    func cancelLogin(provider: ExternalMCPRuntimeProvider, attemptID: UUID) async {
        guard provider == runtimeProvider,
              reservedAttemptIDs.contains(attemptID) || activeAttemptID == attemptID
        else { return }
        cancellationAttemptIDs.append(attemptID)
        cancelCount += 1
        if let cancellationGate { await cancellationGate.sleep() }
    }

    func finish(_ settlement: FigmaMCPProviderLoginSettlement) {
        continuation?.resume(returning: settlement)
        continuation = nil
    }
}

private actor TestStructuredStatusCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }

    func incrementAndReturn() -> Int {
        value += 1
        return value
    }
}

private actor TestVersionedLoginDriver: FigmaMCPProviderLoginDriving, FigmaMCPProviderSubprocessExecutableResolving, FigmaMCPProviderSubprocessAttemptReserving {
    let runtimeProvider: ExternalMCPRuntimeProvider
    let executableVersion: String? = "2.1.186"
    private(set) var attemptContexts: [FigmaMCPProviderLoginAttemptContext] = []
    private(set) var cancellationAttemptIDs: [UUID] = []
    private var reservedAttemptIDs = Set<UUID>()
    private var activeAttemptID: UUID?
    private var version: String

    init(provider: ExternalMCPRuntimeProvider, version: String) {
        runtimeProvider = provider
        self.version = version
    }

    func evaluateAvailability(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget
    ) async -> FigmaMCPProviderLoginAvailability {
        guard provider == runtimeProvider, target == .figma else {
            return .unavailable("The provider executable is unavailable or unsupported.")
        }
        return await supportsExecutableVersion(version)
            ? .available
            : .unavailable("The provider executable is unavailable or unsupported.")
    }

    func beginLogin(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        attemptContext: FigmaMCPProviderLoginAttemptContext
    ) async -> FigmaMCPProviderLoginSettlement {
        guard provider == runtimeProvider, target == .figma else { return .launchFailed }
        attemptContexts.append(attemptContext)
        reservedAttemptIDs.remove(attemptContext.attemptID)
        activeAttemptID = attemptContext.attemptID
        return .exited(status: 0)
    }

    func reserveAttempt(_ attemptID: UUID) async -> FigmaMCPProviderSubprocessAttemptReservation {
        reservedAttemptIDs.insert(attemptID)
        return .reserved
    }

    func cancelLogin(provider: ExternalMCPRuntimeProvider, attemptID: UUID) async {
        guard provider == runtimeProvider,
              reservedAttemptIDs.contains(attemptID) || activeAttemptID == attemptID
        else { return }
        cancellationAttemptIDs.append(attemptID)
    }

    func executableIdentity() async -> String? {
        "/usr/bin/claude"
    }

    func currentExecutableVersion() async -> String? {
        version
    }

    func supportsExecutableVersion(_ version: String?) async -> Bool {
        version == "2.1.186" || version == "2.1.187"
    }

    func setVersion(_ version: String) {
        self.version = version
    }
}

private struct TestTargetResolver: FigmaMCPProviderTargetResolving {
    let runtimeProvider: ExternalMCPRuntimeProvider

    func resolveTarget(for _: ExternalMCPIntegrationTarget) async -> FigmaMCPProviderTargetResolution {
        .resolved(
            providerTargetIdentifier: "figma-server",
            source: .reviewedFixedIdentifier,
            credentialContext: .providerDefaultUserProfile
        )
    }
}

private struct TestFailClosedAdapter: ExternalMCPFailClosedProviderAdapter {
    let runtimeProvider: ExternalMCPRuntimeProvider
}

private actor TestLoginDriver: FigmaMCPProviderLoginDriving, FigmaMCPProviderSubprocessAttemptReserving {
    let runtimeProvider: ExternalMCPRuntimeProvider
    private let waitsForCompletion: Bool
    private let result: FigmaMCPProviderLoginSettlement
    private(set) var beginCount = 0
    private(set) var cancelCount = 0
    private(set) var attemptContexts: [FigmaMCPProviderLoginAttemptContext] = []
    private(set) var cancellationAttemptIDs: [UUID] = []
    private(set) var reservedAttemptID: UUID?
    private var continuation: CheckedContinuation<FigmaMCPProviderLoginSettlement, Never>?
    private var cancelledBeforeBegin = false

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
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget
    ) async -> FigmaMCPProviderLoginAvailability {
        provider == runtimeProvider && target == .figma ? .available : .unavailable("mismatch")
    }

    func beginLogin(
        provider: ExternalMCPRuntimeProvider,
        target: ExternalMCPIntegrationTarget,
        attemptContext: FigmaMCPProviderLoginAttemptContext
    ) async -> FigmaMCPProviderLoginSettlement {
        attemptContexts.append(attemptContext)
        reservedAttemptID = nil
        beginCount += 1
        guard provider == runtimeProvider, target == .figma, waitsForCompletion else { return result }
        if cancelledBeforeBegin {
            cancelledBeforeBegin = false
            return .cancelled
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func reserveAttempt(_ attemptID: UUID) async -> FigmaMCPProviderSubprocessAttemptReservation {
        reservedAttemptID = attemptID
        return .reserved
    }

    func cancelLogin(provider: ExternalMCPRuntimeProvider, attemptID: UUID) async {
        guard provider == runtimeProvider,
              reservedAttemptID == attemptID || attemptContexts.last?.attemptID == attemptID
        else { return }
        cancellationAttemptIDs.append(attemptID)
        cancelCount += 1
        if let continuation {
            continuation.resume(returning: .cancelled)
            self.continuation = nil
        } else {
            cancelledBeforeBegin = true
        }
    }
}

@MainActor
private final class TestRegistrationBox {
    var registration: ExternalMCPProviderRegistration?
}

@MainActor
private final class TestTerminationObserver: ApplicationTerminationObserving {
    private var handler: (@MainActor () -> Void)?

    func observeApplicationTermination(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        self.handler = handler
        return NSObject()
    }

    func removeApplicationTerminationObserver(_: NSObjectProtocol) {}

    func trigger() {
        handler?()
    }
}
