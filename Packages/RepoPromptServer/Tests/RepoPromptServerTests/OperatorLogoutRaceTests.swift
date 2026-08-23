import Foundation
@testable import RepoPromptServicePersistence
import XCTest

private struct InjectedLogoutRaceFailure: Error {}

private actor PasswordRotationGate {
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        blocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

final class OperatorLogoutRaceTests: XCTestCase {
    func testLogoutCommitBeforePasswordRotationRejectsReplacementAndKeepsAuditsAtomic() async throws {
        let (store, token) = try await makeStore(password: "initial-password")
        defer { Task { try? await store.close() } }
        let gate = PasswordRotationGate()
        let passwordCorrelationID = UUID()
        let logoutCorrelationID = UUID()

        let rotation = Task {
            try await store.changeOperatorPassword(
                authorizingToken: token,
                currentPassword: "initial-password",
                newPassword: "replacement-password",
                clientIdentityDigest: "rotation-client",
                correlationID: passwordCorrelationID,
                operationObserver: { phase in
                    if phase == "before-password-transaction" { await gate.block() }
                }
            )
        }
        await gate.waitUntilBlocked()
        let revoked = try await store.logoutOperatorSession(
            token: token,
            clientIdentityDigest: "logout-client",
            correlationID: logoutCorrelationID
        )
        await gate.release()

        do {
            _ = try await rotation.value
            XCTFail("password rotation should reject a session revoked by overlapping logout")
        } catch {}

        let originalAuthentication = try await store.operatorSessionUsername(token: token)
        let originalPasswordValid = try await store.verifyOperatorPassword(password: "initial-password")
        let replacementPasswordValid = try await store.verifyOperatorPassword(password: "replacement-password")
        let database = await store.database
        let liveSessionCount = try await count(database, table: "operator_sessions")
        let logoutSuccessCount = try await auditCount(database, operation: "logout", outcome: "success", correlationID: logoutCorrelationID)
        let passwordSuccessCount = try await auditCount(database, operation: "passwordChange", outcome: "success", correlationID: passwordCorrelationID)
        let passwordFailureCount = try await auditCount(database, operation: "passwordChange", outcome: "failure", correlationID: passwordCorrelationID)
        XCTAssertTrue(revoked)
        XCTAssertNil(originalAuthentication)
        XCTAssertTrue(originalPasswordValid)
        XCTAssertFalse(replacementPasswordValid)
        XCTAssertEqual(liveSessionCount, 0)
        XCTAssertEqual(logoutSuccessCount, 1)
        XCTAssertEqual(passwordSuccessCount, 0)
        XCTAssertEqual(passwordFailureCount, 1)
    }

    func testPasswordRotationCommitBeforeLogoutMakesLateReplacementTerminal() async throws {
        let (store, token) = try await makeStore(password: "initial-password")
        defer { Task { try? await store.close() } }
        let gate = PasswordRotationGate()
        let passwordCorrelationID = UUID()
        let logoutCorrelationID = UUID()

        let rotation = Task {
            try await store.changeOperatorPassword(
                authorizingToken: token,
                currentPassword: "initial-password",
                newPassword: "replacement-password",
                clientIdentityDigest: "rotation-client",
                correlationID: passwordCorrelationID,
                operationObserver: { phase in
                    if phase == "after-password-commit" { await gate.block() }
                }
            )
        }
        await gate.waitUntilBlocked()
        let originalAuthenticationAfterRotation = try await store.operatorSessionUsername(token: token)
        XCTAssertNil(originalAuthenticationAfterRotation)
        let revoked = try await store.logoutOperatorSession(
            token: token,
            clientIdentityDigest: "logout-client",
            correlationID: logoutCorrelationID
        )
        await gate.release()
        let lateReplacement = try await rotation.value

        let lateReplacementAuthentication = try await store.operatorSessionUsername(token: lateReplacement)
        let replacementPasswordValid = try await store.verifyOperatorPassword(password: "replacement-password")
        let database = await store.database
        let liveSessionCount = try await count(database, table: "operator_sessions")
        let logoutSuccessCount = try await auditCount(database, operation: "logout", outcome: "success", correlationID: logoutCorrelationID)
        let passwordSuccessCount = try await auditCount(database, operation: "passwordChange", outcome: "success", correlationID: passwordCorrelationID)
        XCTAssertTrue(revoked)
        XCTAssertNotEqual(lateReplacement, token)
        XCTAssertNil(lateReplacementAuthentication)
        XCTAssertTrue(replacementPasswordValid)
        XCTAssertEqual(liveSessionCount, 0)
        XCTAssertEqual(logoutSuccessCount, 1)
        XCTAssertEqual(passwordSuccessCount, 1)
        let metadata = try await database.query(
            "SELECT revoked_at,revocation_reason FROM operator_session_metadata WHERE correlation_id=?",
            [.text(passwordCorrelationID.uuidString.lowercased())]
        )
        XCTAssertEqual(metadata.count, 2)
        XCTAssertTrue(metadata.allSatisfy { $0.column("revoked_at")?.double != nil })
        XCTAssertTrue(metadata.allSatisfy { $0.column("revocation_reason")?.string == "logout" })
    }

    func testRotationLineageLogoutFaultsRollbackTokenMetadataAndAuditBeforeRetry() async throws {
        for faultPoint in [
            "after-metadata-revocation",
            "after-token-deletion",
            "after-audit-insert"
        ] {
            let (store, token) = try await makeStore(password: "initial-password")
            let passwordCorrelationID = UUID()
            let replacement = try await store.changeOperatorPassword(
                authorizingToken: token,
                currentPassword: "initial-password",
                newPassword: "replacement-password",
                clientIdentityDigest: "rotation-client",
                correlationID: passwordCorrelationID
            )
            let logoutCorrelationID = UUID()

            do {
                _ = try await store.logoutOperatorSession(
                    token: token,
                    clientIdentityDigest: "logout-client",
                    correlationID: logoutCorrelationID,
                    faultInjector: { phase in
                        if phase == faultPoint { throw InjectedLogoutRaceFailure() }
                    }
                )
                XCTFail("expected injected lineage logout failure at \(faultPoint)")
            } catch is InjectedLogoutRaceFailure {}

            let replacementAuthenticationAfterFailure = try await store.operatorSessionUsername(token: replacement)
            let originalAuthenticationAfterFailure = try await store.operatorSessionUsername(token: token)
            let database = await store.database
            let sessionCountAfterFailure = try await count(database, table: "operator_sessions")
            let auditCountAfterFailure = try await auditCount(
                database,
                operation: "logout",
                outcome: "success",
                correlationID: logoutCorrelationID
            )
            XCTAssertEqual(replacementAuthenticationAfterFailure, SQLiteServiceStore.defaultOperatorUsername, faultPoint)
            XCTAssertNil(originalAuthenticationAfterFailure, faultPoint)
            XCTAssertEqual(sessionCountAfterFailure, 2, faultPoint)
            XCTAssertEqual(auditCountAfterFailure, 0, faultPoint)
            let linkedAfterFailure = try await database.query(
                "SELECT revoked_at,revocation_reason FROM operator_session_metadata WHERE correlation_id=?",
                [.text(passwordCorrelationID.uuidString.lowercased())]
            )
            XCTAssertEqual(linkedAfterFailure.count, 2, faultPoint)
            XCTAssertEqual(linkedAfterFailure.count(where: { $0.column("revoked_at")?.double == nil }), 1, faultPoint)

            let retryRevoked = try await store.logoutOperatorSession(
                token: token,
                clientIdentityDigest: "logout-client",
                correlationID: logoutCorrelationID
            )
            let replacementAuthenticationAfterRetry = try await store.operatorSessionUsername(token: replacement)
            let sessionCountAfterRetry = try await count(database, table: "operator_sessions")
            let auditCountAfterRetry = try await auditCount(
                database,
                operation: "logout",
                outcome: "success",
                correlationID: logoutCorrelationID
            )
            XCTAssertTrue(retryRevoked)
            XCTAssertNil(replacementAuthenticationAfterRetry, faultPoint)
            XCTAssertEqual(sessionCountAfterRetry, 0, faultPoint)
            XCTAssertEqual(auditCountAfterRetry, 1, faultPoint)
            try await store.close(clean: false)
        }
    }

    private func makeStore(password: String) async throws -> (SQLiteServiceStore, String) {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let setupToken = try await store.issueOperatorSetupToken()
        let token = try await store.createOperatorAccountAndSession(
            password: password,
            setupToken: setupToken,
            clientIdentityDigest: "setup-client",
            usernameDigest: "setup-username",
            correlationID: UUID()
        )
        return (store, token)
    }

    private func count(_ database: SQLiteDatabaseExecutor, table: String) async throws -> Int {
        try await database.query("SELECT COUNT(*) AS count FROM \(table)").first?.column("count")?.integer ?? -1
    }

    private func auditCount(
        _ database: SQLiteDatabaseExecutor,
        operation: String,
        outcome: String,
        correlationID: UUID
    ) async throws -> Int {
        try await database.query(
            "SELECT COUNT(*) AS count FROM operator_security_audit WHERE operation=? AND outcome=? AND correlation_id=?",
            [.text(operation), .text(outcome), .text(correlationID.uuidString.lowercased())]
        ).first?.column("count")?.integer ?? -1
    }
}
