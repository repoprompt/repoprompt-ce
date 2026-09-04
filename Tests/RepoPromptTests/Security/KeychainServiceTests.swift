import Foundation
@testable import RepoPromptApp
import Security
import XCTest

final class KeychainServiceTests: XCTestCase {
    func testNoninteractiveReadAddsUISkip() throws {
        let fake = FakeSecItemClient { _, result in
            result?.pointee = Data("stored-value".utf8) as NSData
            return errSecSuccess
        }
        let service = makeService(secItemClient: fake)

        let value = try service.get(
            for: "api-key",
            accessMode: .nonInteractive(reason: .test)
        )

        XCTAssertEqual(value, "stored-value")
        let query = try XCTUnwrap(fake.copyQueries.first)
        XCTAssertEqual(query.stringValue(for: kSecUseAuthenticationUI), kSecUseAuthenticationUISkip as String)
    }

    func testInteractiveReadDoesNotAddUISkip() throws {
        let fake = FakeSecItemClient { _, result in
            result?.pointee = Data("stored-value".utf8) as NSData
            return errSecSuccess
        }
        let service = makeService(secItemClient: fake)

        XCTAssertEqual(try service.get(for: "api-key", accessMode: .interactive), "stored-value")
        let query = try XCTUnwrap(fake.copyQueries.first)
        XCTAssertNil(query.stringValue(for: kSecUseAuthenticationUI))
    }

    func testReadMapsSecurityStatusesToSanitizedErrors() {
        let scenarios: [(OSStatus, KeychainService.KeychainError)] = [
            (errSecItemNotFound, .itemNotFound),
            (errSecInteractionNotAllowed, .interactionNotAllowed),
            (errSecUserCanceled, .userInteractionCancelled),
            (errSecAuthFailed, .authenticationFailed),
            (OSStatus(-12345), .unexpectedStatus(-12345))
        ]

        for (status, expectedError) in scenarios {
            let service = makeService(secItemClient: FakeSecItemClient { _, _ in status })
            XCTAssertThrowsError(
                try service.get(for: "api-key", accessMode: .nonInteractive(reason: .test)),
                "status=\(status)"
            ) { error in
                XCTAssertEqual(error as? KeychainService.KeychainError, expectedError, "status=\(status)")
            }
        }
    }

    func testCanonicalMissingThrowsItemNotFoundWithoutFallback() throws {
        let canonicalService = "test.canonical.missing"
        let fake = FakeSecItemClient { _, _ in
            errSecItemNotFound
        }
        let service = makeService(serviceName: canonicalService, secItemClient: fake)

        XCTAssertThrowsError(
            try service.get(for: "api-key", accessMode: .nonInteractive(reason: .test))
        ) { error in
            XCTAssertEqual(error as? KeychainService.KeychainError, .itemNotFound)
        }

        XCTAssertEqual(fake.copyQueries.map { $0.stringValue(for: kSecAttrService) }, [canonicalService])
    }

    func testCanonicalInteractionDenialFailsClosedWithoutFallback() throws {
        let canonicalService = "test.canonical.denied"
        let fake = FakeSecItemClient { query, result in
            switch query.stringValue(for: kSecAttrService) {
            case canonicalService:
                return errSecInteractionNotAllowed
            case "test.noncanonical.denied":
                result?.pointee = Data("noncanonical-value".utf8) as NSData
                return errSecSuccess
            default:
                return errSecItemNotFound
            }
        }
        let service = makeService(serviceName: canonicalService, secItemClient: fake)

        XCTAssertThrowsError(
            try service.get(for: "api-key", accessMode: .nonInteractive(reason: .test))
        ) { error in
            XCTAssertEqual(error as? KeychainService.KeychainError, .interactionNotAllowed)
        }

        XCTAssertEqual(fake.copyQueries.map { $0.stringValue(for: kSecAttrService) }, [canonicalService])
    }

    func testDeleteDeletesOnlyCanonicalService() throws {
        let canonicalService = "test.canonical.delete"
        let fake = FakeSecItemClient(
            copyHandler: { _, _ in errSecItemNotFound },
            deleteHandler: { _ in errSecSuccess }
        )
        let service = makeService(serviceName: canonicalService, secItemClient: fake)

        try service.delete(for: "api-key", accessMode: .nonInteractive(reason: .test))

        XCTAssertEqual(fake.deleteQueries.map { $0.stringValue(for: kSecAttrService) }, [canonicalService])
        let deleteQuery = try XCTUnwrap(fake.deleteQueries.first)
        XCTAssertEqual(deleteQuery.stringValue(for: kSecUseAuthenticationUI), kSecUseAuthenticationUISkip as String)
    }

    func testSaveUpdatesCanonicalNoninteractiveItemWithoutAddingWhenPresent() throws {
        let fake = FakeSecItemClient(
            copyHandler: { _, _ in errSecItemNotFound },
            updateHandler: { _, _ in errSecSuccess }
        )
        let service = makeService(serviceName: KeychainService.officialV2ServiceName, secItemClient: fake)

        try service.save("stored-value", for: "api-key", accessMode: .nonInteractive(reason: .test))

        XCTAssertEqual(fake.operationLog, ["update"])
        XCTAssertTrue(fake.addQueries.isEmpty)
        let updateQuery = try XCTUnwrap(fake.updateQueries.first)
        XCTAssertEqual(updateQuery.stringValue(for: kSecClass), kSecClassGenericPassword as String)
        XCTAssertEqual(updateQuery.stringValue(for: kSecAttrService), KeychainService.officialV2ServiceName)
        XCTAssertEqual(updateQuery.stringValue(for: kSecAttrAccount), "api-key")
        XCTAssertEqual(updateQuery.stringValue(for: kSecUseAuthenticationUI), kSecUseAuthenticationUISkip as String)
        let updateAttributes = try XCTUnwrap(fake.updateAttributes.first)
        XCTAssertEqual(updateAttributes.dataValue(for: kSecValueData), Data("stored-value".utf8))
    }

    func testSaveAddsCanonicalNoninteractiveItemAfterMissingUpdate() throws {
        let fake = FakeSecItemClient(
            copyHandler: { _, _ in errSecItemNotFound },
            addHandler: { _, _ in errSecSuccess },
            updateHandler: { _, _ in errSecItemNotFound }
        )
        let service = makeService(serviceName: KeychainService.officialV2ServiceName, secItemClient: fake)

        try service.save("stored-value", for: "api-key", accessMode: .nonInteractive(reason: .test))

        XCTAssertEqual(fake.operationLog, ["update", "add"])
        let updateQuery = try XCTUnwrap(fake.updateQueries.first)
        XCTAssertEqual(updateQuery.stringValue(for: kSecAttrService), KeychainService.officialV2ServiceName)
        XCTAssertEqual(updateQuery.stringValue(for: kSecAttrAccount), "api-key")
        XCTAssertEqual(updateQuery.stringValue(for: kSecUseAuthenticationUI), kSecUseAuthenticationUISkip as String)
        let addQuery = try XCTUnwrap(fake.addQueries.first)
        XCTAssertEqual(addQuery.stringValue(for: kSecClass), kSecClassGenericPassword as String)
        XCTAssertEqual(addQuery.stringValue(for: kSecAttrService), KeychainService.officialV2ServiceName)
        XCTAssertEqual(addQuery.stringValue(for: kSecAttrAccount), "api-key")
        XCTAssertEqual(addQuery.stringValue(for: kSecUseAuthenticationUI), kSecUseAuthenticationUISkip as String)
        XCTAssertEqual(addQuery.dataValue(for: kSecValueData), Data("stored-value".utf8))
        XCTAssertNil(addQuery.stringValue(for: kSecAttrAccessible))
        XCTAssertNil(addQuery.boolValue(for: kSecAttrSynchronizable))
    }

    func testSaveAddsCreationAttributesOnlyWhenCreatingItem() throws {
        let fake = FakeSecItemClient(
            copyHandler: { _, _ in errSecItemNotFound },
            addHandler: { _, _ in errSecSuccess },
            updateHandler: { _, _ in errSecItemNotFound }
        )
        let provider = FakeItemCreationAttributeProvider()
        let service = KeychainService(
            serviceName: KeychainService.identityMigrationBridgeServiceNamePrefix,
            secItemClient: fake,
            itemCreationAttributeProvider: provider
        )

        try service.save("stored-value", for: "api-key", accessMode: .nonInteractive(reason: .test))

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(fake.addQueries.first?.stringValue(for: kSecAttrAccess), "test-access-policy")
        XCTAssertNil(fake.addQueries.first?.stringValue(for: kSecAttrAccessible))
        XCTAssertNil(fake.addQueries.first?.boolValue(for: kSecAttrSynchronizable))
        XCTAssertNil(fake.updateAttributes.first?.stringValue(for: kSecAttrAccess))
    }

    func testCreateUsesAttemptScopedServiceIdentityWithoutGenericMarker() throws {
        let attemptIdentifier = "123e4567-e89b-12d3-a456-426614174000"
        let serviceName = try XCTUnwrap(
            KeychainService.identityMigrationBridgeServiceName(for: attemptIdentifier)
        )
        let fake = FakeSecItemClient(
            copyHandler: { _, _ in errSecItemNotFound },
            addHandler: { _, _ in errSecSuccess }
        )
        let provider = FakeItemCreationAttributeProvider()
        let service = KeychainService(
            serviceName: serviceName,
            secItemClient: fake,
            itemCreationAttributeProvider: provider
        )

        try service.create("stored-value", for: "api-key", accessMode: .nonInteractive(reason: .test))

        XCTAssertEqual(fake.operationLog, ["add"])
        XCTAssertTrue(fake.updateQueries.isEmpty)
        let addQuery = try XCTUnwrap(fake.addQueries.first)
        XCTAssertEqual(addQuery.stringValue(for: kSecAttrService), serviceName)
        XCTAssertNil(addQuery.dataValue(for: kSecAttrGeneric))
        XCTAssertEqual(addQuery.stringValue(for: kSecAttrAccess), "test-access-policy")
        XCTAssertNil(addQuery.stringValue(for: kSecAttrAccessible))
        XCTAssertNil(addQuery.boolValue(for: kSecAttrSynchronizable))
    }

    func testAttemptScopedServiceIdentityRequiresCanonicalUUIDAndIsDistinct() throws {
        let first = "123e4567-e89b-12d3-a456-426614174000"
        let second = "123e4567-e89b-12d3-a456-426614174001"
        let firstService = try XCTUnwrap(KeychainService.identityMigrationBridgeServiceName(for: first))
        let secondService = try XCTUnwrap(KeychainService.identityMigrationBridgeServiceName(for: second))

        XCTAssertNotEqual(firstService, secondService)
        XCTAssertTrue(firstService.hasSuffix(first))
        XCTAssertNil(KeychainService.identityMigrationBridgeServiceName(for: first.uppercased()))
        XCTAssertNil(KeychainService.identityMigrationBridgeServiceName(for: "attempt-123"))
    }

    func testACLPrincipalValidationRequiresExactDesignatedRequirements() throws {
        let legacyRequirement = Data("legacy-requirement".utf8)
        let successorRequirement = Data("successor-requirement".utf8)
        let expected = [legacyRequirement, successorRequirement]

        XCTAssertNoThrow(try ClassicKeychainACLValidator.validate(
            principals: [.requirement(successorRequirement), .requirement(legacyRequirement)],
            expected: expected
        ))
        XCTAssertThrowsError(try ClassicKeychainACLValidator.validate(
            principals: [.requirement(legacyRequirement)],
            expected: expected
        )) { error in
            XCTAssertEqual(error as? KeychainACLValidationError, .missingPrincipal)
        }
        XCTAssertThrowsError(try ClassicKeychainACLValidator.validate(
            principals: [.requirement(legacyRequirement), .wildcard],
            expected: expected
        )) { error in
            XCTAssertEqual(error as? KeychainACLValidationError, .wildcardPrincipal)
        }
        XCTAssertThrowsError(try ClassicKeychainACLValidator.validate(
            principals: [.requirement(legacyRequirement), .requirement(Data("attacker".utf8))],
            expected: expected
        )) { error in
            XCTAssertEqual(error as? KeychainACLValidationError, .extraPrincipal)
        }
    }

    func testReadRejectsForgedItemACLBeforeReturningCredentialValue() {
        let fake = FakeSecItemClient { query, result in
            if query.boolValue(for: kSecReturnRef) == true {
                result?.pointee = NSObject()
            } else {
                result?.pointee = Data("attacker-value".utf8) as NSData
            }
            return errSecSuccess
        }
        let validator = FakeItemAccessValidator(error: KeychainACLValidationError.extraPrincipal)
        let service = KeychainService(
            serviceName: KeychainService.identityMigrationLegacyStateServiceName,
            secItemClient: fake,
            itemAccessValidator: validator,
            itemAccessProvider: FakeSecKeychainItemAccessProvider()
        )

        XCTAssertThrowsError(
            try service.get(for: "migration-journal", accessMode: .nonInteractive(reason: .test))
        ) { error in
            XCTAssertEqual(error as? KeychainACLValidationError, .extraPrincipal)
        }
        XCTAssertEqual(fake.copyQueries.count, 1)
        XCTAssertEqual(fake.copyQueries.first?.boolValue(for: kSecReturnRef), true)
    }

    func testCopiedBridgeManifestACLIsValidatedBeforeReuse() {
        let fake = FakeSecItemClient { _, result in
            result?.pointee = NSObject()
            return errSecSuccess
        }
        let validator = FakeItemAccessValidator(error: KeychainACLValidationError.extraPrincipal)
        let provider = ExistingKeychainItemAccessAttributeProvider(
            serviceName: "attempt-service",
            account: SecureStorageIdentityMigrationCoordinator.bridgeManifestAccount,
            accessValidator: validator,
            itemAccessProvider: FakeSecKeychainItemAccessProvider(),
            secItemClient: fake
        )

        XCTAssertThrowsError(try provider.attributesForNewItem()) { error in
            XCTAssertEqual(error as? KeychainACLValidationError, .extraPrincipal)
        }
        XCTAssertEqual(validator.validationCount, 1)
    }

    func testPersistentServiceNamesAreIsolatedAndLegacyIsRepairOnly() throws {
        let fingerprintA = String(repeating: "A", count: 64)
        let fingerprintB = String(repeating: "B", count: 64)
        let names = Set([
            KeychainService.legacyCanonicalServiceName,
            KeychainService.officialV2ServiceName,
            KeychainService.identityMigrationBridgeServiceNamePrefix,
            KeychainService.identityMigrationLegacyStateServiceName,
            KeychainService.localSelfSignedServiceName(fingerprint: fingerprintA, generation: 1),
            KeychainService.localSelfSignedServiceName(fingerprint: fingerprintA, generation: 2),
            KeychainService.localSelfSignedServiceName(fingerprint: fingerprintB, generation: 1),
            KeychainService.debugServiceName
        ])
        XCTAssertEqual(names.count, 8)

        let fake = FakeSecItemClient { _, _ in errSecItemNotFound }
        let legacy = KeychainService.legacyRepairSource(secItemClient: fake)
        XCTAssertThrowsError(try legacy.get(for: "api-key", accessMode: .nonInteractive(reason: .test)))
        XCTAssertEqual(
            fake.copyQueries.map { $0.stringValue(for: kSecAttrService) },
            [KeychainService.legacyCanonicalServiceName]
        )
    }

    private func makeService(
        serviceName: String = "test.canonical.service",
        secItemClient: SecItemClient
    ) -> KeychainService {
        KeychainService(
            serviceName: serviceName,
            secItemClient: secItemClient
        )
    }
}

private final class FakeItemCreationAttributeProvider: KeychainItemCreationAttributeProvider {
    private(set) var callCount = 0

    func attributesForNewItem() throws -> [String: Any] {
        callCount += 1
        return [kSecAttrAccess as String: "test-access-policy"]
    }
}

private final class FakeItemAccessValidator: KeychainItemAccessValidator {
    private let error: Error?
    private(set) var validationCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func validate(_: AnyObject) throws {
        validationCount += 1
        if let error { throw error }
    }
}

private struct FakeSecKeychainItemAccessProvider: SecKeychainItemAccessProvider {
    func copyAccess(from _: AnyObject) throws -> AnyObject {
        NSObject()
    }
}

private final class FakeSecItemClient: SecItemClient {
    typealias CopyHandler = (CapturedQuery, UnsafeMutablePointer<AnyObject?>?) -> OSStatus

    private let copyHandler: CopyHandler
    private let addHandler: (CapturedQuery, UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    private let updateHandler: (CapturedQuery, CapturedQuery) -> OSStatus
    private let deleteHandler: (CapturedQuery) -> OSStatus

    private(set) var copyQueries: [CapturedQuery] = []
    private(set) var addQueries: [CapturedQuery] = []
    private(set) var updateQueries: [CapturedQuery] = []
    private(set) var updateAttributes: [CapturedQuery] = []
    private(set) var deleteQueries: [CapturedQuery] = []
    private(set) var operationLog: [String] = []

    init(
        copyHandler: @escaping CopyHandler,
        addHandler: @escaping (CapturedQuery, UnsafeMutablePointer<AnyObject?>?) -> OSStatus = { _, _ in errSecSuccess },
        updateHandler: @escaping (CapturedQuery, CapturedQuery) -> OSStatus = { _, _ in errSecItemNotFound },
        deleteHandler: @escaping (CapturedQuery) -> OSStatus = { _ in errSecSuccess }
    ) {
        self.copyHandler = copyHandler
        self.addHandler = addHandler
        self.updateHandler = updateHandler
        self.deleteHandler = deleteHandler
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        let captured = CapturedQuery(query)
        copyQueries.append(captured)
        return copyHandler(captured, result)
    }

    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        let captured = CapturedQuery(query)
        addQueries.append(captured)
        operationLog.append("add")
        return addHandler(captured, result)
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        let capturedQuery = CapturedQuery(query)
        let capturedAttributes = CapturedQuery(attributes)
        updateQueries.append(capturedQuery)
        updateAttributes.append(capturedAttributes)
        operationLog.append("update")
        return updateHandler(capturedQuery, capturedAttributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        let captured = CapturedQuery(query)
        deleteQueries.append(captured)
        return deleteHandler(captured)
    }
}

private struct CapturedQuery {
    private let dictionary: NSDictionary

    init(_ query: CFDictionary) {
        dictionary = query as NSDictionary
    }

    func stringValue(for key: CFString) -> String? {
        if let value = dictionary[key as String] as? String {
            return value
        }
        if let value = dictionary[key] as? String {
            return value
        }
        return nil
    }

    func dataValue(for key: CFString) -> Data? {
        if let value = dictionary[key as String] as? Data {
            return value
        }
        if let value = dictionary[key as String] as? NSData {
            return value as Data
        }
        if let value = dictionary[key] as? Data {
            return value
        }
        if let value = dictionary[key] as? NSData {
            return value as Data
        }
        return nil
    }

    func boolValue(for key: CFString) -> Bool? {
        if let value = dictionary[key as String] as? Bool {
            return value
        }
        if let value = dictionary[key] as? Bool {
            return value
        }
        return nil
    }
}
