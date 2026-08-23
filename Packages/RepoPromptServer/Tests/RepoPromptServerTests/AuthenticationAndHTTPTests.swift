import Foundation
import Hummingbird
import HummingbirdTesting
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class AuthenticationAndHTTPTests: XCTestCase {
    private let responseSigningKey = InternalSigningKey(keyID: "response-v1", role: .sync, direction: InternalHMACDirection.repoPromptToClient, secret: Data("response-secret".utf8))

    func testConfigurationAcceptsOverlappingRoleKeysAndRejectsDuplicateIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func secret(_ name: String) throws -> String {
            let path = directory.appendingPathComponent(name).path
            let material = String(("\(name)-" + String(repeating: "x", count: 64)).prefix(32))
            try Data(material.utf8).write(to: URL(fileURLWithPath: path))
            return path
        }
        var environment = try [
            "REPOPROMPT_TLS_CERT_FILE": "/cert", "REPOPROMPT_TLS_KEY_FILE": "/key", "REPOPROMPT_TLS_CLIENT_CA_FILE": "/ca",
            "REPOPROMPT_OPERATOR_CERT_IDENTITY": "operator.internal",
            "REPOPROMPT_APP_HMAC_FILE": secret("app"), "REPOPROMPT_SYNC_HMAC_FILE": secret("sync"),
            "REPOPROMPT_OPERATOR_HMAC_FILE": secret("operator"), "REPOPROMPT_EVENT_HMAC_FILE": secret("event"),
            "REPOPROMPT_APP_PREVIOUS_KEY_ID": "app-v0", "REPOPROMPT_APP_PREVIOUS_HMAC_FILE": secret("app-v0")
        ]
        let configuration = try RepoPromptServerConfiguration.environment(environment)
        XCTAssertEqual(configuration.signingKeys.count, 4)
        XCTAssertEqual(configuration.signingKeys.first(where: { $0.keyID == "app-v0" })?.active, false)
        XCTAssertEqual(configuration.signingKeys.first(where: { $0.keyID == "app-v0" })?.role, .app)
        XCTAssertEqual(Set(configuration.providerExecutables.keys), [.codex, .claudeCompatible, .openCodeACP, .cursorACP, .grokBuildACP])
        XCTAssertEqual(configuration.enabledProviders, [.codex, .claudeCompatible])

        environment["REPOPROMPT_ENABLED_PROVIDERS"] = ""
        let disabledConfiguration = try RepoPromptServerConfiguration.environment(environment)
        XCTAssertTrue(disabledConfiguration.enabledProviders.isEmpty)
        environment["REPOPROMPT_ENABLED_PROVIDERS"] = "codex, claudeCompatible"
        let enabledConfiguration = try RepoPromptServerConfiguration.environment(environment)
        XCTAssertEqual(enabledConfiguration.enabledProviders, [.codex, .claudeCompatible])

        environment["REPOPROMPT_CODEX_CREDENTIAL_HOME"] = directory.path
        XCTAssertThrowsError(try RepoPromptServerConfiguration.environment(environment))
        environment["REPOPROMPT_CODEX_CREDENTIAL_HOME"] = nil
        environment["REPOPROMPT_CODEX_AUTH_STATUS_FILE"] = directory.appendingPathComponent("status.json").path
        XCTAssertThrowsError(try RepoPromptServerConfiguration.environment(environment))
        environment["REPOPROMPT_CODEX_AUTH_STATUS_FILE"] = nil

        environment["REPOPROMPT_ENABLED_PROVIDERS"] = "unknown-provider"
        XCTAssertThrowsError(try RepoPromptServerConfiguration.environment(environment))
        environment["REPOPROMPT_ENABLED_PROVIDERS"] = "codex"

        environment["REPOPROMPT_SYNC_PREVIOUS_KEY_ID"] = "app-v0"
        environment["REPOPROMPT_SYNC_PREVIOUS_HMAC_FILE"] = try secret("sync-v0")
        XCTAssertThrowsError(try RepoPromptServerConfiguration.environment(environment))
    }

    func testOperatorOnlyConfigurationBootsWithoutIntegrationHMAC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = [
            "REPOPROMPT_TLS_CERT_FILE": "/cert",
            "REPOPROMPT_TLS_KEY_FILE": "/key",
            "REPOPROMPT_TLS_CLIENT_CA_FILE": "/ca",
            "REPOPROMPT_OPERATOR_CERT_IDENTITY": "operator.internal",
            "REPOPROMPT_STATE_DB": directory.appendingPathComponent("repoprompt.sqlite").path
        ]
        let configuration = try RepoPromptServerConfiguration.environment(environment)
        XCTAssertTrue(configuration.signingKeys.isEmpty)
        XCTAssertEqual(configuration.eventSigningKey.direction, InternalHMACDirection.repoPromptToClient)
        XCTAssertGreaterThanOrEqual(configuration.eventSigningKey.secret.count, 32)
        let again = try RepoPromptServerConfiguration.environment(environment)
        XCTAssertEqual(configuration.eventSigningKey.secret, again.eventSigningKey.secret)
        let unpairedAppHMAC = directory.appendingPathComponent("app.hmac")
        try Data(String(repeating: "a", count: 32).utf8).write(to: unpairedAppHMAC)
        var incomplete = environment
        incomplete["REPOPROMPT_APP_HMAC_FILE"] = unpairedAppHMAC.path
        XCTAssertThrowsError(try RepoPromptServerConfiguration.environment(incomplete))
    }

    func testNeutralAppEnvNamesLoadRepoPromptHMACDirections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func secret(_ name: String) throws -> String {
            let path = directory.appendingPathComponent(name).path
            let material = String(("\(name)-" + String(repeating: "x", count: 64)).prefix(32))
            try Data(material.utf8).write(to: URL(fileURLWithPath: path))
            return path
        }
        let configuration = try RepoPromptServerConfiguration.environment([
            "REPOPROMPT_TLS_CERT_FILE": "/cert",
            "REPOPROMPT_TLS_KEY_FILE": "/key",
            "REPOPROMPT_TLS_CLIENT_CA_FILE": "/ca",
            "REPOPROMPT_OPERATOR_CERT_IDENTITY": "operator.internal",
            "REPOPROMPT_APP_HMAC_FILE": secret("app"),
            "REPOPROMPT_SYNC_HMAC_FILE": secret("sync"),
            "REPOPROMPT_EVENT_HMAC_FILE": secret("event")
        ])
        XCTAssertEqual(configuration.signingKeys.first { $0.role == .app }?.direction, InternalHMACDirection.appToRepoPrompt)
        XCTAssertEqual(configuration.signingKeys.first { $0.role == .sync }?.direction, InternalHMACDirection.syncToRepoPrompt)
        XCTAssertEqual(configuration.signingKeys.first { $0.role == .app }?.keyID, "app-v1")
        XCTAssertEqual(configuration.eventSigningKey.direction, InternalHMACDirection.repoPromptToClient)
    }

    func testResponseSigningCoversJSONErrorsEmptyAndBinaryBodies() {
        let instant = Date(timeIntervalSince1970: 1_786_368_896.789)
        let nonce = "cmVzcG9uc2Utbm9uY2U"
        let signer = InternalResponseSigner(key: responseSigningKey, now: { instant }, nonce: { nonce })
        let cases: [(HTTPResponse.Status, String, Data)] = [
            (.ok, "/internal/v1/diagnostics", Data(#"{"ok":true}"#.utf8)),
            (.serviceUnavailable, "/internal/v1/diagnostics", Data(#"{"code":"dependencyUnavailable"}"#.utf8)),
            (.noContent, "/internal/v1/admin/checkpoint", Data()),
            (.partialContent, "/internal/v1/sessions/a/artifacts/b/content", Data([0, 1, 2, 255]))
        ]

        for (status, path, body) in cases {
            let digest = CanonicalSigning.bodyDigest(body)
            var headers = HTTPFields()
            headers[.init("x-internal-body-digest")!] = digest
            let signed = signer.sign(Response(status: status, headers: headers), requestPathAndQuery: path)
            let timestamp = CanonicalSigning.iso8601String(instant)
            let canonical = CanonicalSigning.requestString(method: "RESPONSE", pathAndQuery: "\(path)#\(status.code)", timestamp: timestamp, nonce: nonce, bodyDigest: digest, authorizationDecisionDigest: CanonicalSigning.bodyDigest(Data()), keyID: responseSigningKey.keyID)
            XCTAssertEqual(signed.headers[.init("x-internal-body-digest")!], digest)
            XCTAssertEqual(signed.headers[.init("x-internal-key-id")!], responseSigningKey.keyID)
            XCTAssertEqual(signed.headers[.init("x-internal-timestamp")!], timestamp)
            XCTAssertEqual(signed.headers[.init("x-internal-nonce")!], nonce)
            XCTAssertEqual(signed.headers[.init("x-internal-signature")!], CanonicalSigning.hmacSHA256(message: canonical, key: responseSigningKey.secret))
        }
    }

    func testCertificateTrustConfigurationRejectsOverlappingRoleIdentities() throws {
        XCTAssertThrowsError(try CertificateIdentityRoleResolver.environment([
            "REPOPROMPT_APP_CERT_IDENTITY": "shared.internal",
            "REPOPROMPT_SYNC_CERT_IDENTITY": "shared.internal",
            "REPOPROMPT_OPERATOR_CERT_IDENTITY": "operator.internal"
        ]))
    }

    func testOperatorOnlyCertificateIdentityDoesNotRequireIntegrationPeers() throws {
        XCTAssertNoThrow(try CertificateIdentityRoleResolver.environment([
            "REPOPROMPT_OPERATOR_CERT_IDENTITY": "operator.internal"
        ]))
        XCTAssertThrowsError(try CertificateIdentityRoleResolver.environment([
            "REPOPROMPT_OPERATOR_CERT_IDENTITY": "operator.internal",
            "REPOPROMPT_APP_CERT_IDENTITY": "app.internal"
        ]))
    }

    func testInternalRouteRoleRejectsUnknownNames() throws {
        XCTAssertEqual(try JSONDecoder().decode(InternalRouteRole.self, from: Data(#""app""#.utf8)), .app)
        XCTAssertEqual(try JSONDecoder().decode(InternalRouteRole.self, from: Data(#""sync""#.utf8)), .sync)
        XCTAssertThrowsError(try JSONDecoder().decode(InternalRouteRole.self, from: Data(#""unknown""#.utf8)))
        XCTAssertEqual(String(data: try JSONEncoder().encode(InternalRouteRole.app), encoding: .utf8), "\"app\"")
        XCTAssertEqual(String(data: try JSONEncoder().encode(InternalRouteRole.sync), encoding: .utf8), "\"sync\"")
    }

    func testSignedRequestRejectsNonceReplayAndRoleMismatch() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let instant = Date(timeIntervalSince1970: 1000)
        let key = InternalSigningKey(keyID: "sync-v1", role: .sync, direction: InternalHMACDirection.syncToRepoPrompt, secret: Data("secret".utf8))
        let auth = InternalRequestAuthenticator(keys: [key], store: store, now: { instant })
        let timestamp = CanonicalSigning.iso8601String(instant)
        let nonce = "abcdefghijklmnop"
        let bodyDigest = CanonicalSigning.bodyDigest(Data())
        let authorizationDigest = CanonicalSigning.bodyDigest(Data())
        let canonical = CanonicalSigning.requestString(method: "GET", pathAndQuery: "/internal/v1/events", timestamp: timestamp, nonce: nonce, bodyDigest: bodyDigest, authorizationDecisionDigest: authorizationDigest, keyID: key.keyID)
        let request = SignedInternalRequest(method: "GET", pathAndQuery: "/internal/v1/events", timestamp: timestamp, nonce: nonce, body: Data(), bodyDigest: bodyDigest, authorizationDecisionData: nil, authorizationDecisionDigest: authorizationDigest, keyID: key.keyID, signature: CanonicalSigning.hmacSHA256(message: canonical, key: key.secret))
        _ = try await auth.verify(request, allowedRoles: [.sync], operation: "events")
        do { _ = try await auth.verify(request, allowedRoles: [.sync], operation: "events")
            XCTFail("expected replay rejection")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .internalAuthFailed) }
        try await store.close()
    }

    func testAuthorizationDecisionRevisionsAreDurablyMonotonicAndSingleUse() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let instant = Date(timeIntervalSince1970: 1000)
        let key = InternalSigningKey(keyID: "app-v1", role: .app, direction: InternalHMACDirection.appToRepoPrompt, secret: Data("secret".utf8))
        let auth = InternalRequestAuthenticator(keys: [key], store: store, now: { instant })

        func request(revision: Int64, nonce: String, decisionID: UUID = UUID()) throws -> SignedInternalRequest {
            let unsignedDecision = AuthorizationDecision(decisionID: decisionID, actor: .init(userID: "u1", username: "alice", displayName: "Alice"), operation: "listProjects", requestDigest: CanonicalSigning.bodyDigest(Data()), policyRevision: revision, controllerRevision: revision, membershipRevision: revision, issuedAt: instant, expiresAt: instant.addingTimeInterval(10), requestID: UUID(), correlationID: UUID(), keyID: key.keyID, signature: "")
            let unsignedData = try JSONEncoder.serviceEncoder.encode(unsignedDecision)
            let decisionSignature = CanonicalSigning.hmacSHA256(message: try CanonicalSigning.canonicalJSONObject(unsignedData, removingTopLevelKeys: ["signature"]), key: key.secret)
            let decision = AuthorizationDecision(decisionID: unsignedDecision.decisionID, actor: unsignedDecision.actor, operation: unsignedDecision.operation, requestDigest: unsignedDecision.requestDigest, policyRevision: unsignedDecision.policyRevision, controllerRevision: unsignedDecision.controllerRevision, membershipRevision: unsignedDecision.membershipRevision, issuedAt: unsignedDecision.issuedAt, expiresAt: unsignedDecision.expiresAt, requestID: unsignedDecision.requestID, correlationID: unsignedDecision.correlationID, keyID: key.keyID, signature: decisionSignature)
            let decisionData = try JSONEncoder.serviceEncoder.encode(decision)
            let timestamp = CanonicalSigning.iso8601String(instant)
            let path = "/internal/v1/projects"
            let bodyDigest = CanonicalSigning.bodyDigest(Data())
            let decisionDigest = CanonicalSigning.bodyDigest(decisionData)
            let canonical = CanonicalSigning.requestString(method: "GET", pathAndQuery: path, timestamp: timestamp, nonce: nonce, bodyDigest: bodyDigest, authorizationDecisionDigest: decisionDigest, keyID: key.keyID)
            return SignedInternalRequest(method: "GET", pathAndQuery: path, timestamp: timestamp, nonce: nonce, body: Data(), bodyDigest: bodyDigest, authorizationDecisionData: decisionData, authorizationDecisionDigest: decisionDigest, keyID: key.keyID, signature: CanonicalSigning.hmacSHA256(message: canonical, key: key.secret))
        }

        let accepted = try request(revision: 2, nonce: "decisionrevision2")
        _ = try await auth.verify(accepted, allowedRoles: [.app], operation: "listProjects")
        do {
            _ = try await auth.verify(request(revision: 1, nonce: "decisionrevision1"), allowedRoles: [.app], operation: "listProjects")
            XCTFail("expected revision regression rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorizationDecisionRejected)
        }
        try await store.close()
    }

    func testLoopbackHealthRoutesAreContentFree() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let auth = InternalRequestAuthenticator(keys: [], store: store)
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: auth, eventSigningKey: responseSigningKey, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.healthRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/health/live", method: .get) { response in XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.body.readableBytes, 0)
            }
            try await client.execute(uri: "/health/ready", method: .get) { response in XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.body.readableBytes, 0)
            }
        }
        try await store.close()
    }

    func testUnavailableCapabilityRoutesStillRequireAuthentication() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let auth = InternalRequestAuthenticator(keys: [], store: store)
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: auth, eventSigningKey: responseSigningKey, mutationGate: AuthorityMutationGate())
        let responseKeyID = responseSigningKey.keyID
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/internal/v1/catalog/providers", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
                let body = Data(response.body.readableBytesView)
                XCTAssertEqual(response.headers[.init("x-internal-body-digest")!], CanonicalSigning.bodyDigest(body))
                XCTAssertEqual(response.headers[.init("x-internal-key-id")!], responseKeyID)
                XCTAssertNotNil(response.headers[.init("x-internal-timestamp")!])
                XCTAssertNotNil(response.headers[.init("x-internal-nonce")!])
                XCTAssertNotNil(response.headers[.init("x-internal-signature")!])
            }
        }
        try await store.close()
    }

    func testEveryNormativeV1MethodAndPathIsRegistered() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: InternalRequestAuthenticator(keys: [], store: store), eventSigningKey: responseSigningKey, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.internalRouter())
        let id = UUID().uuidString
        let routes: [(HTTPRequest.Method, String)] = [
            (.get, "/internal/v1/diagnostics"), (.get, "/metrics"), (.get, "/internal/v1/capabilities"),
            (.get, "/internal/v1/projects"), (.post, "/internal/v1/projects"),
            (.post, "/internal/v1/projects/\(id)/source-operations"), (.get, "/internal/v1/projects/\(id)/snapshot"),
            (.patch, "/internal/v1/projects/\(id)"), (.delete, "/internal/v1/projects/\(id)"), (.post, "/internal/v1/projects/\(id)/refresh"),
            (.get, "/internal/v1/projects/\(id)/tree"), (.post, "/internal/v1/projects/\(id)/search"), (.post, "/internal/v1/projects/\(id)/file"),
            (.post, "/internal/v1/projects/\(id)/diff"), (.post, "/internal/v1/projects/\(id)/composer-attachments"),
            (.post, "/internal/v1/projects/\(id)/composer-attachments/resolve"),
            (.get, "/internal/v1/projects/\(id)/composer-attachments/\(id)/preview"),
            (.delete, "/internal/v1/projects/\(id)/composer-attachments/\(id)"),
            (.get, "/internal/v1/catalog/composer"), (.get, "/internal/v1/catalog/composer-suggestions"),
            (.get, "/internal/v1/catalog/providers"), (.get, "/internal/v1/catalog/models"),
            (.get, "/internal/v1/catalog/workflows"), (.get, "/internal/v1/catalog/workflows/review"), (.get, "/internal/v1/catalog/execution-modes"),
            (.get, "/internal/v1/sessions"), (.post, "/internal/v1/sessions"), (.get, "/internal/v1/sessions/\(id)/snapshot"),
            (.post, "/internal/v1/sessions/\(id)/commands"), (.post, "/internal/v1/sessions/\(id)/interactions/\(id)/answer"),
            (.patch, "/internal/v1/sessions/\(id)/execution-permissions"), (.patch, "/internal/v1/sessions/\(id)/collaboration-metadata"),
            (.get, "/internal/v1/sessions/\(id)/children"), (.get, "/internal/v1/sessions/\(id)/transcript"),
            (.get, "/internal/v1/sessions/\(id)/artifacts"), (.get, "/internal/v1/sessions/\(id)/artifacts/\(id)/content"),
            (.get, "/internal/v1/projects/\(id)/worktrees"), (.get, "/internal/v1/projects/\(id)/worktrees/\(id)"),
            (.post, "/internal/v1/sessions/\(id)/worktrees"), (.patch, "/internal/v1/sessions/\(id)/worktree-binding"),
            (.post, "/internal/v1/sessions/\(id)/worktrees/\(id)/merge"), (.get, "/internal/v1/sessions/\(id)/context/selection"),
            (.put, "/internal/v1/sessions/\(id)/context/selection"), (.post, "/internal/v1/sessions/\(id)/context/selection/add"),
            (.post, "/internal/v1/sessions/\(id)/context/selection/remove"), (.post, "/internal/v1/sessions/\(id)/context/build"),
            (.post, "/internal/v1/sessions/\(id)/context/context-builder"), (.post, "/internal/v1/sessions/\(id)/context/oracle"),
            (.get, "/internal/v1/events"), (.get, "/internal/v1/events/stream"), (.get, "/internal/v1/snapshot"),
            (.post, "/internal/v1/admin/checkpoint"), (.post, "/internal/v1/admin/quiesce")
        ]
        try await app.test(.router) { client in
            for (method, path) in routes {
                try await client.execute(uri: path, method: method) { response in
                    XCTAssertNotEqual(response.status, .notFound, "Missing route: \(method) \(path)")
                    XCTAssertNotEqual(response.status, .methodNotAllowed, "Wrong method registration: \(method) \(path)")
                }
            }
        }
        try await store.close()
    }

    func testServerIsReadyWithZeroConfiguredProviders() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = ProviderCLIAdapter(configurations: [], enabledProviders: [])
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let readiness = RepoPromptReadinessService(
            authority: authority,
            store: store,
            minimumFreeBytes: 0,
            minimumFreeNodes: 0,
            maximumActiveSessions: 10,
            cacheDuration: 0
        )

        let snapshot = await readiness.snapshot(forceRefresh: true)
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: InternalRequestAuthenticator(keys: [], store: store), eventSigningKey: responseSigningKey, readiness: readiness, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.healthRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/health/ready", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }

        XCTAssertTrue(snapshot.ready)
        XCTAssertTrue(snapshot.providers.isEmpty)
        try await store.close()
    }

    func testServerRemainsReadyWhenAllProviderChecksFail() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        try await store.reserveOwnedResource(OwnedResourceRecord(
            kind: .providerHome,
            externalID: UUID(),
            internalPathIdentity: "/var/lib/repoprompt/state/provider-homes/unavailable",
            lifecycleState: .missing
        ))
        let runtimes = ProviderKind.allCases.map { CountingUnavailableProviderRuntime(kind: $0) }
        let adapter = ProviderCLIAdapter(runtimes: runtimes, preflightCacheDuration: .milliseconds(50))
        let configurations = ProviderKind.allCases.map {
            ProviderCLIConfiguration(kind: $0, executable: "/usr/bin/false", protocolVersion: "unavailable")
        }
        let providerSettings = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: configurations,
            initiallyEnabled: Set(ProviderKind.allCases)
        )
        try await providerSettings.bootstrap()

        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: adapter)
        let readiness = RepoPromptReadinessService(
            authority: authority,
            store: store,
            requiredProviders: Set(ProviderKind.allCases),
            minimumFreeBytes: 0,
            minimumFreeNodes: 0,
            maximumActiveSessions: 10,
            cacheDuration: 0,
            providerSettings: providerSettings
        )
        let snapshot = await readiness.snapshot(forceRefresh: true)
        XCTAssertTrue(snapshot.ready)
        XCTAssertTrue(snapshot.providers.isEmpty)
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: InternalRequestAuthenticator(keys: [], store: store), eventSigningKey: responseSigningKey, readiness: readiness, providerSettings: providerSettings, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.healthRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/health/ready", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }

        _ = try await providerSettings.catalog(refreshCLI: true, refreshRuntime: true)
        try await Task.sleep(for: .milliseconds(50))
        for runtime in runtimes {
            let count = await runtime.preflightCount()
            XCTAssertEqual(count, 0)
        }
        try await store.close()
    }

    func testOperationalSnapshotAggregatesProviderHistoryWithoutMakingProviderFailuresCoreReadiness() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let now = Date(timeIntervalSince1970: 10_000)
        let kinds: [OwnedResourceKind] = [.providerHome, .providerCredentialCopy, .providerOutput]
        for index in 0 ..< 256 {
            try await store.reserveOwnedResource(.init(
                kind: kinds[index % kinds.count],
                internalPathIdentity: "/provider-history/\(index)",
                lifecycleState: index.isMultiple(of: 3) ? .missing : .deleted,
                observedBytes: Int64(index),
                metadata: ["probe": "\(index)"],
                cleanupError: index.isMultiple(of: 7) ? "provider probe failed" : nil,
                createdAt: now.addingTimeInterval(-100),
                updatedAt: now.addingTimeInterval(-50)
            ))
        }

        let snapshot = try await store.operationalSnapshot(now: now)
        XCTAssertTrue(snapshot.integrityValid)
        XCTAssertTrue(snapshot.migrationsValid)
        XCTAssertTrue(snapshot.ownedResources.ready)
        XCTAssertEqual(snapshot.ownedResources.aggregates.reduce(0) { $0 + $1.count }, 256)
        XCTAssertEqual(snapshot.ownedResources.unhealthyCommittedResources, 0)
        try await store.close()
    }

    func testServerRecoversOnlyConnectedProviderStatusWithSingleFlight() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let connectedRuntime = CountingUnavailableProviderRuntime(kind: .openCodeACP)
        let unconfiguredRuntime = CountingUnavailableProviderRuntime(kind: .cursorACP)
        let adapter = ProviderCLIAdapter(runtimes: [connectedRuntime, unconfiguredRuntime], preflightCacheDuration: .seconds(1))
        let configurations = [
            ProviderCLIConfiguration(kind: .openCodeACP, executable: "/usr/bin/true", protocolVersion: "acp-v1"),
            ProviderCLIConfiguration(kind: .cursorACP, executable: "/usr/bin/true", protocolVersion: "acp-v1")
        ]
        let now = Date()
        let connection = ProviderConnectionRecord(
            connectionID: UUID(),
            providerID: .openCodeACP,
            authenticationMethod: .providerSpecific,
            state: .connected,
            accountLabel: "sandbox",
            lastTestedAt: now,
            testState: .valid,
            detail: "Connected",
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: now,
            updatedAt: now,
            revision: 1
        )
        _ = try await store.upsertProviderConnection(.init(record: connection, credentialReference: nil), expectedRevision: 0)
        let providerSettings = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: configurations,
            initiallyEnabled: [.openCodeACP, .cursorACP]
        )
        try await providerSettings.bootstrap()

        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: adapter)
        let readiness = RepoPromptReadinessService(
            authority: authority,
            store: store,
            minimumFreeBytes: 0,
            minimumFreeNodes: 0,
            maximumActiveSessions: 10,
            cacheDuration: 0,
            providerSettings: providerSettings
        )
        let snapshot = await readiness.snapshot(forceRefresh: true)
        XCTAssertTrue(snapshot.ready)
        for _ in 0 ..< 12 {
            _ = try await providerSettings.catalog(refreshCLI: true, refreshRuntime: true)
        }
        await providerSettings.startConnectedProviderRecovery()
        try await Task.sleep(for: .milliseconds(350))
        let connectedCount = await connectedRuntime.preflightCount()
        let unconfiguredCount = await unconfiguredRuntime.preflightCount()
        XCTAssertEqual(connectedCount, 1)
        XCTAssertEqual(unconfiguredCount, 0)
        try await store.close()
    }

    func testReadinessFailsClosedForMissingVolumeAndCapacity() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = ProviderCLIAdapter(configurations: [
            .init(kind: .codex, executable: "/usr/bin/true", protocolVersion: "unexpected-v1")
        ])
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let readiness = RepoPromptReadinessService(
            authority: authority,
            store: store,
            volumes: [.init(name: "missing", path: missing)],
            requiredProviders: [.codex],
            expectedProviderProtocols: [.codex: "app-server-v2"],
            minimumFreeBytes: 0,
            minimumFreeNodes: 0,
            maximumActiveSessions: 0,
            cacheDuration: 0
        )
        let auth = InternalRequestAuthenticator(keys: [], store: store)
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: auth, eventSigningKey: responseSigningKey, readiness: readiness, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.healthRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/health/live", method: .get) { response in XCTAssertEqual(response.status, .ok) }
            try await client.execute(uri: "/health/ready", method: .get) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                XCTAssertEqual(response.body.readableBytes, 0)
            }
        }
        let snapshot = await readiness.snapshot(forceRefresh: true)
        XCTAssertFalse(snapshot.ready)
        XCTAssertTrue(snapshot.providers.isEmpty)
        XCTAssertEqual(snapshot.checks.first { $0.name == "volume:missing" }?.detail, "missing")
        XCTAssertEqual(snapshot.checks.first { $0.name == "session-capacity" }?.ready, false)
        try await store.close()
    }

    func testNestedSessionsDoNotFailReadinessCapacity() async throws {
        let recovered = try await recoveredRunningSessions(rootCount: 1, childrenPerRoot: 3)
        defer { removeSQLiteFiles(recovered.database) }
        let readiness = RepoPromptReadinessService(
            authority: recovered.authority,
            store: recovered.store,
            minimumFreeBytes: 0,
            minimumFreeNodes: 0,
            maximumActiveSessions: 2,
            cacheDuration: 0
        )
        let snapshot = await readiness.snapshot(forceRefresh: true)
        XCTAssertTrue(snapshot.ready)
        XCTAssertEqual(snapshot.activeSessionCount, 4)
        XCTAssertEqual(snapshot.checks.first { $0.name == "session-capacity" }?.detail, "1/2")
        XCTAssertEqual(snapshot.checks.first { $0.name == "session-capacity" }?.ready, true)
        let service = RepoPromptHTTPService(authority: recovered.authority, store: recovered.store, authenticator: InternalRequestAuthenticator(keys: [], store: recovered.store), eventSigningKey: responseSigningKey, readiness: readiness, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.healthRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/health/ready", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        try await recovered.store.close()
    }

    func testExhaustedRootCapacityDoesNotFailHealthReady() async throws {
        let recovered = try await recoveredRunningSessions(rootCount: 2, childrenPerRoot: 0)
        defer { removeSQLiteFiles(recovered.database) }
        let readiness = RepoPromptReadinessService(
            authority: recovered.authority,
            store: recovered.store,
            minimumFreeBytes: 0,
            minimumFreeNodes: 0,
            maximumActiveSessions: 2,
            cacheDuration: 0
        )
        let snapshot = await readiness.snapshot(forceRefresh: true)
        XCTAssertTrue(snapshot.ready)
        XCTAssertEqual(snapshot.activeSessionCount, 2)
        XCTAssertEqual(snapshot.checks.first { $0.name == "session-capacity" }?.detail, "2/2")
        XCTAssertEqual(snapshot.checks.first { $0.name == "session-capacity" }?.ready, false)
        let service = RepoPromptHTTPService(authority: recovered.authority, store: recovered.store, authenticator: InternalRequestAuthenticator(keys: [], store: recovered.store), eventSigningKey: responseSigningKey, readiness: readiness, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.healthRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/health/ready", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        try await recovered.store.close()
    }

    func testDegradedProjectIsDiagnosticWithoutFailingUnrelatedReadiness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "degraded", roots: [.init(logicalName: "root", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "project", requestDigest: "project")
        try FileManager.default.removeItem(at: root)
        let degraded = try await authority.refreshProject(projectID: project.projectID, expectedRevision: project.revision, actor: actor, idempotencyKey: "refresh", requestDigest: "refresh")
        XCTAssertEqual(degraded.state, .degraded)
        let readiness = RepoPromptReadinessService(authority: authority, store: store, minimumFreeBytes: 0, minimumFreeNodes: 0, maximumActiveSessions: 10, cacheDuration: 0)
        let snapshot = await readiness.snapshot(forceRefresh: true)
        XCTAssertTrue(snapshot.ready)
        XCTAssertEqual(snapshot.degradedProjectIDs, [project.projectID])
        try await store.close()
    }

    func testVerifiedLiveProcessFamilyRemainsReadyAndUsesCanonicalDiagnosticKeys() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let identity = PersistedProcessIdentity(
            pid: 4242,
            parentPID: 1,
            processGroupID: 4242,
            sessionID: 4242,
            startTimeTicks: 99,
            bootID: "boot",
            executablePath: "/opt/repoprompt/providers/codex",
            helperTokenDigest: "digest"
        )
        try await store.persistProcessFamily(
            runID: UUID(),
            leader: identity,
            connectionGeneration: 1,
            containmentMode: "cgroup-v2"
        )
        let readiness = RepoPromptReadinessService(
            authority: authority,
            store: store,
            minimumFreeBytes: 0,
            minimumFreeNodes: 0,
            maximumActiveSessions: 10,
            cacheDuration: 0
        )
        let snapshot = await readiness.snapshot(forceRefresh: true)
        XCTAssertTrue(snapshot.ready)
        XCTAssertEqual(snapshot.operational?.activeProcessFamilyCount, 1)
        XCTAssertEqual(snapshot.checks.first { $0.name == "supervisor-recovery" }?.ready, true)

        let encoded = try JSONEncoder.serviceEncoder.encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["degradedProjectIds"])
        XCTAssertNil(object["degradedProjectIDs"])
        try await store.close()
    }

    func testInternalReadAfterAdmissionCloseRejectsBeforeAuthenticationStoreAccess() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let gate = AuthorityMutationGate()
        let instant = Date(timeIntervalSince1970: 1000)
        let key = InternalSigningKey(
            keyID: "app-v1",
            role: .app,
            direction: InternalHMACDirection.appToRepoPrompt,
            secret: Data("secret".utf8)
        )
        let path = "/internal/v1/projects"
        let headers = signedHeaders(
            method: "GET",
            path: path,
            key: key,
            instant: instant,
            nonce: "closedreadstore1"
        )
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [key], store: store, now: { instant }),
            eventSigningKey: responseSigningKey,
            mutationGate: gate
        )
        let app = Application(router: service.internalRouter())

        await gate.close()
        try await store.close()

        try await app.test(.router) { client in
            try await client.execute(uri: path, method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .unprocessableContent)
                let error = try JSONDecoder.serviceDecoder.decode(
                    ServiceAPIError.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(error.code, .staleCapability)
                XCTAssertNotNil(response.headers[.init("x-internal-signature")!])
            }
        }
    }

    func testPortalReadAfterAdmissionCloseRejectsBeforeClosedStoreAccess() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let gate = AuthorityMutationGate()
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: responseSigningKey,
            mutationGate: gate
        )
        let app = Application(router: service.internalRouter())

        await gate.close()
        try await store.close()

        try await app.test(.router) { client in
            try await client.execute(uri: "/portal/api/v1/auth/status", method: .get) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                let error = try JSONDecoder.serviceDecoder.decode(
                    ServiceAPIError.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(error.code, .staleCapability)
            }
        }
    }

    func testSSEAfterDrainRejectsBeforeAuthenticationOrClosedStoreAccess() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let gate = AuthorityMutationGate()
        let instant = Date(timeIntervalSince1970: 1000)
        let key = InternalSigningKey(
            keyID: "sync-v1",
            role: .sync,
            direction: InternalHMACDirection.syncToRepoPrompt,
            secret: Data("secret".utf8)
        )
        let path = "/internal/v1/events/stream"
        let headers = signedHeaders(
            method: "GET",
            path: path,
            key: key,
            instant: instant,
            nonce: "drainedsseaccess"
        )
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [key], store: store, now: { instant }),
            eventSigningKey: responseSigningKey,
            mutationGate: gate
        )
        let app = Application(router: service.internalRouter())

        await gate.beginDraining()
        try await store.close()

        try await app.test(.router) { client in
            try await client.execute(uri: path, method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .unprocessableContent)
                let error = try JSONDecoder.serviceDecoder.decode(
                    ServiceAPIError.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(error.code, .serviceDraining)
                XCTAssertTrue(error.retryable)
            }
        }
    }

    func testSSELastEventIDBelowReplayFloorReturnsControlFrame() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "project-sse", requestDigest: "project-sse")
        let metadata = try await store.metadata()
        _ = try await store.archiveEvents(through: 1)

        let instant = Date(timeIntervalSince1970: 1000)
        let key = InternalSigningKey(keyID: "sync-v1", role: .sync, direction: InternalHMACDirection.syncToRepoPrompt, secret: Data("secret".utf8))
        let auth = InternalRequestAuthenticator(keys: [key], store: store, now: { instant })
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: auth, eventSigningKey: responseSigningKey, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.internalRouter())
        let path = "/internal/v1/events/stream"
        let timestamp = CanonicalSigning.iso8601String(instant)
        let nonce = "expiredcursor0001"
        let canonical = CanonicalSigning.requestString(method: "GET", pathAndQuery: path, timestamp: timestamp, nonce: nonce, bodyDigest: CanonicalSigning.bodyDigest(Data()), authorizationDecisionDigest: CanonicalSigning.bodyDigest(Data()), keyID: key.keyID)
        let requestHeaders: HTTPFields = {
            var headers = HTTPFields()
            headers[.init("x-internal-key-id")!] = key.keyID
            headers[.init("x-internal-timestamp")!] = timestamp
            headers[.init("x-internal-nonce")!] = nonce
            headers[.init("x-internal-body-digest")!] = CanonicalSigning.bodyDigest(Data())
            headers[.init("x-internal-authorization-digest")!] = CanonicalSigning.bodyDigest(Data())
            headers[.init("x-internal-signature")!] = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
            headers[.init("Last-Event-ID")!] = "\(metadata.storeID.uuidString):0"
            return headers
        }()

        try await app.test(.router) { client in
            try await client.execute(uri: path, method: .get, headers: requestHeaders) { response in
                XCTAssertEqual(response.status, .ok)
                let eventStream = String(decoding: response.body.readableBytesView, as: UTF8.self)
                XCTAssertTrue(eventStream.contains("event: cursor_expired"))
                let dataLine = try XCTUnwrap(eventStream.split(separator: "\n").first { $0.hasPrefix("data: ") })
                let payload = try JSONDecoder.serviceDecoder.decode(
                    CursorExpiredResponse.self,
                    from: Data(dataLine.dropFirst("data: ".count).utf8)
                )
                XCTAssertEqual(payload.storeID, metadata.storeID)
                XCTAssertEqual(payload.replayFloor, 1)
                XCTAssertEqual(payload.snapshotURL, "/internal/v1/snapshot")
            }
        }
        try await store.close()
    }

    func testRESTExpiredCursorReturnsSnapshotRecoveryContract() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "project-rest-expired", requestDigest: "project-rest-expired")
        let metadata = try await store.metadata()
        _ = try await store.archiveEvents(through: 1)
        let instant = Date(timeIntervalSince1970: 1000)
        let key = InternalSigningKey(keyID: "sync-v1", role: .sync, direction: InternalHMACDirection.syncToRepoPrompt, secret: Data("secret".utf8))
        let auth = InternalRequestAuthenticator(keys: [key], store: store, now: { instant })
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: auth, eventSigningKey: responseSigningKey, mutationGate: AuthorityMutationGate())
        let app = Application(router: service.internalRouter())
        let path = "/internal/v1/events?after=\(metadata.storeID.uuidString):0"
        let headers = signedHeaders(method: "GET", path: path, key: key, instant: instant, nonce: "expiredcursorrest1")
        try await app.test(.router) { client in
            try await client.execute(uri: path, method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .gone)
                let payload = try JSONDecoder.serviceDecoder.decode(CursorExpiredResponse.self, from: Data(response.body.readableBytesView))
                XCTAssertEqual(payload.storeID, metadata.storeID)
                XCTAssertEqual(payload.replayFloor, 1)
                XCTAssertEqual(payload.snapshotURL, "/internal/v1/snapshot")
            }
        }
        try await store.close()
    }

    private func recoveredRunningSessions(
        rootCount: Int,
        childrenPerRoot: Int
    ) async throws -> (database: URL, store: SQLiteServiceStore, authority: RepoPromptHeadlessAuthority) {
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let actor = ExternalActor(userID: "u1", username: "alice", displayName: "Alice")
        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let projectCursor = try await store.nextCursor()
        let projectID = UUID()
        let project = ProjectSnapshot(
            projectID: projectID,
            name: "P",
            creator: actor,
            state: .active,
            roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)],
            revision: 1,
            cursor: projectCursor
        )
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        for _ in 0 ..< rootCount {
            let rootID = UUID()
            try await persistRunningSession(store: store, sessionID: rootID, projectID: projectID, parentSessionID: nil, rootSessionID: rootID, actor: actor)
            for _ in 0 ..< childrenPerRoot {
                try await persistRunningSession(store: store, sessionID: UUID(), projectID: projectID, parentSessionID: rootID, rootSessionID: rootID, actor: actor)
            }
        }
        try await store.close(clean: true)
        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        return (database, store, authority)
    }

    private func persistRunningSession(
        store: SQLiteServiceStore,
        sessionID: UUID,
        projectID: UUID,
        parentSessionID: UUID?,
        rootSessionID: UUID,
        actor: ExternalActor
    ) async throws {
        let cursor = try await store.nextCursor()
        let session = SessionSnapshot(
            sessionID: sessionID,
            projectID: projectID,
            parentSessionID: parentSessionID,
            rootSessionID: rootSessionID,
            creator: actor,
            provider: .codex,
            model: nil,
            visibility: .privateSession,
            state: .running,
            runGeneration: 1,
            turnEpoch: 1,
            revision: 2,
            transcript: [],
            interactions: [],
            cursor: cursor
        )
        _ = try await store.persistSession(session, eventType: .sessionResumed, actor: actor, correlationID: UUID(), idempotency: nil)
    }

    private func removeSQLiteFiles(_ database: URL) {
        try? FileManager.default.removeItem(at: database)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
    }

    private func signedHeaders(method: String, path: String, key: InternalSigningKey, instant: Date, nonce: String) -> HTTPFields {
        let timestamp = CanonicalSigning.iso8601String(instant)
        let bodyDigest = CanonicalSigning.bodyDigest(Data())
        let authorizationDigest = CanonicalSigning.bodyDigest(Data())
        let canonical = CanonicalSigning.requestString(method: method, pathAndQuery: path, timestamp: timestamp, nonce: nonce, bodyDigest: bodyDigest, authorizationDecisionDigest: authorizationDigest, keyID: key.keyID)
        var headers = HTTPFields()
        headers[.init("x-internal-key-id")!] = key.keyID
        headers[.init("x-internal-timestamp")!] = timestamp
        headers[.init("x-internal-nonce")!] = nonce
        headers[.init("x-internal-body-digest")!] = bodyDigest
        headers[.init("x-internal-authorization-digest")!] = authorizationDigest
        headers[.init("x-internal-signature")!] = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
        return headers
    }
}

private actor CountingUnavailableProviderRuntime: AgentProviderRuntime {
    let kind: ProviderKind
    private var count = 0

    init(kind: ProviderKind) {
        self.kind = kind
    }

    func capability() -> ProviderCapability {
        .init(kind: kind, enabled: true, executable: "/usr/bin/true", supportsResume: true, supportsSteering: true, protocolVersion: "unavailable")
    }

    func preflight() async -> ProviderCapability {
        count += 1
        try? await Task.sleep(for: .milliseconds(200))
        return .init(kind: kind, enabled: false, executable: "/usr/bin/true", supportsResume: true, supportsSteering: true, protocolVersion: "unavailable", reasonUnavailable: "Provider handshake failed")
    }

    func preflightCount() -> Int { count }

    func execute(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        throw ServiceAPIError(code: .dependencyUnavailable, message: "provider unavailable")
    }

    func interrupt(runID _: UUID) {}
}
