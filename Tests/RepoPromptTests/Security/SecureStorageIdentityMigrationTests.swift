import Foundation
@testable import RepoPromptApp
import XCTest

final class SecureStorageIdentityMigrationTests: XCTestCase {
    private let accounts: [SecureStorageAccount] = [.openAIAPI, .anthropicAPI]
    private let firstAttemptIdentifier = "123e4567-e89b-12d3-a456-426614174000"
    private let secondAttemptIdentifier = "123e4567-e89b-12d3-a456-426614174001"

    func testPreparationCopiesValuesCommitsBothManifestsAndPreservesSource() throws {
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()
        let state = TestIdentityMigrationStateStore()
        var attemptIdentifiers: [String] = []
        let coordinator = makeCoordinator(source: source, state: state) { attemptIdentifier in
            attemptIdentifiers.append(attemptIdentifier)
            return bridge
        }

        let report = coordinator.prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        XCTAssertEqual(report.records.map(\.state), [.copied, .absent])
        XCTAssertEqual(source.value(for: SecureStorageAccount.openAIAPI.identifier), "secret")
        XCTAssertEqual(bridge.value(for: SecureStorageAccount.openAIAPI.identifier), "secret")
        XCTAssertFalse(source.calls.contains { $0.operation == .delete })
        XCTAssertEqual(state.savedManifests.map(\.status), [.preparing, .committed])
        XCTAssertEqual(state.createdManifests.map(\.status), [.preparing])

        let committed = try XCTUnwrap(state.manifest)
        XCTAssertEqual(committed.version, SecureStorageIdentityMigrationManifest.currentVersion)
        XCTAssertEqual(committed.status, .committed)
        XCTAssertEqual(committed.catalogIdentifiers, accounts.map(\.identifier).sorted())
        XCTAssertEqual(attemptIdentifiers, [committed.attemptIdentifier])
        XCTAssertEqual(
            bridge.value(for: SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount),
            SecureStorageIdentityMigrationCoordinator.encodeManifest(committed)
        )
        XCTAssertTrue((source.calls + bridge.calls).allSatisfy {
            $0.accessMode == .nonInteractive(reason: .launch)
        })
    }

    func testPreflightReadFailureWritesNeitherJournalNorBridge() {
        let source = MigrationTestBackend()
        source.getErrors[SecureStorageAccount.openAIAPI.identifier] =
            KeychainService.KeychainError.interactionNotAllowed
        let bridge = MigrationTestBackend()
        let state = TestIdentityMigrationStateStore()
        var factoryCallCount = 0
        let coordinator = makeCoordinator(source: source, state: state) { _ in
            factoryCallCount += 1
            return bridge
        }

        let report = coordinator.prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.records.first?.state, .interactionRequired)
        XCTAssertTrue(report.blockedUpdateMessage?.contains("login Keychain is locked or unavailable") == true)
        XCTAssertTrue(state.savedManifests.isEmpty)
        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testPreflightPreservesCancelledAndAuthenticationFailures() {
        let cancellationSource = MigrationTestBackend()
        cancellationSource.getErrors[SecureStorageAccount.openAIAPI.identifier] =
            KeychainService.KeychainError.userInteractionCancelled

        let cancellationReport = makeCoordinator(
            source: cancellationSource,
            bridge: MigrationTestBackend(),
            state: TestIdentityMigrationStateStore()
        ).prepareBridge()

        XCTAssertEqual(cancellationReport.records.first?.state, .userInteractionCancelled)
        XCTAssertTrue(cancellationReport.blockedUpdateMessage?.contains("Keychain access was cancelled") == true)

        let authenticationSource = MigrationTestBackend()
        authenticationSource.getErrors[SecureStorageAccount.openAIAPI.identifier] =
            KeychainService.KeychainError.authenticationFailed

        let authenticationReport = makeCoordinator(
            source: authenticationSource,
            bridge: MigrationTestBackend(),
            state: TestIdentityMigrationStateStore()
        ).prepareBridge()

        XCTAssertEqual(authenticationReport.records.first?.state, .authenticationFailed)
        XCTAssertTrue(authenticationReport.blockedUpdateMessage?.contains("Keychain authentication failed") == true)
    }

    func testInterruptedPreparationResumesFromSourceAndCommits() throws {
        let source = MigrationTestBackend(values: [
            SecureStorageAccount.openAIAPI.identifier: "openai-v1",
            SecureStorageAccount.anthropicAPI.identifier: "anthropic"
        ])
        let bridge = MigrationTestBackend()
        bridge.createErrors[SecureStorageAccount.anthropicAPI.identifier] =
            KeychainService.KeychainError.unexpectedStatus(-1)
        let state = TestIdentityMigrationStateStore()
        let coordinator = makeCoordinator(source: source, bridge: bridge, state: state)

        let firstReport = coordinator.prepareBridge()

        XCTAssertFalse(firstReport.bridgeReady)
        XCTAssertEqual(firstReport.records.map(\.state), [.copied, .failed])
        XCTAssertEqual(state.manifest?.status, .preparing)
        XCTAssertEqual(bridge.value(for: SecureStorageAccount.openAIAPI.identifier), "openai-v1")

        source.setValue("openai-v2", for: SecureStorageAccount.openAIAPI.identifier)
        bridge.createErrors.removeValue(forKey: SecureStorageAccount.anthropicAPI.identifier)

        let resumedReport = coordinator.prepareBridge()

        XCTAssertTrue(resumedReport.bridgeReady)
        XCTAssertEqual(resumedReport.records.map(\.state), [.copied, .copied])
        XCTAssertEqual(bridge.value(for: SecureStorageAccount.openAIAPI.identifier), "openai-v2")
        XCTAssertEqual(bridge.value(for: SecureStorageAccount.anthropicAPI.identifier), "anthropic")
        XCTAssertEqual(try XCTUnwrap(state.manifest).status, .committed)
    }

    func testLostJournalStartsNewServiceAndIgnoresOrphanedAttemptItems() {
        let source = MigrationTestBackend(values: [
            SecureStorageAccount.openAIAPI.identifier: "openai",
            SecureStorageAccount.anthropicAPI.identifier: "anthropic"
        ])
        let firstBridge = MigrationTestBackend()
        firstBridge.createErrors[SecureStorageAccount.anthropicAPI.identifier] =
            KeychainService.KeychainError.unexpectedStatus(-1)
        let secondBridge = MigrationTestBackend()
        let state = TestIdentityMigrationStateStore()
        var generatedAttempts = [firstAttemptIdentifier, secondAttemptIdentifier]
        let coordinator = makeCoordinator(
            source: source,
            state: state,
            attemptIdentifierGenerator: { generatedAttempts.removeFirst() }
        ) { attemptIdentifier in
            switch attemptIdentifier {
            case self.firstAttemptIdentifier:
                firstBridge
            case self.secondAttemptIdentifier:
                secondBridge
            default:
                throw TestStateError.failed
            }
        }

        XCTAssertFalse(coordinator.prepareBridge().bridgeReady)
        XCTAssertEqual(
            firstBridge.value(for: SecureStorageAccount.openAIAPI.identifier),
            "openai"
        )
        state.simulateJournalLoss()

        let recoveredReport = coordinator.prepareBridge()

        XCTAssertTrue(recoveredReport.bridgeReady)
        XCTAssertEqual(secondBridge.value(for: SecureStorageAccount.openAIAPI.identifier), "openai")
        XCTAssertEqual(secondBridge.value(for: SecureStorageAccount.anthropicAPI.identifier), "anthropic")
        XCTAssertEqual(state.manifest?.attemptIdentifier, secondAttemptIdentifier)
    }

    func testPreparingJournalRemovesAttemptScopedValueWhenSourceWasDeleted() {
        let manifest = makeManifest(status: .preparing)
        let source = MigrationTestBackend()
        let bridge = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "stale"])
        let state = TestIdentityMigrationStateStore(manifest: manifest)

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        XCTAssertNil(bridge.value(for: SecureStorageAccount.openAIAPI.identifier))
        XCTAssertTrue(bridge.calls.contains {
            $0.operation == .delete && $0.key == SecureStorageAccount.openAIAPI.identifier
        })
    }

    func testCommittedManifestVerifiesFullBridgeProjectionWithoutSourceReads() throws {
        let manifest = makeManifest(status: .committed)
        let encoded = try XCTUnwrap(SecureStorageIdentityMigrationCoordinator.encodeManifest(manifest))
        XCTAssertEqual(
            encoded,
            #"{"attemptIdentifier":"123e4567-e89b-12d3-a456-426614174000","catalogIdentifiers":["AnthropicAPI","OpenAIAPI"],"status":"committed","version":2}"#
        )
        let source = MigrationTestBackend()
        let bridge = MigrationTestBackend(values: [
            SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount: encoded
        ])
        let state = TestIdentityMigrationStateStore(manifest: manifest)

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        // The committed projection classifies every cataloged account explicitly;
        // both accounts are absent from the bridge here, which is acceptable.
        XCTAssertEqual(report.records.map(\.state), [.absent, .absent])
        XCTAssertTrue(source.calls.isEmpty)
        // Reads touch the bridge service only: the manifest plus each account.
        XCTAssertEqual(
            bridge.calls.map(\.key),
            [SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount] + accounts.map(\.identifier)
        )
    }

    func testCommittedProjectionAccountReadFailureBlocksWithSpecificReason() throws {
        let manifest = makeManifest(status: .committed)
        let encoded = try XCTUnwrap(SecureStorageIdentityMigrationCoordinator.encodeManifest(manifest))
        let bridge = MigrationTestBackend(values: [
            SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount: encoded
        ])
        bridge.getErrors[SecureStorageAccount.openAIAPI.identifier] =
            KeychainService.KeychainError.interactionNotAllowed
        let source = MigrationTestBackend()
        let state = TestIdentityMigrationStateStore(manifest: manifest)

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.blockingState, .interactionRequired)
        XCTAssertTrue(report.blockedUpdateMessage?.contains("login Keychain is locked or unavailable") == true)
        XCTAssertTrue(source.calls.isEmpty)
    }

    func testResolverRejectsCommittedBridgeWithUnreadableAccountProjection() throws {
        let manifest = makeManifest(status: .committed)
        let encoded = try XCTUnwrap(SecureStorageIdentityMigrationCoordinator.encodeManifest(manifest))
        let bridge = MigrationTestBackend(values: [
            SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount: encoded
        ])
        bridge.getErrors[SecureStorageAccount.anthropicAPI.identifier] =
            KeychainService.KeychainError.authenticationFailed
        let resolver = SecureStorageIdentityMigrationCommittedBridgeResolver(
            accounts: accounts,
            stateStore: TestIdentityMigrationStateStore(manifest: manifest),
            bridgeStoreFactory: { _ in bridge }
        )

        XCTAssertThrowsError(try resolver.resolve()) { error in
            guard case KeychainService.KeychainError.authenticationFailed = error else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        }
    }

    func testCommittedProjectionReportsVerifiedRecordsForPresentValues() throws {
        let manifest = makeManifest(status: .committed)
        let encoded = try XCTUnwrap(SecureStorageIdentityMigrationCoordinator.encodeManifest(manifest))
        let bridge = MigrationTestBackend(values: [
            SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount: encoded,
            SecureStorageAccount.openAIAPI.identifier: "openai-secret"
        ])
        let state = TestIdentityMigrationStateStore(manifest: manifest)

        let report = makeCoordinator(
            source: MigrationTestBackend(),
            bridge: bridge,
            state: state
        ).prepareBridge()

        XCTAssertTrue(report.bridgeReady)
        XCTAssertEqual(report.records.map(\.state), [.verified, .absent])
        XCTAssertEqual(report.records.map(\.account), accounts)
    }

    func testCommittedProjectionRejectsMismatchedBridgeManifestWithoutDestructiveRecovery() throws {
        let manifest = makeManifest(status: .committed)
        let foreignManifest = SecureStorageIdentityMigrationManifest(
            version: SecureStorageIdentityMigrationManifest.currentVersion,
            status: .committed,
            attemptIdentifier: secondAttemptIdentifier,
            catalogIdentifiers: accounts.map(\.identifier).sorted()
        )
        let planted = try XCTUnwrap(SecureStorageIdentityMigrationCoordinator.encodeManifest(foreignManifest))
        let bridge = MigrationTestBackend(values: [
            SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount: planted
        ])
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])

        let report = makeCoordinator(
            source: source,
            bridge: bridge,
            state: TestIdentityMigrationStateStore(manifest: manifest)
        ).prepareBridge()

        // A bridge manifest from a different attempt must not activate, and the
        // mismatch must not trigger recovery writes against source or bridge.
        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.blockingState, .failed)
        XCTAssertTrue(source.calls.isEmpty)
        XCTAssertTrue(bridge.calls.allSatisfy { $0.operation == .get })
    }

    func testResolverRejectsPlantedPreparingManifestInBridgeSlot() throws {
        let manifest = makeManifest(status: .committed)
        let planted = try XCTUnwrap(
            SecureStorageIdentityMigrationCoordinator.encodeManifest(makeManifest(status: .preparing))
        )
        let bridge = MigrationTestBackend(values: [
            SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount: planted
        ])
        let resolver = SecureStorageIdentityMigrationCommittedBridgeResolver(
            accounts: accounts,
            stateStore: TestIdentityMigrationStateStore(manifest: manifest),
            bridgeStoreFactory: { _ in bridge }
        )

        XCTAssertThrowsError(try resolver.resolve()) { error in
            guard case SecureStorageIdentityMigrationActivationError.invalidBridgeManifest = error else {
                return XCTFail("Expected invalidBridgeManifest, got \(error)")
            }
        }
    }

    func testSuccessorPhaseGateBlocksEverythingExceptDisabled() {
        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.successorBlockedMessage(forPhase: .disabled))
        XCTAssertEqual(
            SecureStorageIdentityMigrationBootstrap.successorBlockedMessage(forPhase: .legacyPreparer),
            SecureStorageIdentityMigrationBootstrap.successorUnsupportedPhaseMessage
        )
        XCTAssertEqual(
            SecureStorageIdentityMigrationBootstrap.successorBlockedMessage(forPhase: nil),
            SecureStorageIdentityMigrationBootstrap.unrecognizedConfigurationMessage
        )
        XCTAssertTrue(
            SecureStorageIdentityMigrationBootstrap.successorMissingBridgeMessage.contains("previous RepoPrompt CE version")
        )
    }

    func testCommittedJournalWithoutMatchingBridgeManifestBlocks() {
        let manifest = makeManifest(status: .committed)

        let report = makeCoordinator(
            source: MigrationTestBackend(),
            bridge: MigrationTestBackend(),
            state: TestIdentityMigrationStateStore(manifest: manifest)
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.blockingState, .failed)
    }

    func testInvalidJournalBlocksWithoutReadingCredentials() {
        let invalidManifest = SecureStorageIdentityMigrationManifest(
            version: SecureStorageIdentityMigrationManifest.currentVersion,
            status: .committed,
            attemptIdentifier: "",
            catalogIdentifiers: accounts.map(\.identifier).sorted()
        )
        let source = MigrationTestBackend()
        let bridge = MigrationTestBackend()

        let report = makeCoordinator(
            source: source,
            bridge: bridge,
            state: TestIdentityMigrationStateStore(manifest: invalidManifest)
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertTrue(source.calls.isEmpty)
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testJournalAuthenticationFailureKeepsSpecificBlockedReason() {
        let source = MigrationTestBackend()
        let state = TestIdentityMigrationStateStore(loadError: KeychainService.KeychainError.authenticationFailed)

        let report = makeCoordinator(
            source: source,
            bridge: MigrationTestBackend(),
            state: state
        ).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.blockingState, .authenticationFailed)
        XCTAssertTrue(report.blockedUpdateMessage?.contains("Keychain authentication failed") == true)
        XCTAssertTrue(source.calls.isEmpty)
    }

    func testForgedJournalACLBlocksBeforeBridgeOrCredentialReads() {
        let source = MigrationTestBackend()
        let journalBackend = MigrationTestBackend()
        journalBackend.getErrors[KeychainSecureStorageIdentityMigrationStateStore.account] =
            KeychainACLValidationError.extraPrincipal
        var bridgeFactoryCalled = false
        let coordinator = makeCoordinator(
            source: source,
            state: KeychainSecureStorageIdentityMigrationStateStore(store: journalBackend)
        ) { _ in
            bridgeFactoryCalled = true
            return MigrationTestBackend()
        }

        let report = coordinator.prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertFalse(bridgeFactoryCalled)
        XCTAssertTrue(source.calls.isEmpty)
    }

    func testForgedBridgeManifestACLBlocksCommittedActivation() throws {
        let manifest = makeManifest(status: .committed)
        let encoded = try XCTUnwrap(SecureStorageIdentityMigrationCoordinator.encodeManifest(manifest))
        let bridge = MigrationTestBackend(values: [
            SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount: encoded
        ])
        bridge.getErrors[SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount] =
            KeychainACLValidationError.extraPrincipal
        let resolver = SecureStorageIdentityMigrationCommittedBridgeResolver(
            accounts: accounts,
            stateStore: TestIdentityMigrationStateStore(manifest: manifest),
            bridgeStoreFactory: { _ in bridge }
        )

        XCTAssertThrowsError(try resolver.resolve()) { error in
            XCTAssertEqual(error as? KeychainACLValidationError, .extraPrincipal)
        }
    }

    func testCommittedBridgeRemainsAuthorityWhenRuntimeCatalogAddsAccount() throws {
        let frozenMigrationAccounts: [SecureStorageAccount] = [.openAIAPI]
        let futureRuntimeAccount = SecureStorageAccount.anthropicAPI
        let manifest = SecureStorageIdentityMigrationManifest(
            version: SecureStorageIdentityMigrationManifest.currentVersion,
            status: .committed,
            attemptIdentifier: firstAttemptIdentifier,
            catalogIdentifiers: frozenMigrationAccounts.map(\.identifier)
        )
        let encoded = try XCTUnwrap(SecureStorageIdentityMigrationCoordinator.encodeManifest(manifest))
        let bridge = MigrationTestBackend(values: [
            SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount: encoded
        ])
        let resolution = try XCTUnwrap(SecureStorageIdentityMigrationCommittedBridgeResolver(
            accounts: frozenMigrationAccounts,
            stateStore: TestIdentityMigrationStateStore(manifest: manifest),
            bridgeStoreFactory: { _ in bridge }
        ).resolve())

        try resolution.store.save(
            "future-value",
            for: futureRuntimeAccount.identifier,
            accessMode: .nonInteractive(reason: .test)
        )

        XCTAssertEqual(bridge.value(for: futureRuntimeAccount.identifier), "future-value")
        XCTAssertEqual(resolution.manifest.catalogIdentifiers, [SecureStorageAccount.openAIAPI.identifier])
    }

    func testPreparingJournalPersistenceFailureLeavesBridgeUntouched() {
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()
        let state = TestIdentityMigrationStateStore(saveFailuresRemaining: 1)
        var factoryCallCount = 0
        let coordinator = makeCoordinator(source: source, state: state) { _ in
            factoryCallCount += 1
            return bridge
        }

        let report = coordinator.prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testCorruptJournalFailsClosedWithoutResetOrCredentialAccess() {
        let journalBackend = MigrationTestBackend(values: [
            KeychainSecureStorageIdentityMigrationStateStore.account: "not-json"
        ])
        let state = KeychainSecureStorageIdentityMigrationStateStore(store: journalBackend)
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        // A corrupt journal may be the only pointer to an already-committed bridge.
        // It must never be deleted or replaced by a fresh attempt from stale source data.
        XCTAssertFalse(report.bridgeReady)
        XCTAssertNotNil(report.blockedUpdateMessage)
        XCTAssertTrue(source.calls.isEmpty)
        XCTAssertTrue(bridge.calls.isEmpty)
        XCTAssertFalse(journalBackend.calls.contains { $0.operation == .delete })
        XCTAssertFalse(journalBackend.calls.contains { $0.operation == .save })
        XCTAssertFalse(journalBackend.calls.contains { $0.operation == .create })
        XCTAssertEqual(journalBackend.value(for: KeychainSecureStorageIdentityMigrationStateStore.account), "not-json")
    }

    func testFreshAttemptJournalWriteIsCreateOnlyAndCannotOverwrite() throws {
        // Keychain-backed store: an existing journal item must reject create-only writes.
        let journalBackend = MigrationTestBackend(values: [
            KeychainSecureStorageIdentityMigrationStateStore.account: "existing-journal"
        ])
        let store = KeychainSecureStorageIdentityMigrationStateStore(store: journalBackend)

        XCTAssertThrowsError(try store.create(makeManifest(status: .preparing))) { error in
            guard case KeychainService.KeychainError.duplicateItem = error else {
                return XCTFail("Expected duplicateItem, got \(error)")
            }
        }
        XCTAssertEqual(
            journalBackend.value(for: KeychainSecureStorageIdentityMigrationStateStore.account),
            "existing-journal"
        )

        // Coordinator: a journal that appears between load and create blocks the attempt.
        let state = TestIdentityMigrationStateStore(
            createError: KeychainService.KeychainError.duplicateItem
        )
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertTrue(state.savedManifests.isEmpty)
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testBridgeManifestPersistenceFailureLeavesJournalPreparing() {
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()
        bridge.createErrors[SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount] =
            KeychainService.KeychainError.unexpectedStatus(-1)
        let state = TestIdentityMigrationStateStore()

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(state.manifest?.status, .preparing)
        XCTAssertEqual(state.savedManifests.map(\.status), [.preparing])
    }

    func testBridgeManifestAuthenticationFailureKeepsSpecificBlockedReason() {
        let source = MigrationTestBackend(values: [SecureStorageAccount.openAIAPI.identifier: "secret"])
        let bridge = MigrationTestBackend()
        bridge.createErrors[SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount] =
            KeychainService.KeychainError.authenticationFailed
        let state = TestIdentityMigrationStateStore()

        let report = makeCoordinator(source: source, bridge: bridge, state: state).prepareBridge()

        XCTAssertFalse(report.bridgeReady)
        XCTAssertEqual(report.blockingState, .authenticationFailed)
        XCTAssertTrue(report.blockedUpdateMessage?.contains("Keychain authentication failed") == true)
        XCTAssertEqual(state.manifest?.status, .preparing)
    }

    func testAnchorValidationAcceptsOnlyExecutableRegularFileInsideResources() throws {
        let fixture = try makeAnchorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            SecureStorageIdentityMigrationBootstrap.validatedAnchorURL(
                relativePath: "IdentityMigration/anchor",
                resourceURL: fixture.resources
            ),
            fixture.anchor.standardizedFileURL
        )
    }

    func testConfiguredPhaseAcceptsOnlyKnownLiteralValues() {
        XCTAssertEqual(SecureStorageIdentityMigrationBootstrap.configuredPhase(from: "disabled"), .disabled)
        XCTAssertEqual(
            SecureStorageIdentityMigrationBootstrap.configuredPhase(from: "legacy-preparer"),
            .legacyPreparer
        )
        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.configuredPhase(from: "legacy_preparer"))
        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.configuredPhase(from: nil))
        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.configuredPhase(from: 1))
    }

    func testPreparerCatalogGateRejectsDriftFromFrozenMigrationCatalog() {
        XCTAssertTrue(SecureStorageIdentityMigrationBootstrap.preparerCatalogMatchesFrozenCatalog(
            currentAccounts: [.openAIAPI],
            migrationAccounts: [.openAIAPI]
        ))
        XCTAssertFalse(SecureStorageIdentityMigrationBootstrap.preparerCatalogMatchesFrozenCatalog(
            currentAccounts: [.openAIAPI, .anthropicAPI],
            migrationAccounts: [.openAIAPI]
        ))
    }

    func testAnchorValidationRejectsSymlinkAndPathEscape() throws {
        let fixture = try makeAnchorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let symlink = fixture.resources.appendingPathComponent("IdentityMigration/anchor-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.anchor)

        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.validatedAnchorURL(
            relativePath: "IdentityMigration/anchor-link",
            resourceURL: fixture.resources
        ))
        XCTAssertNil(SecureStorageIdentityMigrationBootstrap.validatedAnchorURL(
            relativePath: "../outside-anchor",
            resourceURL: fixture.resources
        ))
    }

    private func makeManifest(
        status: SecureStorageIdentityMigrationManifest.Status
    ) -> SecureStorageIdentityMigrationManifest {
        SecureStorageIdentityMigrationManifest(
            version: SecureStorageIdentityMigrationManifest.currentVersion,
            status: status,
            attemptIdentifier: firstAttemptIdentifier,
            catalogIdentifiers: accounts.map(\.identifier).sorted()
        )
    }

    private func makeCoordinator(
        source: SecureKeyValueStorageBackend,
        bridge: SecureKeyValueStorageBackend,
        state: SecureStorageIdentityMigrationStateStore
    ) -> SecureStorageIdentityMigrationCoordinator {
        makeCoordinator(source: source, state: state) { _ in bridge }
    }

    private func makeCoordinator(
        source: SecureKeyValueStorageBackend,
        state: SecureStorageIdentityMigrationStateStore,
        attemptIdentifierGenerator: @escaping SecureStorageIdentityMigrationCoordinator.AttemptIdentifierGenerator = {
            UUID().uuidString.lowercased()
        },
        bridgeFactory: @escaping SecureStorageIdentityMigrationCoordinator.BridgeStoreFactory
    ) -> SecureStorageIdentityMigrationCoordinator {
        SecureStorageIdentityMigrationCoordinator(
            accounts: accounts,
            sourceStore: source,
            bridgeStoreFactory: bridgeFactory,
            stateStore: state,
            attemptIdentifierGenerator: attemptIdentifierGenerator
        )
    }

    private func makeAnchorFixture() throws -> (root: URL, resources: URL, anchor: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-identity-migration-tests-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("Resources")
        let anchorDirectory = resources.appendingPathComponent("IdentityMigration")
        try FileManager.default.createDirectory(at: anchorDirectory, withIntermediateDirectories: true)
        let anchor = anchorDirectory.appendingPathComponent("anchor")
        try Data("anchor".utf8).write(to: anchor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: anchor.path)
        return (root, resources, anchor)
    }
}

private enum TestStateError: Error {
    case failed
}

private final class TestIdentityMigrationStateStore: SecureStorageIdentityMigrationStateStore {
    private(set) var manifest: SecureStorageIdentityMigrationManifest?
    private(set) var savedManifests: [SecureStorageIdentityMigrationManifest] = []
    private(set) var createdManifests: [SecureStorageIdentityMigrationManifest] = []
    var loadError: Error?
    var createError: Error?
    var saveFailuresRemaining: Int

    init(
        manifest: SecureStorageIdentityMigrationManifest? = nil,
        loadError: Error? = nil,
        createError: Error? = nil,
        saveFailuresRemaining: Int = 0
    ) {
        self.manifest = manifest
        self.loadError = loadError
        self.createError = createError
        self.saveFailuresRemaining = saveFailuresRemaining
    }

    func load() throws -> SecureStorageIdentityMigrationManifest? {
        if let loadError { throw loadError }
        return manifest
    }

    func create(_ manifest: SecureStorageIdentityMigrationManifest) throws {
        if let createError { throw createError }
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw TestStateError.failed
        }
        guard self.manifest == nil else {
            throw KeychainService.KeychainError.duplicateItem
        }
        createdManifests.append(manifest)
        savedManifests.append(manifest)
        self.manifest = manifest
    }

    func save(_ manifest: SecureStorageIdentityMigrationManifest) throws {
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw TestStateError.failed
        }
        savedManifests.append(manifest)
        self.manifest = manifest
    }

    /// Test-only stand-in for out-of-band journal deletion. Production code has
    /// no destructive journal reset API.
    func simulateJournalLoss() {
        manifest = nil
    }
}

private final class MigrationTestBackend: SecureKeyValueStorageBackend, @unchecked Sendable {
    enum Operation: Equatable {
        case get
        case save
        case create
        case delete
    }

    struct Call: Equatable {
        let operation: Operation
        let key: String
        let accessMode: KeychainAccessMode
    }

    let persistsValuesAcrossLaunches = true
    var getErrors: [String: Error] = [:]
    var saveErrors: [String: Error] = [:]
    var createErrors: [String: Error] = [:]
    var deleteErrors: [String: Error] = [:]

    private var values: [String: String]
    private(set) var calls: [Call] = []
    private let lock = NSRecursiveLock()

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(_ value: String, for key: String, accessMode: KeychainAccessMode) throws {
        try withLock {
            calls.append(Call(operation: .save, key: key, accessMode: accessMode))
            if let error = saveErrors[key] { throw error }
            values[key] = value
        }
    }

    func create(_ value: String, for key: String, accessMode: KeychainAccessMode) throws {
        try withLock {
            calls.append(Call(operation: .create, key: key, accessMode: accessMode))
            if let error = createErrors[key] { throw error }
            guard values[key] == nil else { throw KeychainService.KeychainError.duplicateItem }
            values[key] = value
        }
    }

    func get(for key: String, accessMode: KeychainAccessMode) throws -> String {
        try withLock {
            calls.append(Call(operation: .get, key: key, accessMode: accessMode))
            if let error = getErrors[key] { throw error }
            guard let value = values[key] else { throw KeychainService.KeychainError.itemNotFound }
            return value
        }
    }

    func delete(for key: String, accessMode: KeychainAccessMode) throws {
        try withLock {
            calls.append(Call(operation: .delete, key: key, accessMode: accessMode))
            if let error = deleteErrors[key] { throw error }
            values.removeValue(forKey: key)
        }
    }

    func setValue(_ value: String?, for key: String) {
        withLock { values[key] = value }
    }

    func value(for key: String) -> String? {
        withLock { values[key] }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
