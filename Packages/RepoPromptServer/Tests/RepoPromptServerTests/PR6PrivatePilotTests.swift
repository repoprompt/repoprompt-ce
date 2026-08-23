import Foundation
import XCTest
@testable import RepoPromptServerExecutable
@testable import RepoPromptServerHost
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence

final class SchemaV9MigrationTests: XCTestCase {
    func testFreshStoreActivatesImmutableV9Shape() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }

        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 9)
        XCTAssertEqual(SchemaV9.definition.computedDigest, SchemaV9.canonicalDigest)
        let database = await store.database
        let names = try await database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('operator_auth_throttle_buckets','operator_security_audit','operator_session_metadata','maintenance_receipts') ORDER BY name"
        ).compactMap { $0.column("name")?.string }
        XCTAssertEqual(names, [
            "maintenance_receipts",
            "operator_auth_throttle_buckets",
            "operator_security_audit",
            "operator_session_metadata",
        ])
        let digest = try await database.query("SELECT digest FROM schema_migrations WHERE version=9").first?.column("digest")?.string
        XCTAssertEqual(digest, SchemaV9.canonicalDigest)
    }

    func testV8ToV9MigrationPreservesAccountAndSessionAndImportsBackupProvenance() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory("v8-v9-state")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        var store = try await SQLiteServiceStore.open(storage: .file(databaseURL.path))
        let setup = try await store.issueOperatorSetupToken()
        try await store.createOperatorAccount(password: "migration-password", setupToken: setup)
        let token = try await store.createOperatorSession()

        let initialDatabase = await store.database
        _ = try await initialDatabase.query("UPDATE operator_sessions SET created_at='2026-08-20 12:34:56'")
        for table in [
            "maintenance_receipts",
            "operator_session_metadata",
            "operator_security_audit",
            "operator_auth_throttle_buckets",
        ] {
            _ = try await initialDatabase.query("DROP TABLE \(table)")
        }
        _ = try await initialDatabase.query("DELETE FROM schema_migrations WHERE version=9")
        _ = try await initialDatabase.query("UPDATE service_metadata SET schema_version=8 WHERE fixed_id=1")
        try await store.close(clean: false)

        store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let source = try await store.migrationSourceEvidence()
        let result = try await store.migrateToLatest(
            verifiedBackup: .init(
                source: source,
                archiveSHA256: String(repeating: "a", count: 64),
                manifestSHA256: String(repeating: "b", count: 64),
                verifierFingerprint: String(repeating: "c", count: 64),
                recipientFingerprints: ["age:x25519:test"],
                sidecarSHA256: String(repeating: "d", count: 64),
                toolVersion: "test-tool",
                toolDigest: String(repeating: "e", count: 64)
            ),
            namespaceKind: "server",
            databaseIdentityDigest: StoreMigrationTestSupport.namespace(root: root).namespaceID
        )
        XCTAssertEqual(result.schemaVersion, 9)
        let passwordValid = try await store.verifyOperatorPassword(password: "migration-password")
        let sessionUsername = try await store.operatorSessionUsername(token: token)
        XCTAssertTrue(passwordValid)
        XCTAssertEqual(sessionUsername, SQLiteServiceStore.defaultOperatorUsername)
        let migratedSessions = try await store.operatorSessions(currentToken: token)
        XCTAssertGreaterThan(migratedSessions.first?.issuedAt.timeIntervalSince1970 ?? 0, 1_700_000_000)
        let receipts = try await store.maintenanceReceipts()
        XCTAssertEqual(receipts.first?.operation, "migrationVerify")
        XCTAssertEqual(receipts.first?.recipientFingerprints, ["age:x25519:test"])
        try await store.close(clean: false)
    }
}

final class PortalSecurityTests: XCTestCase {
    func testLoginThrottlePersistsAcrossRestartAndUsesNoRawIdentity() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory("throttle-restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("repoprompt.sqlite")
        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let now = Date(timeIntervalSince1970: 10_000)
        for _ in 0 ..< 5 {
            _ = try await store.recordOperatorAuthenticationResult(
                scope: .login,
                clientIdentityDigest: "keyed-client-digest",
                usernameDigest: "keyed-username-digest",
                succeeded: false,
                now: now
            )
        }
        try await store.close(clean: false)

        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let admission = try await store.operatorAuthenticationAdmission(
            scope: .login,
            clientIdentityDigest: "keyed-client-digest",
            usernameDigest: "keyed-username-digest",
            now: now.addingTimeInterval(1)
        )
        XCTAssertFalse(admission.allowed)
        XCTAssertEqual(admission.retryAfterSeconds, 59)
        let reopenedDatabase = await store.database
        let row = try await reopenedDatabase.query("SELECT client_identity_digest,username_digest FROM operator_auth_throttle_buckets").first
        XCTAssertEqual(row?.column("client_identity_digest")?.string, "keyed-client-digest")
        XCTAssertEqual(row?.column("username_digest")?.string, "keyed-username-digest")
        try await store.close(clean: false)
    }

    func testPasswordChangeRevokesPriorSessionsAndRevokeAllPreservesCurrentSession() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let setup = try await store.issueOperatorSetupToken()
        try await store.createOperatorAccount(password: "initial-password", setupToken: setup)
        let prior1 = try await store.createOperatorSession()
        let prior2 = try await store.createOperatorSession()
        let replacement = try await store.changeOperatorPassword(
            authorizingToken: prior1,
            currentPassword: "initial-password",
            newPassword: "replacement-password",
            clientIdentityDigest: "client-digest",
            correlationID: UUID()
        )
        let priorUsername1 = try await store.operatorSessionUsername(token: prior1)
        let priorUsername2 = try await store.operatorSessionUsername(token: prior2)
        let replacementUsername = try await store.operatorSessionUsername(token: replacement)
        let passwordValid = try await store.verifyOperatorPassword(password: "replacement-password")
        let other = try await store.createOperatorSession()
        let revoked = try await store.revokeAllOperatorSessions(reason: "test", exceptToken: replacement)
        let retainedUsername = try await store.operatorSessionUsername(token: replacement)
        let revokedOtherUsername = try await store.operatorSessionUsername(token: other)
        let sessions = try await store.operatorSessions(currentToken: replacement)
        XCTAssertNil(priorUsername1)
        XCTAssertNil(priorUsername2)
        XCTAssertNotNil(replacementUsername)
        XCTAssertTrue(passwordValid)
        XCTAssertEqual(revoked, 1)
        XCTAssertNotNil(retainedUsername)
        XCTAssertNil(revokedOtherUsername)
        XCTAssertTrue(sessions.contains(where: \.current))
    }

    func testSuccessfulLoginCreatesSessionClearsThrottleAndAuditsInOneTransaction() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let setup = try await store.issueOperatorSetupToken()
        try await store.createOperatorAccount(password: "login-password", setupToken: setup)
        _ = try await store.recordOperatorAuthenticationResult(
            scope: .login,
            clientIdentityDigest: "client-digest",
            usernameDigest: "username-digest",
            succeeded: false
        )

        let token = try await store.authenticateOperatorAndCreateSession(
            password: "login-password",
            clientIdentityDigest: "client-digest",
            usernameDigest: "username-digest",
            correlationID: UUID()
        )

        let authenticatedUsername: String? = if let token {
            try await store.operatorSessionUsername(token: token)
        } else {
            nil
        }
        XCTAssertNotNil(token)
        XCTAssertNotNil(authenticatedUsername)
        let database = await store.database
        let throttleCount = try await database.query(
            "SELECT COUNT(*) AS count FROM operator_auth_throttle_buckets"
        ).first?.column("count")?.integer
        let auditOperation = try await store.operatorSecurityAudit().first?.operation
        XCTAssertEqual(throttleCount, 0)
        XCTAssertEqual(auditOperation, "login")
    }
}

final class TrustedProxyIntegrationTests: XCTestCase {
    func testCSRFUsesValidatedTrustedProxyPublicOriginNotBackendAuthority() throws {
        let policy = try PortalNetworkPolicy(.trustedProxy(
            publicOrigin: "https://pilot.example.test:9443",
            trustedProxyCIDRs: ["127.0.0.0/8"]
        ))
        let identity = try policy.resolve(
            immediatePeer: "127.0.0.1",
            forwarded: nil,
            forwardedFor: "203.0.113.8",
            forwardedProto: "https",
            forwardedHost: "pilot.example.test:9443",
            realIP: nil
        )
        let publicOrigin = try XCTUnwrap(identity.publicOrigin)
        XCTAssertNoThrow(try RepoPromptPortalRequestProtection.validateMutation(
            origin: publicOrigin,
            expectedOrigin: publicOrigin,
            fetchSite: "same-origin",
            contentType: "application/json",
            csrfHeader: "1"
        ))
        XCTAssertThrowsError(try RepoPromptPortalRequestProtection.validateMutation(
            origin: "http://127.0.0.1:9081",
            expectedOrigin: publicOrigin,
            fetchSite: "same-origin",
            contentType: "application/json",
            csrfHeader: "1"
        ))
    }

    func testDirectTLSRejectsAllForwardedIdentityHeaders() throws {
        let policy = try PortalNetworkPolicy(.directTLS)
        XCTAssertThrowsError(try policy.resolve(
            immediatePeer: "127.0.0.1",
            forwarded: nil,
            forwardedFor: "203.0.113.5",
            forwardedProto: nil,
            forwardedHost: nil,
            realIP: nil
        ))
    }

    func testTrustedProxyAcceptsOnlySingleHopHTTPSPublicOriginFromCIDR() throws {
        let policy = try PortalNetworkPolicy(.trustedProxy(
            publicOrigin: "https://pilot.example.test:9443",
            trustedProxyCIDRs: ["127.0.0.0/8", "2001:db8::/32"]
        ))
        let identity = try policy.resolve(
            immediatePeer: "127.0.0.2",
            forwarded: nil,
            forwardedFor: "203.0.113.8",
            forwardedProto: "https",
            forwardedHost: "pilot.example.test:9443",
            realIP: nil
        )
        XCTAssertEqual(identity.clientAddress, "203.0.113.8")
        XCTAssertEqual(identity.publicOrigin, "https://pilot.example.test:9443")

        XCTAssertThrowsError(try policy.resolve(
            immediatePeer: "192.0.2.10",
            forwarded: nil,
            forwardedFor: "203.0.113.8",
            forwardedProto: "https",
            forwardedHost: "pilot.example.test:9443",
            realIP: nil
        ))
        XCTAssertThrowsError(try policy.resolve(
            immediatePeer: "127.0.0.2",
            forwarded: nil,
            forwardedFor: "203.0.113.8, 198.51.100.1",
            forwardedProto: "https",
            forwardedHost: "pilot.example.test:9443",
            realIP: nil
        ))
        XCTAssertThrowsError(try policy.resolve(
            immediatePeer: "127.0.0.2",
            forwarded: nil,
            forwardedFor: "203.0.113.8",
            forwardedProto: "http",
            forwardedHost: "pilot.example.test:9443",
            realIP: nil
        ))
    }
}

final class BackupKeyCustodyRotationTests: XCTestCase {
    func testV9ReceiptPreservesOnlyRecipientFingerprintsAndOperationalStatus() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let metadata = try await store.metadata()
        let source = MigrationSourceEvidence(
            storeID: metadata.storeID,
            schemaVersion: metadata.schemaVersion,
            nextGlobalSequence: metadata.nextGlobalSequence,
            sqliteSHA256: String(repeating: "a", count: 64),
            migrationLedgerSHA256: String(repeating: "b", count: 64)
        )
        try await store.recordMaintenanceReceipt(
            operation: "backupCreate",
            outcome: "success",
            archiveSHA256: String(repeating: "c", count: 64),
            manifestSHA256: String(repeating: "d", count: 64),
            source: source,
            verifierFingerprint: nil,
            recipientFingerprints: ["age:x25519:custodian-a", "age:x25519:custodian-b"],
            sidecarSHA256: String(repeating: "e", count: 64),
            toolVersion: "test",
            toolDigest: String(repeating: "f", count: 64),
            now: Date(timeIntervalSince1970: 20_000)
        )
        let receipts = try await store.maintenanceReceipts()
        XCTAssertEqual(receipts.first?.recipientFingerprints, ["age:x25519:custodian-a", "age:x25519:custodian-b"])
        let operational = try await store.operationalSnapshot(now: Date(timeIntervalSince1970: 20_001))
        XCTAssertEqual(operational.maintenanceReceiptCount, 1)
        XCTAssertEqual(operational.securityAuditCount, 3)
        XCTAssertEqual(operational.lastSuccessfulBackupAt, Date(timeIntervalSince1970: 20_000))
    }
}

final class PrivatePilotPortalAssetTests: XCTestCase {
    func testPortalExposesAccountAndOperationsWithoutBrowserPersistence() throws {
        let html = try String(decoding: RepoPromptPortalAssets.data(for: .index), as: UTF8.self)
        let script = try String(decoding: RepoPromptPortalAssets.data(for: .script), as: UTF8.self)

        XCTAssertTrue(html.contains("#settings/operator-account"))
        XCTAssertTrue(html.contains("#settings/operations"))
        for path in [
            "api/v1/account/password",
            "api/v1/account/sessions",
            "api/v1/account/sessions/revoke-all",
            "api/v1/logout",
            "api/v1/operations",
        ] {
            XCTAssertTrue(script.contains(path), "missing private-pilot portal path: \(path)")
        }
        XCTAssertTrue(script.contains("dataset.sensitive"))
        XCTAssertTrue(html.contains("id=\"auth-token\" name=\"setupToken\" type=\"password\""))
        XCTAssertGreaterThanOrEqual(html.components(separatedBy: "data-sensitive=\"true\"").count - 1, 3)
        XCTAssertTrue(script.contains("function clearAuthenticationSecrets()"))
        XCTAssertTrue(script.contains("const logout = element(\"button\", \"danger-button\", \"Logout\")"))
        XCTAssertTrue(script.contains("logout.addEventListener(\"click\", () => logoutOperator(logout))"))
        XCTAssertTrue(script.contains("() => api(\"api/v1/logout\", { method: \"POST\" })"))
        XCTAssertTrue(script.contains("state.logoutPromise = terminatePortalSession("))
        XCTAssertTrue(script.contains("const authenticationGeneration ="))
        XCTAssertTrue(script.contains("await fenceAuthenticatedPortalResponse("))
        XCTAssertTrue(script.contains("function installPortalAuthenticationSubmission("))
        XCTAssertTrue(script.contains("const mode = state.authenticationMode"))
        XCTAssertTrue(script.contains("presentPortalAuthenticationMode(state, document, status)"))
        XCTAssertTrue(script.contains("if (state.authenticationSubmitInstalled) return false;"))
        XCTAssertTrue(script.contains("function invalidatePortalLoadState(state)"))
        XCTAssertTrue(script.contains("return runPortalLoad(state, authenticationGeneration, setLoading"))
        XCTAssertTrue(script.contains("if (state.loadOperation === load)"))
        XCTAssertTrue(script.contains("resetAuthenticatedPortalState(state, document, location"))
        XCTAssertTrue(script.contains("state.operatorAuthenticated = false"))
        XCTAssertTrue(script.contains("app.setAttribute(\"aria-hidden\", \"true\")"))
        XCTAssertTrue(script.contains("finally {\n        clearSecrets();"))
        XCTAssertTrue(script.contains("if (state.route !== nextRoute) disposeSensitiveInputs();"))
        XCTAssertTrue(script.contains("window.RepoPromptPortalTest = Object.freeze({"))
        XCTAssertTrue(script.contains("if (!window.__REPOPROMPT_PORTAL_TEST_HOOK__?.deferStart) start();"))
        XCTAssertTrue(script.contains("owner-only operator-setup-token file"))
        XCTAssertTrue(script.contains("never written to server logs"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("sessionStorage"))
    }
}

final class PrivatePilotConfigurationTests: XCTestCase {
    func testPlaintextPortalRejectsNonLoopbackAndMissingTrustedProxy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = [
            "REPOPROMPT_STATE_DB": root.appendingPathComponent("repoprompt.sqlite").path,
            "REPOPROMPT_ENABLED_PROVIDERS": "",
            "REPOPROMPT_PORTAL_PORT": "9081",
        ]
        XCTAssertThrowsError(try RepoPromptServerConfiguration.environment(environment))

        environment["REPOPROMPT_PUBLIC_ORIGIN"] = "https://pilot.example.test"
        environment["REPOPROMPT_TRUSTED_PROXY_CIDRS"] = "127.0.0.0/8"
        environment["REPOPROMPT_PORTAL_HOST"] = "0.0.0.0"
        XCTAssertThrowsError(try RepoPromptServerConfiguration.environment(environment))

        environment["REPOPROMPT_PORTAL_HOST"] = "127.0.0.1"
        let configuration = try RepoPromptServerConfiguration.environment(environment)
        XCTAssertEqual(configuration.portalPort, 9081)
    }

    func testOwnerOnlySecretWriterPublishesMode0600BeforeUse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("operator-setup-token")

        try writeOwnerOnlySecret(Data("secret-value\n".utf8), to: destination)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        XCTAssertEqual(try Data(contentsOf: destination), Data("secret-value\n".utf8))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.hasSuffix(".tmp") }
        )
    }
}

final class OperatorRecoveryTests: XCTestCase {
    func testOfflineResetRevokesEverySessionAndAuditsWithoutPassword() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let setup = try await store.issueOperatorSetupToken()
        try await store.createOperatorAccount(password: "before-reset", setupToken: setup)
        let token = try await store.createOperatorSession()
        try await store.resetOperatorPasswordOffline(newPassword: "after-reset-password")
        let sessionUsername = try await store.operatorSessionUsername(token: token)
        let passwordValid = try await store.verifyOperatorPassword(password: "after-reset-password")
        XCTAssertNil(sessionUsername)
        XCTAssertTrue(passwordValid)
        let audit = try await store.operatorSecurityAudit()
        XCTAssertEqual(audit.first?.operation, "passwordReset")
        XCTAssertFalse(String(describing: audit).contains("after-reset-password"))
    }
}
