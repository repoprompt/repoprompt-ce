import Foundation
@testable import RepoPrompt
import XCTest

final class MCPRemoteBearerTokenStoreTests: XCTestCase {
    func testSaveLoadAndAuthenticatePrimaryTokenUsesNoninteractiveReads() throws {
        let secureStrings = FakeNetworkMCPSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)

        let metadata = try store.savePrimaryToken("secret-token", label: " OpenClaw ")

        XCTAssertEqual(metadata.label, "OpenClaw")
        XCTAssertEqual(metadata.fingerprint, MCPRemoteBearerTokenStore.fingerprint(for: "secret-token"))
        XCTAssertEqual(metadata.createdAt, Date(timeIntervalSince1970: 1800))
        XCTAssertEqual(metadata.rotatedAt, Date(timeIntervalSince1970: 1800))
        XCTAssertEqual(metadata.secureStoragePersistsAcrossLaunches, true)
        XCTAssertEqual(secureStrings.plainValues[MCPRemoteBearerTokenStore.primaryTokenStorageKey], "secret-token")
        XCTAssertEqual(secureStrings.plainSaveAccessModes, [.interactive])

        XCTAssertEqual(
            store.authenticate(authorizationHeader: "Bearer secret-token"),
            .authenticated(fingerprint: metadata.fingerprint)
        )
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .networkMCPAuthentication)])
    }

    func testGeneratedTokenIsSavedAndMetadataContainsNoRawToken() throws {
        let secureStrings = FakeNetworkMCPSecurePlainStringStore()
        let store = makeStore(
            secureStrings: secureStrings,
            randomBytes: { count in Array(0 ..< UInt8(count)) }
        )

        let result = try store.generateAndSavePrimaryToken(label: nil, byteCount: 4)

        XCTAssertEqual(result.token, "AAECAw")
        XCTAssertEqual(secureStrings.plainValues[MCPRemoteBearerTokenStore.primaryTokenStorageKey], result.token)
        XCTAssertEqual(result.metadata.label, MCPRemoteBearerTokenStore.defaultTokenLabel)

        let encoded = try JSONEncoder().encode(result.metadata)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains(result.token))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("bearer"))
    }

    func testAuthRejectsMissingMalformedEmptyAndInvalidHeaders() throws {
        let secureStrings = FakeNetworkMCPSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)
        try store.savePrimaryToken("secret-token")

        XCTAssertEqual(store.authenticate(authorizationHeader: nil), .rejected(.missingAuthorizationHeader))
        XCTAssertEqual(store.authenticate(authorizationHeader: "   "), .rejected(.missingAuthorizationHeader))
        XCTAssertEqual(store.authenticate(authorizationHeader: "Basic secret-token"), .rejected(.unsupportedAuthorizationScheme))
        XCTAssertEqual(store.authenticate(authorizationHeader: "Bearer"), .rejected(.emptyBearerToken))
        XCTAssertEqual(store.authenticate(authorizationHeader: "Bearer   "), .rejected(.emptyBearerToken))
        XCTAssertEqual(store.authenticate(authorizationHeader: "Bearer wrong-token"), .rejected(.invalidBearerToken))
        XCTAssertEqual(MCPRemoteBearerAuthenticationFailure.invalidBearerToken.httpStatusCode, 401)
        XCTAssertEqual(MCPRemoteBearerAuthenticationFailure.invalidBearerToken.mcpErrorCode, -32001)
    }

    func testAuthFailsClosedWhenSecureTokenMissingOrStorageUnavailable() {
        let missingStore = makeStore(secureStrings: FakeNetworkMCPSecurePlainStringStore())
        XCTAssertEqual(
            missingStore.authenticate(authorizationHeader: "Bearer secret-token"),
            .rejected(.tokenUnavailable)
        )
        XCTAssertEqual(MCPRemoteBearerAuthenticationFailure.tokenUnavailable.httpStatusCode, 503)
        XCTAssertEqual(MCPRemoteBearerAuthenticationFailure.tokenUnavailable.mcpErrorCode, -32003)

        let unavailableSecureStrings = FakeNetworkMCPSecurePlainStringStore(
            plainGetError: KeychainService.KeychainError.interactionNotAllowed
        )
        let unavailableStore = makeStore(secureStrings: unavailableSecureStrings)
        XCTAssertEqual(
            unavailableStore.authenticate(authorizationHeader: "Bearer secret-token"),
            .rejected(.secureStorageUnavailable)
        )
        XCTAssertEqual(unavailableSecureStrings.plainGetAccessModes, [.nonInteractive(reason: .networkMCPAuthentication)])
    }

    func testRotationReplacesTokenAndChangesMetadataFingerprint() throws {
        let secureStrings = FakeNetworkMCPSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)

        let first = try store.savePrimaryToken("first-token", label: "first")
        let second = try store.savePrimaryToken("second-token", label: "second")

        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(secureStrings.plainValues[MCPRemoteBearerTokenStore.primaryTokenStorageKey], "second-token")
        XCTAssertEqual(store.authenticate(authorizationHeader: "Bearer first-token"), .rejected(.invalidBearerToken))
        XCTAssertEqual(
            store.authenticate(authorizationHeader: "Bearer second-token"),
            .authenticated(fingerprint: second.fingerprint)
        )
    }

    func testDeleteRemovesPrimaryTokenAndHasPrimaryTokenUsesRequestedAccessMode() throws {
        let secureStrings = FakeNetworkMCPSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)
        try store.savePrimaryToken("secret-token")

        XCTAssertTrue(try store.hasPrimaryToken(accessMode: .nonInteractive(reason: .test)))
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .test)])

        try store.deletePrimaryToken()
        XCTAssertNil(secureStrings.plainValues[MCPRemoteBearerTokenStore.primaryTokenStorageKey])
        XCTAssertEqual(secureStrings.plainDeleteAccessModes, [.interactive])
        XCTAssertFalse(try store.hasPrimaryToken(accessMode: .nonInteractive(reason: .test)))
    }

    func testConstantTimeEqualsChecksContentAndLength() {
        XCTAssertTrue(MCPRemoteBearerTokenStore.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(MCPRemoteBearerTokenStore.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(MCPRemoteBearerTokenStore.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(MCPRemoteBearerTokenStore.constantTimeEquals("", "abc"))
    }

    private func makeStore(
        secureStrings: FakeNetworkMCPSecurePlainStringStore,
        randomBytes: @escaping (Int) throws -> [UInt8] = { count in Array(repeating: 7, count: count) }
    ) -> MCPRemoteBearerTokenStore {
        MCPRemoteBearerTokenStore(
            secureStrings: secureStrings,
            now: { Date(timeIntervalSince1970: 1800) },
            idGenerator: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! },
            randomBytes: randomBytes
        )
    }
}

private final class FakeNetworkMCPSecurePlainStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches: Bool

    var plainValues: [String: String] = [:]
    var plainGetError: Error?
    var plainSaveError: Error?
    var plainDeleteError: Error?

    private(set) var plainGetAccessModes: [KeychainAccessMode] = []
    private(set) var plainSaveAccessModes: [KeychainAccessMode] = []
    private(set) var plainDeleteAccessModes: [KeychainAccessMode] = []

    init(
        plainGetError: Error? = nil,
        plainSaveError: Error? = nil,
        plainDeleteError: Error? = nil,
        persistsValuesAcrossLaunches: Bool = true
    ) {
        self.plainGetError = plainGetError
        self.plainSaveError = plainSaveError
        self.plainDeleteError = plainDeleteError
        self.persistsValuesAcrossLaunches = persistsValuesAcrossLaunches
    }

    func getPlainValue(for key: String, accessMode: KeychainAccessMode) throws -> String? {
        plainGetAccessModes.append(accessMode)
        if let plainGetError {
            throw plainGetError
        }
        return plainValues[key]
    }

    func savePlainValue(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode
    ) throws {
        plainSaveAccessModes.append(accessMode)
        if let plainSaveError {
            throw plainSaveError
        }
        plainValues[key] = value
    }

    func deletePlainValue(for key: String, accessMode: KeychainAccessMode) throws {
        plainDeleteAccessModes.append(accessMode)
        if let plainDeleteError {
            throw plainDeleteError
        }
        plainValues.removeValue(forKey: key)
    }
}
