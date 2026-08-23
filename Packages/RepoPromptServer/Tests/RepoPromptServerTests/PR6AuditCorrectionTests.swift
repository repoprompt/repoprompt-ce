import Foundation
import RepoPromptRuntimeModel
import XCTest
@testable import RepoPromptServerHost
@testable import RepoPromptServicePersistence

private struct InjectedPR6AuditFailure: Error {}

final class PR6AuditCorrectionTests: XCTestCase {
    func testLogoutRollbackRetryAndIdempotencyKeepTokenMetadataAndAuditAtomic() async throws {
        for faultPoint in [
            "after-metadata-revocation",
            "after-token-deletion",
            "after-audit-insert",
        ] {
            let root = try StoreMigrationTestSupport.temporaryDirectory("logout-\(faultPoint)")
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
            var store = try await SQLiteServiceStore.open(storage: .file(databaseURL.path))
            let setupToken = try await store.issueOperatorSetupToken()
            try await store.createOperatorAccount(password: "logout-atomic-password", setupToken: setupToken)
            let token = try await store.createOperatorSession()
            let issuedSessions = try await store.operatorSessions(currentToken: token)
            let target = try XCTUnwrap(issuedSessions.first(where: \.current))
            let correlationID = UUID()
            let now = Date(timeIntervalSince1970: 50_000)

            do {
                try await store.logoutOperatorSession(
                    token: token,
                    clientIdentityDigest: "logout-client-digest",
                    correlationID: correlationID,
                    now: now,
                    faultInjector: { observed in
                        if observed == faultPoint { throw InjectedPR6AuditFailure() }
                    }
                )
                XCTFail("expected injected logout failure at \(faultPoint)")
            } catch is InjectedPR6AuditFailure {}
            try await store.close(clean: false)

            store = try await SQLiteServiceStore.open(storage: .file(databaseURL.path))
            let database = await store.database
            let liveAfterFailure = try await database.query(
                "SELECT COUNT(*) AS count FROM operator_sessions WHERE session_id=?",
                [.text(target.sessionID.uuidString.lowercased())]
            ).first?.column("count")?.integer
            let metadataAfterFailure = try await database.query(
                "SELECT revoked_at,revocation_reason FROM operator_session_metadata WHERE session_id=?",
                [.text(target.sessionID.uuidString.lowercased())]
            ).first
            let auditAfterFailure = try await database.query(
                "SELECT COUNT(*) AS count FROM operator_security_audit WHERE operation='logout' AND correlation_id=?",
                [.text(correlationID.uuidString.lowercased())]
            ).first?.column("count")?.integer
            XCTAssertEqual(liveAfterFailure, 1, faultPoint)
            XCTAssertNil(metadataAfterFailure?.column("revoked_at")?.double, faultPoint)
            XCTAssertNil(metadataAfterFailure?.column("revocation_reason")?.string, faultPoint)
            XCTAssertEqual(auditAfterFailure, 0, faultPoint)
            let authenticatedAfterFailure = try await store.operatorSessionUsername(token: token)
            XCTAssertEqual(authenticatedAfterFailure, SQLiteServiceStore.defaultOperatorUsername, faultPoint)

            let revoked = try await store.logoutOperatorSession(
                token: token,
                clientIdentityDigest: "logout-client-digest",
                correlationID: correlationID,
                now: now
            )
            XCTAssertTrue(revoked, faultPoint)
            let authenticatedAfterCommit = try await store.operatorSessionUsername(token: token)
            XCTAssertNil(authenticatedAfterCommit, faultPoint)
            let liveAfterCommit = try await database.query(
                "SELECT COUNT(*) AS count FROM operator_sessions WHERE session_id=?",
                [.text(target.sessionID.uuidString.lowercased())]
            ).first?.column("count")?.integer
            let metadataAfterCommit = try await database.query(
                "SELECT revoked_at,revocation_reason FROM operator_session_metadata WHERE session_id=?",
                [.text(target.sessionID.uuidString.lowercased())]
            ).first
            let auditAfterCommit = try await database.query(
                "SELECT COUNT(*) AS count FROM operator_security_audit WHERE operation='logout' AND outcome='success' AND correlation_id=? AND detail_code='sessionRevoked'",
                [.text(correlationID.uuidString.lowercased())]
            ).first?.column("count")?.integer
            XCTAssertEqual(liveAfterCommit, 0, faultPoint)
            let revokedAt = try XCTUnwrap(metadataAfterCommit?.column("revoked_at")?.double)
            XCTAssertEqual(revokedAt, now.timeIntervalSince1970, accuracy: 0.001, faultPoint)
            XCTAssertEqual(metadataAfterCommit?.column("revocation_reason")?.string, "logout", faultPoint)
            XCTAssertEqual(auditAfterCommit, 1, faultPoint)

            let idempotentRetry = try await store.logoutOperatorSession(
                token: token,
                clientIdentityDigest: "logout-client-digest",
                correlationID: correlationID,
                now: now.addingTimeInterval(1)
            )
            XCTAssertTrue(idempotentRetry, faultPoint)
            let auditAfterRetry = try await database.query(
                "SELECT COUNT(*) AS count FROM operator_security_audit WHERE operation='logout' AND correlation_id=?",
                [.text(correlationID.uuidString.lowercased())]
            ).first?.column("count")?.integer
            XCTAssertEqual(auditAfterRetry, 1, faultPoint)
            try await store.close(clean: false)
        }
    }

    func testBackupFailureWritesSecretFreeV9SecurityAudit() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory("backup-failure-audit")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try StoreMigrationTestSupport.namespace(root: root)
        let session = try await AuthorityMaintenanceSession.open(
            configuration: .init(namespace: namespace)
        )
        do {
            _ = try await session.createBackup(
                service: StoreMigrationTestSupport.backupService(),
                request: .init(
                    outputURL: root.appendingPathComponent("must-not-exist.tar.age"),
                    recipientsFileURL: root.appendingPathComponent("must-not-be-read.txt"),
                    roots: [],
                    namespaceKind: "server",
                    databaseIdentityDigest: String(repeating: "0", count: 64)
                )
            )
            XCTFail("expected namespace mismatch")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .namespacePurposeMismatch)
        }
        try await session.close(clean: false)

        let store = try await SQLiteServiceStore.openForMaintenance(
            storage: .file(namespace.databasePath)
        )
        let audit = try await store.operatorSecurityAudit(limit: 100)
        XCTAssertTrue(audit.contains {
            $0.operation == "backupCreate"
                && $0.outcome == "failure"
                && $0.detailCode == "namespaceMismatch"
        })
        XCTAssertFalse(String(describing: audit).contains("must-not-be-read"))
        try await store.close(clean: false)
    }

    func testRestoreRequestCannotDecodeWithoutRequiredV9Receipt() throws {
        let requestWithoutReceipt = Data(#"""
        {
          "schemaVersion":1,
          "acknowledged":true,
          "sourceNamespaceKind":"server",
          "sourceDatabaseIdentityDigest":"1111111111111111111111111111111111111111111111111111111111111111",
          "targetNamespaceKind":"server",
          "targetDatabaseIdentityDigest":"2222222222222222222222222222222222222222222222222222222222222222",
          "restoredFromStoreId":"00000000-0000-0000-0000-000000000001",
          "backupSequence":0,
          "backupCreatedAt":"2026-08-21T00:00:00Z",
          "backupManifestSha256":"3333333333333333333333333333333333333333333333333333333333333333",
          "missingExternalOptionalAssetIDs":[]
        }
        """#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RestoreNamespaceRequestV1.self, from: requestWithoutReceipt))
    }

    func testConcurrentAuthenticationReservationsAdmitAtMostFiveAttempts() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let now = Date(timeIntervalSince1970: 30_000)

        let admitted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    try await store.reserveOperatorAuthenticationAttempt(
                        scope: .login,
                        clientIdentityDigest: "concurrent-client-digest",
                        usernameDigest: "concurrent-username-digest",
                        now: now
                    ).allowed
                }
            }
            var results: [Bool] = []
            for try await result in group { results.append(result) }
            return results.filter { $0 }.count
        }

        XCTAssertEqual(admitted, 5)
        let denied = try await store.reserveOperatorAuthenticationAttempt(
            scope: .login,
            clientIdentityDigest: "concurrent-client-digest",
            usernameDigest: "concurrent-username-digest",
            now: now
        )
        XCTAssertFalse(denied.allowed)
        let row = try await store.database.query(
            "SELECT attempt_count FROM operator_auth_throttle_buckets WHERE scope='login'"
        ).first
        XCTAssertEqual(row?.column("attempt_count")?.integer, 5)
    }

    func testSetupTransactionRollsBackTokenAccountSessionAndSuccessAuditTogether() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let setupToken = try await store.issueOperatorSetupToken()
        let secretPassword = "transaction-password"

        do {
            _ = try await store.createOperatorAccountAndSession(
                password: secretPassword,
                setupToken: setupToken,
                clientIdentityDigest: "setup-client-digest",
                usernameDigest: "setup-username-digest",
                correlationID: UUID(),
                faultInjector: { point in
                    if point == "after-session-insert" { throw InjectedPR6AuditFailure() }
                }
            )
            XCTFail("expected setup transaction fault")
        } catch is InjectedPR6AuditFailure {}

        let accountExistsAfterRollback = try await store.hasOperatorAccount()
        XCTAssertFalse(accountExistsAfterRollback)
        let database = await store.database
        let sessionCount = try await database.query("SELECT COUNT(*) AS count FROM operator_sessions")
            .first?.column("count")?.integer
        let consumedAt = try await database.query("SELECT consumed_at FROM operator_setup_tokens")
            .first?.column("consumed_at")?.double
        XCTAssertEqual(sessionCount, 0)
        XCTAssertNil(consumedAt)

        let sessionToken = try await store.createOperatorAccountAndSession(
            password: secretPassword,
            setupToken: setupToken,
            clientIdentityDigest: "setup-client-digest",
            usernameDigest: "setup-username-digest",
            correlationID: UUID()
        )
        let sessionUsername = try await store.operatorSessionUsername(token: sessionToken)
        XCTAssertEqual(sessionUsername, SQLiteServiceStore.defaultOperatorUsername)
        let audit = try await store.operatorSecurityAudit(limit: 100)
        XCTAssertTrue(audit.contains { $0.operation == "setupTokenConsume" && $0.outcome == "success" })
        XCTAssertTrue(audit.contains { $0.operation == "accountCreate" && $0.outcome == "success" })
        XCTAssertTrue(audit.contains { $0.operation == "accountCreate" && $0.outcome == "failure" })
        XCTAssertFalse(String(describing: audit).contains(setupToken))
        XCTAssertFalse(String(describing: audit).contains(secretPassword))
    }

    func testOfflineResetUsesDurableThrottleAndNeverAuditsPassword() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let setupToken = try await store.issueOperatorSetupToken()
        try await store.createOperatorAccount(password: "before-reset-password", setupToken: setupToken)
        let invalidPassword = "short"
        let now = Date(timeIntervalSince1970: 40_000)

        for _ in 0 ..< 5 {
            do {
                try await store.resetOperatorPasswordOffline(newPassword: invalidPassword, now: now)
            } catch {}
        }
        do {
            try await store.resetOperatorPasswordOffline(newPassword: "valid-after-throttle-password", now: now)
            XCTFail("expected durable offline reset throttle")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rateLimited)
        }

        let row = try await store.database.query(
            "SELECT attempt_count FROM operator_auth_throttle_buckets WHERE scope='offlineReset'"
        ).first
        XCTAssertEqual(row?.column("attempt_count")?.integer, 5)
        let audit = try await store.operatorSecurityAudit(limit: 100)
        XCTAssertTrue(audit.contains { $0.operation == "passwordReset" && $0.outcome == "failure" })
        XCTAssertTrue(audit.contains { $0.operation == "passwordReset" && $0.outcome == "rateLimited" })
        XCTAssertFalse(String(describing: audit).contains(invalidPassword))
        XCTAssertFalse(String(describing: audit).contains("valid-after-throttle-password"))
    }

    func testRestoreActivationAndRequiredReceiptRollBackTogetherAtCrashPoint() async throws {
        let sourceDigest = String(repeating: "1", count: 64)
        let targetDigest = String(repeating: "2", count: 64)
        let manifestDigest = String(repeating: "3", count: 64)
        let store = try await SQLiteServiceStore.openForServing(
            storage: .memory,
            namespaceKind: "server",
            databaseIdentityDigest: sourceDigest
        )
        defer { Task { try? await store.close() } }
        let prior = try await store.metadata().storeID
        let receipt = makeTestMaintenanceReceipt(
            storeID: prior,
            backupSequence: 0,
            manifestSHA256: manifestDigest
        )

        do {
            _ = try await store.activateRestoredNamespace(
                from: prior,
                backupSequence: 0,
                manifestDigest: manifestDigest,
                sourceNamespaceKind: "server",
                sourceDatabaseIdentityDigest: sourceDigest,
                targetNamespaceKind: "server",
                targetDatabaseIdentityDigest: targetDigest,
                activationToken: Data(repeating: 7, count: 32),
                instanceID: UUID(),
                maintenanceReceipt: receipt,
                faultInjector: { point in
                    if point == "after-activation-before-receipt" { throw InjectedPR6AuditFailure() }
                }
            )
            XCTFail("expected restore crash point")
        } catch is InjectedPR6AuditFailure {}

        let metadataAfterCrash = try await store.metadata()
        XCTAssertEqual(metadataAfterCrash.storeID, prior)
        let identity = try await store.database.query(
            "SELECT database_identity_digest FROM authority_namespace_identity WHERE fixed_id=1"
        ).first?.column("database_identity_digest")?.string
        XCTAssertEqual(identity, sourceDigest)
        let receiptsAfterCrash = try await store.maintenanceReceipts()
        XCTAssertTrue(receiptsAfterCrash.isEmpty)
        let failureAudit = try await store.operatorSecurityAudit(limit: 100)
        XCTAssertTrue(failureAudit.contains {
            $0.operation == "restorePrepare" && $0.outcome == "failure"
        })

        let fresh = try await store.activateRestoredNamespace(
            from: prior,
            backupSequence: 0,
            manifestDigest: manifestDigest,
            sourceNamespaceKind: "server",
            sourceDatabaseIdentityDigest: sourceDigest,
            targetNamespaceKind: "server",
            targetDatabaseIdentityDigest: targetDigest,
            activationToken: Data(repeating: 7, count: 32),
            instanceID: UUID(),
            maintenanceReceipt: receipt
        )
        XCTAssertNotEqual(fresh, prior)
        let receipts = try await store.maintenanceReceipts()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.operation, "restorePrepare")
    }

    func testV9AuditCoversMigrationSetupAuthPasswordResetAndBackupWithoutSecrets() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let setupToken = try await store.issueOperatorSetupToken()
        let accountPassword = "audit-account-password"
        do {
            try await store.createOperatorAccount(password: accountPassword, setupToken: "invalid-setup-token")
            XCTFail("expected setup token failure")
        } catch {}
        try await store.createOperatorAccount(password: accountPassword, setupToken: setupToken)
        let passwordChangeSession = try await store.createOperatorSession()

        _ = try await store.reserveOperatorAuthenticationAttempt(
            scope: .login,
            clientIdentityDigest: "audit-client-digest",
            usernameDigest: "audit-username-digest"
        )
        _ = try await store.recordReservedOperatorAuthenticationFailure(
            scope: .login,
            clientIdentityDigest: "audit-client-digest",
            usernameDigest: "audit-username-digest",
            auditOperation: "login",
            auditActor: "anonymous",
            auditChannel: "portal",
            correlationID: UUID(),
            detailCode: "credentialsRejected"
        )
        do {
            _ = try await store.changeOperatorPassword(
                authorizingToken: passwordChangeSession,
                currentPassword: "wrong-current-password",
                newPassword: "unused-new-password",
                clientIdentityDigest: "audit-client-digest",
                correlationID: UUID()
            )
            XCTFail("expected password change failure")
        } catch {}
        do {
            try await store.resetOperatorPasswordOffline(newPassword: "short")
            XCTFail("expected reset failure")
        } catch {}

        let metadata = try await store.metadata()
        try await store.recordMaintenanceReceipt(
            operation: "backupCreate",
            outcome: "success",
            archiveSHA256: String(repeating: "4", count: 64),
            manifestSHA256: String(repeating: "5", count: 64),
            source: MigrationSourceEvidence(
                storeID: metadata.storeID,
                schemaVersion: metadata.schemaVersion,
                nextGlobalSequence: metadata.nextGlobalSequence,
                sqliteSHA256: String(repeating: "6", count: 64),
                migrationLedgerSHA256: String(repeating: "7", count: 64)
            ),
            verifierFingerprint: nil,
            recipientFingerprints: ["x25519:audit-recipient"],
            sidecarSHA256: String(repeating: "8", count: 64),
            toolVersion: "test",
            toolDigest: String(repeating: "9", count: 64)
        )

        let audit = try await store.operatorSecurityAudit(limit: 200)
        let outcomes = Set(audit.map { "\($0.operation):\($0.outcome)" })
        for expected in [
            "schemaMigrationV9:started", "schemaMigrationV9:success",
            "setupTokenIssue:success", "setupTokenConsume:failure", "setupTokenConsume:success",
            "login:failure", "passwordChange:failure", "passwordReset:failure", "backupCreate:success",
        ] {
            XCTAssertTrue(outcomes.contains(expected), "missing V9 security audit outcome: \(expected)")
        }
        let serialized = String(describing: audit)
        for secret in [setupToken, accountPassword, "invalid-setup-token", "wrong-current-password", "unused-new-password"] {
            XCTAssertFalse(serialized.contains(secret))
        }
    }
}
