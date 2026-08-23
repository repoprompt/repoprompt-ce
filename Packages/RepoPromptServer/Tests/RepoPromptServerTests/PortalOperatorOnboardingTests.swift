import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import RepoPromptHeadlessRuntime
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class PortalOperatorOnboardingTests: XCTestCase {
    func testSetupRequiresTokenAndDeletesOwnerOnlyTokenFileBeforeSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokenURL = root.appendingPathComponent("operator-setup-token")
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let token = try await store.issueOperatorSetupToken()
        try Data("\(token)\n".utf8).write(to: tokenURL)
        let service = try await Self.service(store: store, setupTokenURL: tokenURL)
        let app = Application(router: service.internalRouter())

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/portal/api/v1/setup",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(string: #"{"password":"operator-password","passwordConfirmation":"operator-password"}"#)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: tokenURL.path))
            let accountExists = try await store.hasOperatorAccount()
            XCTAssertFalse(accountExists)

            try await client.execute(
                uri: "/portal/api/v1/setup",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(SetupBody(
                    password: "operator-password",
                    passwordConfirmation: "operator-password",
                    setupToken: token
                )))
            ) { response in
                XCTAssertEqual(response.status, .created)
                XCTAssertFalse(FileManager.default.fileExists(atPath: tokenURL.path))
            }
        }
    }

    func testFirstRunSetupThenLoginIssuesSessionCookie() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let token = try await store.issueOperatorSetupToken()
        let service = try await Self.service(store: store)
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/portal/", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let html = String(buffer: response.body)
                XCTAssertTrue(html.contains("auth-gate"))
            }
            try await client.execute(uri: "/portal/api/v1/bootstrap", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(uri: "/portal/api/v1/auth/status", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let status = try JSONDecoder.serviceDecoder.decode(AuthStatus.self, from: Data(response.body.readableBytesView))
                XCTAssertTrue(status.needsSetup)
                XCTAssertFalse(status.authenticated)
                XCTAssertTrue(status.passwordLoginEnabled)
            }
            try await client.execute(
                uri: "/portal/api/v1/setup",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(SetupBody(
                    password: "operator-password",
                    passwordConfirmation: "operator-password",
                    setupToken: token
                )))
            ) { response in
                XCTAssertEqual(response.status, .created)
                XCTAssertTrue((response.headers[.setCookie] ?? "").contains("rpce_operator_session="))
            }
            var cookie = ""
            try await client.execute(
                uri: "/portal/api/v1/login",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(LoginBody(password: "operator-password")))
            ) { response in
                XCTAssertEqual(response.status, .ok)
                cookie = try XCTUnwrap(response.headers[.setCookie])
            }
            var headers = HTTPFields()
            headers[.cookie] = cookie.split(separator: ";").first.map(String.init)
            try await client.execute(uri: "/portal/api/v1/bootstrap", method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testPortalLogoutCommitsTokenMetadataAndAuditBeforeClearingCookie() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let setupToken = try await store.issueOperatorSetupToken()
        try await store.createOperatorAccount(password: "logout-http-password", setupToken: setupToken)
        let token = try await store.createOperatorSession()
        let issuedSessions = try await store.operatorSessions(currentToken: token)
        let target = try XCTUnwrap(issuedSessions.first(where: \.current))
        let service = try await Self.service(store: store)
        let app = Application(router: service.internalRouter())

        try await app.test(.router) { client in
            var headers = Self.portalMutationHeaders()
            headers[.cookie] = "rpce_operator_session=\(token)"
            try await client.execute(
                uri: "/portal/api/v1/logout",
                method: .post,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue((response.headers[.setCookie] ?? "").contains("Max-Age=0"))
            }
            try await client.execute(
                uri: "/portal/api/v1/bootstrap",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }

        let authenticatedAfterLogout = try await store.operatorSessionUsername(token: token)
        XCTAssertNil(authenticatedAfterLogout)
        let sessionsAfterLogout = try await store.operatorSessions(currentToken: token)
        let record = try XCTUnwrap(sessionsAfterLogout.first { $0.sessionID == target.sessionID })
        XCTAssertNotNil(record.revokedAt)
        XCTAssertEqual(record.revocationReason, "logout")
        let securityAudit = try await store.operatorSecurityAudit(limit: 100)
        let logoutAudit = try XCTUnwrap(securityAudit.first {
            $0.operation == "logout" && $0.outcome == "success" && $0.detailCode == "sessionRevoked"
        })
        XCTAssertEqual(logoutAudit.actor, "operator:\(SQLiteServiceStore.defaultOperatorUsername)")
        XCTAssertNotNil(logoutAudit.clientIdentityDigest)
        XCTAssertFalse(String(describing: logoutAudit).contains(token))
    }

    func testLogoutRejectsPasswordReplacementCookieHeldPastCommittedLogout() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let setupToken = try await store.issueOperatorSetupToken()
        try await store.createOperatorAccount(password: "initial-http-password", setupToken: setupToken)
        let originalToken = try await store.createOperatorSession()
        let service = try await Self.service(store: store)
        let app = Application(router: service.internalRouter())

        try await app.test(.router) { client in
            var originalHeaders = Self.portalMutationHeaders()
            originalHeaders[.cookie] = "rpce_operator_session=\(originalToken)"
            var lateReplacementCookie = ""
            try await client.execute(
                uri: "/portal/api/v1/account/password",
                method: .post,
                headers: originalHeaders,
                body: ByteBuffer(string: #"{"currentPassword":"initial-http-password","newPassword":"replacement-http-password","passwordConfirmation":"replacement-http-password"}"#)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                lateReplacementCookie = try XCTUnwrap(response.headers[.setCookie])
                XCTAssertFalse(lateReplacementCookie.contains("Max-Age=0"))
            }
            try await client.execute(
                uri: "/portal/api/v1/logout",
                method: .post,
                headers: originalHeaders
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue((response.headers[.setCookie] ?? "").contains("Max-Age=0"))
            }
            var replacementHeaders = HTTPFields()
            replacementHeaders[.cookie] = lateReplacementCookie.split(separator: ";").first.map(String.init)
            try await client.execute(
                uri: "/portal/api/v1/bootstrap",
                method: .get,
                headers: replacementHeaders
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testSetupRejectsMismatchedPasswordAndInvalidToken() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        _ = try await store.issueOperatorSetupToken()
        let service = try await Self.service(store: store)
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/portal/api/v1/setup",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(SetupBody(
                    password: "operator-password",
                    passwordConfirmation: "different-password",
                    setupToken: "nope"
                )))
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            try await client.execute(
                uri: "/portal/api/v1/setup",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(SetupBody(
                    password: "operator-password",
                    passwordConfirmation: "operator-password",
                    setupToken: "nope"
                )))
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testConfigurationBootsWithoutTLSFilesAndEnablesPasswordLogin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try RepoPromptServerConfiguration.environment([
            "REPOPROMPT_STATE_DB": directory.appendingPathComponent("repoprompt.sqlite").path,
            "REPOPROMPT_ENABLED_PROVIDERS": ""
        ])
        XCTAssertFalse(configuration.usesMutualTLS)
        XCTAssertTrue(configuration.certificatePath.hasSuffix("/trust/server.crt"))
        XCTAssertNil(configuration.clientCAPath)
        XCTAssertNil(configuration.portalPort)
    }

    func testMutualTLSBrowserPortalRequiresExplicitTrustedProxyTopology() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = [
            "REPOPROMPT_STATE_DB": directory.appendingPathComponent("repoprompt.sqlite").path,
            "REPOPROMPT_ENABLED_PROVIDERS": "",
            "REPOPROMPT_TLS_CERT_FILE": directory.appendingPathComponent("server.crt").path,
            "REPOPROMPT_TLS_KEY_FILE": directory.appendingPathComponent("server.key").path,
            "REPOPROMPT_TLS_CLIENT_CA_FILE": directory.appendingPathComponent("ca.crt").path,
            "REPOPROMPT_OPERATOR_CERT_IDENTITY": "operator.internal",
        ]
        XCTAssertThrowsError(try RepoPromptServerConfiguration.environment(environment))

        environment["REPOPROMPT_PORTAL_PORT"] = "9081"
        environment["REPOPROMPT_PUBLIC_ORIGIN"] = "https://pilot.example.test"
        environment["REPOPROMPT_TRUSTED_PROXY_CIDRS"] = "127.0.0.0/8"
        let configuration = try RepoPromptServerConfiguration.environment(environment)
        XCTAssertTrue(configuration.usesMutualTLS)
        XCTAssertEqual(configuration.portalPort, 9081)
    }

    func testOperatorCertificateDoesNotSkipPasswordSetup() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let token = try await store.issueOperatorSetupToken()
        let service = RepoPromptHTTPService(
            authority: RepoPromptHeadlessAuthority(store: store),
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: InternalSigningKey(keyID: "response", role: .sync, direction: InternalHMACDirection.repoPromptToClient, secret: Data("response-secret-32-bytes-long!!".utf8)),
            certificateRoleResolver: CertificateIdentityRoleResolver(identities: ["repoprompt-operator": .operatorRole]),
            portalPeerCertificateDER: Data("not-used".utf8),
            portalPasswordLoginEnabled: true
        , mutationGate: AuthorityMutationGate()
        )
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/portal/api/v1/auth/status", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let status = try JSONDecoder.serviceDecoder.decode(AuthStatus.self, from: Data(response.body.readableBytesView))
                XCTAssertTrue(status.needsSetup)
                XCTAssertFalse(status.authenticated)
                XCTAssertTrue(status.passwordLoginEnabled)
            }
            try await client.execute(uri: "/portal/api/v1/bootstrap", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(
                uri: "/portal/api/v1/setup",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(SetupBody(
                    password: "operator-password",
                    passwordConfirmation: "operator-password",
                    setupToken: token
                )))
            ) { response in
                XCTAssertEqual(response.status, .created)
            }
        }
    }

    private static func service(
        store: SQLiteServiceStore,
        setupTokenURL: URL? = nil
    ) async throws -> RepoPromptHTTPService {
        let authority = RepoPromptHeadlessAuthority(store: store)
        return RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: InternalSigningKey(keyID: "response", role: .sync, direction: InternalHMACDirection.repoPromptToClient, secret: Data("response-secret-32-bytes-long!!".utf8)),
            portalPasswordLoginEnabled: true,
            operatorSetupTokenURL: setupTokenURL
        , mutationGate: AuthorityMutationGate()
        )
    }

    private static func portalMutationHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers[.init("Origin")!] = "https://localhost"
        headers[.init("Sec-Fetch-Site")!] = "same-origin"
        headers[.contentType] = "application/json"
        headers[.init("X-RepoPrompt-Portal-CSRF")!] = "1"
        return headers
    }

    private struct AuthStatus: Decodable {
        let needsSetup: Bool
        let authenticated: Bool
        let passwordLoginEnabled: Bool
    }

    private struct SetupBody: Encodable {
        let password: String
        let passwordConfirmation: String
        let setupToken: String
    }

    private struct LoginBody: Encodable {
        let password: String
    }
}
