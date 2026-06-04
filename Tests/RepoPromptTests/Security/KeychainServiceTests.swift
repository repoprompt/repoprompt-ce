import Foundation
@testable import RepoPrompt
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
        let service = makeService(serviceName: KeychainService.canonicalServiceName, secItemClient: fake)

        try service.save("stored-value", for: "api-key", accessMode: .nonInteractive(reason: .test))

        XCTAssertEqual(fake.operationLog, ["update"])
        XCTAssertTrue(fake.addQueries.isEmpty)
        let updateQuery = try XCTUnwrap(fake.updateQueries.first)
        XCTAssertEqual(updateQuery.stringValue(for: kSecClass), kSecClassGenericPassword as String)
        XCTAssertEqual(updateQuery.stringValue(for: kSecAttrService), KeychainService.canonicalServiceName)
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
        let service = makeService(serviceName: KeychainService.canonicalServiceName, secItemClient: fake)

        try service.save("stored-value", for: "api-key", accessMode: .nonInteractive(reason: .test))

        XCTAssertEqual(fake.operationLog, ["update", "add"])
        let updateQuery = try XCTUnwrap(fake.updateQueries.first)
        XCTAssertEqual(updateQuery.stringValue(for: kSecAttrService), KeychainService.canonicalServiceName)
        XCTAssertEqual(updateQuery.stringValue(for: kSecAttrAccount), "api-key")
        XCTAssertEqual(updateQuery.stringValue(for: kSecUseAuthenticationUI), kSecUseAuthenticationUISkip as String)
        let addQuery = try XCTUnwrap(fake.addQueries.first)
        XCTAssertEqual(addQuery.stringValue(for: kSecClass), kSecClassGenericPassword as String)
        XCTAssertEqual(addQuery.stringValue(for: kSecAttrService), KeychainService.canonicalServiceName)
        XCTAssertEqual(addQuery.stringValue(for: kSecAttrAccount), "api-key")
        XCTAssertEqual(addQuery.stringValue(for: kSecUseAuthenticationUI), kSecUseAuthenticationUISkip as String)
        XCTAssertEqual(addQuery.dataValue(for: kSecValueData), Data("stored-value".utf8))
        XCTAssertEqual(addQuery.stringValue(for: kSecAttrAccessible), kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(addQuery.boolValue(for: kSecAttrSynchronizable), false)
    }

    func testPersistentBackendPolicySeparatesSigningModes() {
        XCTAssertEqual(PersistentKeychainRuntimePolicy.backendKind(signingModeMarker: "developer-id"), .canonical)
        XCTAssertEqual(PersistentKeychainRuntimePolicy.backendKind(signingModeMarker: " LOCAL-SELF-SIGNED "), .localSelfSigned)
        XCTAssertEqual(PersistentKeychainRuntimePolicy.backendKind(signingModeMarker: "release-candidate-adhoc"), .canonical)
        XCTAssertEqual(PersistentKeychainRuntimePolicy.backendKind(signingModeMarker: nil), .canonical)
        XCTAssertNotEqual(KeychainService.canonicalServiceName, KeychainService.localSelfSignedServiceName)
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
