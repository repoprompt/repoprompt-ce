import Foundation
@testable import RepoPrompt
import XCTest

final class SecureStorageRepairServiceTests: XCTestCase {
    func testScanClassifiesKnownAccountsNoninteractivelyAndContinuesAfterFailures() async {
        let accounts: [SecureStorageAccount] = [
            .anthropicAPI,
            .openAIAPI,
            .geminiAPI,
            .openRouterAPI,
            .ollamaURL,
            .azureAPI,
            .deepSeekAPI
        ]
        let legacy = TestSecureStorageBackend(values: [
            .openAIAPI: "legacy-openai",
            .openRouterAPI: "same",
            .ollamaURL: "legacy-url"
        ])
        legacy.getErrors[.geminiAPI] = .interactionNotAllowed
        legacy.getErrors[.azureAPI] = .userInteractionCancelled
        legacy.getErrors[.deepSeekAPI] = .authenticationFailed
        let target = TestSecureStorageBackend(values: [
            .openRouterAPI: "same",
            .ollamaURL: "new-url"
        ])
        let service = SecureStorageRepairService(accounts: accounts, legacyStore: legacy, targetStore: target)

        let records = await service.scan()

        XCTAssertEqual(records.map(\.state), [
            .absent,
            .importable,
            .interactionRequired,
            .imported,
            .conflict,
            .cancelled,
            .failed(.authenticationFailed)
        ])
        XCTAssertEqual(records.map(\.targetVerified), [false, false, false, true, false, false, false])
        XCTAssertTrue(legacy.calls.allSatisfy { $0.accessMode == .nonInteractive(reason: .backgroundAvailabilityCheck) })
        XCTAssertTrue(target.calls.allSatisfy { $0.accessMode == .nonInteractive(reason: .backgroundAvailabilityCheck) })
    }

    func testImportWritesOneAccountVerifiesTargetAndKeepsLegacy() async {
        let legacy = TestSecureStorageBackend(values: [.anthropicAPI: "legacy-secret"])
        let target = TestSecureStorageBackend()
        let service = SecureStorageRepairService(accounts: [.anthropicAPI], legacyStore: legacy, targetStore: target)

        let result = await service.importAccount(.anthropicAPI)

        XCTAssertEqual(result, SecureStorageRepairRecord(account: .anthropicAPI, state: .imported, targetVerified: true))
        XCTAssertEqual(target.value(for: .anthropicAPI), "legacy-secret")
        XCTAssertEqual(legacy.value(for: .anthropicAPI), "legacy-secret")
        XCTAssertEqual(target.calls.map(\.operation), [.get, .save, .get])
        XCTAssertTrue((legacy.calls + target.calls).allSatisfy { $0.accessMode == .interactive })
    }

    func testEqualTargetIsAlreadyImportedWithoutWrite() async {
        let legacy = TestSecureStorageBackend(values: [.openAIAPI: "same"])
        let target = TestSecureStorageBackend(values: [.openAIAPI: "same"])
        let service = SecureStorageRepairService(accounts: [.openAIAPI], legacyStore: legacy, targetStore: target)

        let result = await service.importAccount(.openAIAPI)

        XCTAssertEqual(result.state, .imported)
        XCTAssertEqual(target.calls.map(\.operation), [.get])
    }

    func testConflictPreservesTargetUntilExplicitReplacement() async {
        let legacy = TestSecureStorageBackend(values: [.geminiAPI: "legacy"])
        let target = TestSecureStorageBackend(values: [.geminiAPI: "current-v2"])
        let service = SecureStorageRepairService(accounts: [.geminiAPI], legacyStore: legacy, targetStore: target)

        let preserved = await service.importAccount(.geminiAPI)
        XCTAssertEqual(preserved.state, .conflict)
        XCTAssertEqual(target.value(for: .geminiAPI), "current-v2")
        XCTAssertFalse(target.calls.contains { $0.operation == .save })

        let replaced = await service.importAccount(.geminiAPI, resolution: .replaceTarget)
        XCTAssertEqual(replaced.state, .imported)
        XCTAssertEqual(target.value(for: .geminiAPI), "legacy")
    }

    func testImportFailsWhenPostWriteVerificationDiffers() async {
        let legacy = TestSecureStorageBackend(values: [.openRouterAPI: "legacy"])
        let target = TestSecureStorageBackend()
        target.savedValueOverride = "corrupt"
        let service = SecureStorageRepairService(accounts: [.openRouterAPI], legacyStore: legacy, targetStore: target)

        let result = await service.importAccount(.openRouterAPI)

        XCTAssertEqual(result.state, .failed(.verificationFailed))
        XCTAssertEqual(legacy.value(for: .openRouterAPI), "legacy")
    }

    func testLegacyDeletionRequiresConfirmationAndVerifiedEquality() async {
        let legacy = TestSecureStorageBackend(values: [.azureAPI: "same"])
        let target = TestSecureStorageBackend(values: [.azureAPI: "same"])
        let service = SecureStorageRepairService(accounts: [.azureAPI], legacyStore: legacy, targetStore: target)

        let unconfirmed = await service.deleteLegacy(.azureAPI, confirmed: false)
        XCTAssertEqual(unconfirmed.state, .failed(.confirmationRequired))
        XCTAssertEqual(legacy.value(for: .azureAPI), "same")

        let deleted = await service.deleteLegacy(.azureAPI, confirmed: true)
        XCTAssertEqual(deleted, SecureStorageRepairRecord(account: .azureAPI, state: .absent, targetVerified: true))
        XCTAssertNil(legacy.value(for: .azureAPI))
        XCTAssertEqual(target.value(for: .azureAPI), "same")
    }

    func testLegacyDeletionRefusesDifferingTarget() async {
        let legacy = TestSecureStorageBackend(values: [.deepSeekAPI: "legacy"])
        let target = TestSecureStorageBackend(values: [.deepSeekAPI: "v2"])
        let service = SecureStorageRepairService(accounts: [.deepSeekAPI], legacyStore: legacy, targetStore: target)

        let result = await service.deleteLegacy(.deepSeekAPI, confirmed: true)

        XCTAssertEqual(result.state, .conflict)
        XCTAssertEqual(legacy.value(for: .deepSeekAPI), "legacy")
        XCTAssertFalse(legacy.calls.contains { $0.operation == .delete })
    }
}
