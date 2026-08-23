import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

extension SQLiteServiceStore {
    public static let defaultOperatorUsername = "operator"
    public static let operatorSessionDuration: TimeInterval = 12 * 60 * 60

    public func hasOperatorAccount() async throws -> Bool {
        let count = try await database.query("SELECT COUNT(*) AS count FROM operator_accounts").first?.column("count")?.integer ?? 0
        return count > 0
    }

    public func issueOperatorSetupToken(
        correlationID: UUID = UUID(),
        channel: String = "offline"
    ) async throws -> String {
        let token = OperatorPasswordHasher.randomToken()
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        do {
            try await transaction(.interactive(estimatedEncodedBytes: 0)) {
                _ = try await database.query("DELETE FROM operator_setup_tokens")
                _ = try await database.query(
                    "INSERT INTO operator_setup_tokens(token_hash,created_at) VALUES(?,CURRENT_TIMESTAMP)",
                    [.text(hash)]
                )
                try await appendOperatorSecurityAudit(
                    operation: "setupTokenIssue", outcome: "success", actor: "operator-recovery",
                    channel: channel, clientIdentityDigest: nil, correlationID: correlationID,
                    detailCode: "tokenIssued"
                )
            }
            return token
        } catch {
            try? await appendOperatorSecurityAudit(
                operation: "setupTokenIssue", outcome: "failure", actor: "operator-recovery",
                channel: channel, clientIdentityDigest: nil, correlationID: correlationID,
                detailCode: "tokenIssueFailed"
            )
            throw error
        }
    }

    public func createOperatorAccount(
        username: String = defaultOperatorUsername,
        password: String,
        setupToken: String,
        clientIdentityDigest: String? = nil,
        correlationID: UUID = UUID(),
        channel: String = "portal"
    ) async throws {
        _ = try await createOperatorAccountAndSession(
            username: username,
            password: password,
            setupToken: setupToken,
            clientIdentityDigest: clientIdentityDigest,
            usernameDigest: nil,
            correlationID: correlationID,
            channel: channel
        )
    }

    public func createOperatorAccountAndSession(
        username: String = defaultOperatorUsername,
        password: String,
        setupToken: String,
        clientIdentityDigest: String?,
        usernameDigest: String?,
        correlationID: UUID,
        channel: String = "portal",
        now: Date = Date(),
        faultInjector: (@Sendable (String) throws -> Void)? = nil
    ) async throws -> String {
        do {
            try OperatorPasswordHasher.validate(password)
            let salt = OperatorPasswordHasher.randomSalt()
            let passwordHash = try OperatorPasswordHasher.hash(password: password, salt: salt)
            let sessionToken = OperatorPasswordHasher.randomToken() + OperatorPasswordHasher.randomToken()
            let sessionHash = OperatorPasswordHasher.sha256Hex(Data(sessionToken.utf8))
            let sessionID = UUID()
            let expiresAt = now.addingTimeInterval(Self.operatorSessionDuration)
            return try await transaction(.interactive(estimatedEncodedBytes: 0)) {
                guard try await database.query(
                    "SELECT 1 FROM operator_accounts LIMIT 1"
                ).isEmpty else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Operator account already exists")
                }
                try await consumeSetupToken(
                    setupToken,
                    clientIdentityDigest: clientIdentityDigest,
                    correlationID: correlationID,
                    channel: channel,
                    now: now
                )
                _ = try await database.query(
                    "INSERT INTO operator_accounts(username,password_salt,password_hash,iterations,created_at) VALUES(?,?,?,?,?)",
                    [
                        .text(username), .text(salt.base64EncodedString()),
                        .text(passwordHash.base64EncodedString()),
                        .integer(OperatorPasswordHasher.iterations), .float(now.timeIntervalSince1970),
                    ]
                )
                try faultInjector?("after-account-insert")
                _ = try await database.query(
                    "INSERT INTO operator_sessions(session_id,username,token_hash,created_at,expires_at) VALUES(?,?,?,?,?)",
                    [
                        .text(sessionID.uuidString.lowercased()), .text(username), .text(sessionHash),
                        .float(now.timeIntervalSince1970), .float(expiresAt.timeIntervalSince1970),
                    ]
                )
                _ = try await database.query(
                    "INSERT INTO operator_session_metadata(session_id,username,issued_at,last_seen_at,client_identity_digest,correlation_id) VALUES(?,?,?,?,?,?)",
                    [
                        .text(sessionID.uuidString.lowercased()), .text(username), .float(now.timeIntervalSince1970),
                        .float(now.timeIntervalSince1970), clientIdentityDigest.map { .text($0) } ?? .null,
                        .text(correlationID.uuidString.lowercased()),
                    ]
                )
                try faultInjector?("after-session-insert")
                if let clientIdentityDigest, let usernameDigest {
                    try await clearOperatorAuthenticationThrottle(
                        scope: .setup,
                        clientIdentityDigest: clientIdentityDigest,
                        usernameDigest: usernameDigest
                    )
                }
                try await appendOperatorSecurityAudit(
                    operation: "accountCreate", outcome: "success", actor: "operator:\(username)",
                    channel: channel, clientIdentityDigest: clientIdentityDigest,
                    correlationID: correlationID, now: now
                )
                try await appendOperatorSecurityAudit(
                    operation: "setup", outcome: "success", actor: "operator:\(username)",
                    channel: channel, clientIdentityDigest: clientIdentityDigest,
                    correlationID: correlationID, now: now
                )
                return sessionToken
            }
        } catch {
            try? await appendOperatorSecurityAudit(
                operation: "accountCreate", outcome: "failure", actor: "anonymous",
                channel: channel, clientIdentityDigest: clientIdentityDigest,
                correlationID: correlationID, detailCode: "setupTransactionRejected", now: now
            )
            try? await appendOperatorSecurityAudit(
                operation: "setupTokenConsume", outcome: "failure", actor: "anonymous",
                channel: channel, clientIdentityDigest: clientIdentityDigest,
                correlationID: correlationID, detailCode: "setupTokenRejected", now: now
            )
            throw error
        }
    }

    public func verifyOperatorPassword(username: String = defaultOperatorUsername, password: String) async throws -> Bool {
        guard let row = try await database.query(
            "SELECT password_salt,password_hash,iterations FROM operator_accounts WHERE username=?",
            [.text(username)]
        ).first,
              let salt = Data(base64Encoded: row.column("password_salt")?.string ?? ""),
              let hash = Data(base64Encoded: row.column("password_hash")?.string ?? ""),
              let iterations = row.column("iterations")?.integer
        else { return false }
        return OperatorPasswordHasher.verify(password, salt: salt, hash: hash, iterations: iterations)
    }

    public func authenticateOperatorAndCreateSession(
        username: String = defaultOperatorUsername,
        password: String,
        clientIdentityDigest: String,
        usernameDigest: String,
        correlationID: UUID,
        now: Date = Date()
    ) async throws -> String? {
        guard let row = try await database.query(
            "SELECT password_salt,password_hash,iterations FROM operator_accounts WHERE username=?",
            [.text(username)]
        ).first,
              let saltText = row.column("password_salt")?.string,
              let hashText = row.column("password_hash")?.string,
              let salt = Data(base64Encoded: saltText),
              let hash = Data(base64Encoded: hashText),
              let iterations = row.column("iterations")?.integer,
              OperatorPasswordHasher.verify(password, salt: salt, hash: hash, iterations: iterations)
        else { return nil }

        let token = OperatorPasswordHasher.randomToken() + OperatorPasswordHasher.randomToken()
        let tokenHash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        let expires = now.addingTimeInterval(Self.operatorSessionDuration)
        let sessionID = UUID()
        return try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            let inserted = try await database.query(
                "INSERT INTO operator_sessions(session_id,username,token_hash,created_at,expires_at) SELECT ?,username,?,?,? FROM operator_accounts WHERE username=? AND password_salt=? AND password_hash=? AND iterations=? RETURNING session_id",
                [
                    .text(sessionID.uuidString.lowercased()), .text(tokenHash), .float(now.timeIntervalSince1970),
                    .float(expires.timeIntervalSince1970), .text(username), .text(saltText), .text(hashText),
                    .integer(iterations),
                ]
            )
            guard !inserted.isEmpty else { return nil }
            _ = try await database.query(
                "INSERT INTO operator_session_metadata(session_id,username,issued_at,last_seen_at,client_identity_digest,correlation_id) VALUES(?,?,?,?,?,?)",
                [
                    .text(sessionID.uuidString.lowercased()), .text(username), .float(now.timeIntervalSince1970),
                    .float(now.timeIntervalSince1970), .text(clientIdentityDigest),
                    .text(correlationID.uuidString.lowercased()),
                ]
            )
            try await clearOperatorAuthenticationThrottle(
                scope: .login,
                clientIdentityDigest: clientIdentityDigest,
                usernameDigest: usernameDigest
            )
            try await appendOperatorSecurityAudit(
                operation: "login", outcome: "success", actor: "operator:\(username)", channel: "portal",
                clientIdentityDigest: clientIdentityDigest, correlationID: correlationID, now: now
            )
            return token
        }
    }

    public func createOperatorSession(
        username: String = defaultOperatorUsername,
        clientIdentityDigest: String? = nil,
        correlationID: UUID = UUID(),
        now: Date = Date()
    ) async throws -> String {
        let token = OperatorPasswordHasher.randomToken() + OperatorPasswordHasher.randomToken()
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        let expires = now.addingTimeInterval(Self.operatorSessionDuration)
        let sessionID = UUID()
        try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            _ = try await database.query(
                "INSERT INTO operator_sessions(session_id,username,token_hash,created_at,expires_at) VALUES(?,?,?,?,?)",
                [.text(sessionID.uuidString.lowercased()), .text(username), .text(hash), .float(now.timeIntervalSince1970), .float(expires.timeIntervalSince1970)]
            )
            _ = try await database.query(
                "INSERT INTO operator_session_metadata(session_id,username,issued_at,last_seen_at,client_identity_digest,correlation_id) VALUES(?,?,?,?,?,?)",
                [
                    .text(sessionID.uuidString.lowercased()), .text(username), .float(now.timeIntervalSince1970),
                    .float(now.timeIntervalSince1970), clientIdentityDigest.map { .text($0) } ?? .null,
                    .text(correlationID.uuidString.lowercased()),
                ]
            )
        }
        return token
    }

    public func operatorSessionUsername(token: String, now: Date = Date()) async throws -> String? {
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        guard let row = try await database.query(
            "SELECT s.session_id,s.username,s.expires_at,m.revoked_at FROM operator_sessions s JOIN operator_session_metadata m ON m.session_id=s.session_id WHERE s.token_hash=?",
            [.text(hash)]
        ).first,
              row.column("revoked_at")?.double == nil,
              let username = row.column("username")?.string,
              let expires = row.column("expires_at")?.double
        else { return nil }
        guard expires > now.timeIntervalSince1970 else {
            if let sessionID = row.column("session_id")?.string {
                _ = try await database.query(
                    "UPDATE operator_session_metadata SET revoked_at=?,revocation_reason='expired' WHERE session_id=? AND revoked_at IS NULL",
                    [.float(now.timeIntervalSince1970), .text(sessionID)]
                )
            }
            _ = try await database.query("DELETE FROM operator_sessions WHERE token_hash=?", [.text(hash)])
            return nil
        }
        if let sessionID = row.column("session_id")?.string {
            _ = try await database.query(
                "UPDATE operator_session_metadata SET last_seen_at=? WHERE session_id=?",
                [.float(now.timeIntervalSince1970), .text(sessionID)]
            )
        }
        return username
    }

    @discardableResult
    public func logoutOperatorSession(
        token: String?,
        clientIdentityDigest: String?,
        correlationID: UUID,
        now: Date = Date(),
        faultInjector: (@Sendable (String) throws -> Void)? = nil
    ) async throws -> Bool {
        try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            if let prior = try await database.query(
                "SELECT detail_code FROM operator_security_audit WHERE operation='logout' AND outcome='success' AND correlation_id=? LIMIT 1",
                [.text(correlationID.uuidString.lowercased())]
            ).first {
                return prior.column("detail_code")?.string == "sessionRevoked"
            }

            var actor = "operator"
            var revokedLiveSession = false
            if let token {
                let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
                if let row = try await database.query(
                    "SELECT s.session_id,s.username,m.revoked_at,m.revocation_reason,m.correlation_id FROM operator_sessions s JOIN operator_session_metadata m ON m.session_id=s.session_id WHERE s.token_hash=?",
                    [.text(hash)]
                ).first,
                    let sessionID = row.column("session_id")?.string
                {
                    let username = row.column("username")?.string
                    if let username {
                        actor = "operator:\(username)"
                    }
                    let rotationCorrelationID = row.column("revocation_reason")?.string == "passwordChanged"
                        ? row.column("correlation_id")?.string
                        : nil
                    if let username, let rotationCorrelationID {
                        let linked = try await database.query(
                            "SELECT s.session_id,m.revoked_at FROM operator_sessions s JOIN operator_session_metadata m ON m.session_id=s.session_id WHERE s.username=? AND m.correlation_id=?",
                            [.text(username), .text(rotationCorrelationID)]
                        )
                        revokedLiveSession = linked.contains { $0.column("revoked_at")?.double == nil }
                        _ = try await database.query(
                            "UPDATE operator_session_metadata SET revoked_at=?,revocation_reason='logout' WHERE username=? AND correlation_id=?",
                            [.float(now.timeIntervalSince1970), .text(username), .text(rotationCorrelationID)]
                        )
                        try faultInjector?("after-metadata-revocation")
                        let deleted = try await database.query(
                            "DELETE FROM operator_sessions WHERE username=? AND session_id IN (SELECT session_id FROM operator_session_metadata WHERE correlation_id=?) RETURNING session_id",
                            [.text(username), .text(rotationCorrelationID)]
                        )
                        guard deleted.count == linked.count, !deleted.isEmpty else {
                            throw ServiceAPIError(code: .internalFailure, message: "Operator password rotation changed before logout completed")
                        }
                    } else {
                        _ = try await database.query(
                            "UPDATE operator_session_metadata SET revoked_at=?,revocation_reason='logout' WHERE session_id=?",
                            [.float(now.timeIntervalSince1970), .text(sessionID)]
                        )
                        revokedLiveSession = true
                        try faultInjector?("after-metadata-revocation")
                        let deleted = try await database.query(
                            "DELETE FROM operator_sessions WHERE session_id=? AND token_hash=? RETURNING session_id",
                            [.text(sessionID), .text(hash)]
                        )
                        guard !deleted.isEmpty else {
                            throw ServiceAPIError(code: .internalFailure, message: "Operator session changed before logout completed")
                        }
                    }
                    try faultInjector?("after-token-deletion")
                }
            }

            try await appendOperatorSecurityAudit(
                operation: "logout",
                outcome: "success",
                actor: actor,
                channel: "portal",
                clientIdentityDigest: clientIdentityDigest,
                correlationID: correlationID,
                detailCode: revokedLiveSession ? "sessionRevoked" : "sessionAlreadyAbsent",
                now: now
            )
            try faultInjector?("after-audit-insert")
            return revokedLiveSession
        }
    }

    public func changeOperatorPassword(
        username: String = defaultOperatorUsername,
        authorizingToken: String,
        currentPassword: String,
        newPassword: String,
        clientIdentityDigest: String?,
        correlationID: UUID,
        now: Date = Date(),
        faultInjector: (@Sendable (String) throws -> Void)? = nil,
        operationObserver: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        guard let current = try await database.query(
            "SELECT password_salt,password_hash,iterations FROM operator_accounts WHERE username=?",
            [.text(username)]
        ).first,
              let currentSaltText = current.column("password_salt")?.string,
              let currentHashText = current.column("password_hash")?.string,
              let currentSalt = Data(base64Encoded: currentSaltText),
              let currentHash = Data(base64Encoded: currentHashText),
              let currentIterations = current.column("iterations")?.integer,
              OperatorPasswordHasher.verify(
                  currentPassword,
                  salt: currentSalt,
                  hash: currentHash,
                  iterations: currentIterations
              )
        else {
            try? await appendOperatorSecurityAudit(
                operation: "passwordChange", outcome: "failure", actor: "operator:\(username)",
                channel: "portal", clientIdentityDigest: clientIdentityDigest,
                correlationID: correlationID, detailCode: "currentPasswordRejected", now: now
            )
            throw ServiceAPIError(code: .internalAuthFailed, message: "Current password is incorrect")
        }
        do {
            try OperatorPasswordHasher.validate(newPassword)
        } catch {
            try? await appendOperatorSecurityAudit(
                operation: "passwordChange", outcome: "failure", actor: "operator:\(username)",
                channel: "portal", clientIdentityDigest: clientIdentityDigest,
                correlationID: correlationID, detailCode: "newPasswordRejected", now: now
            )
            throw error
        }
        let salt = OperatorPasswordHasher.randomSalt()
        let passwordHash = try OperatorPasswordHasher.hash(password: newPassword, salt: salt)
        let authorizingHash = OperatorPasswordHasher.sha256Hex(Data(authorizingToken.utf8))
        let replacement = OperatorPasswordHasher.randomToken() + OperatorPasswordHasher.randomToken()
        let replacementHash = OperatorPasswordHasher.sha256Hex(Data(replacement.utf8))
        let replacementSessionID = UUID()
        let replacementExpiry = now.addingTimeInterval(Self.operatorSessionDuration)
        await operationObserver?("before-password-transaction")
        do {
            try await transaction(.interactive(estimatedEncodedBytes: 0)) {
                guard let authorizingSessionID = try await database.query(
                    "SELECT s.session_id FROM operator_sessions s JOIN operator_session_metadata m ON m.session_id=s.session_id WHERE s.username=? AND s.token_hash=? AND s.expires_at>? AND m.revoked_at IS NULL",
                    [.text(username), .text(authorizingHash), .float(now.timeIntervalSince1970)]
                ).first?.column("session_id")?.string else {
                    throw ServiceAPIError(code: .internalAuthFailed, message: "Operator session ended before password change completed")
                }
                let updated = try await database.query(
                    "UPDATE operator_accounts SET password_salt=?,password_hash=?,iterations=? WHERE username=? AND password_salt=? AND password_hash=? AND iterations=? RETURNING username",
                    [
                        .text(salt.base64EncodedString()), .text(passwordHash.base64EncodedString()),
                        .integer(OperatorPasswordHasher.iterations), .text(username), .text(currentSaltText),
                        .text(currentHashText), .integer(currentIterations),
                    ]
                )
                guard !updated.isEmpty else {
                    throw ServiceAPIError(code: .internalAuthFailed, message: "Current password changed before this request completed")
                }
                try faultInjector?("after-account-update")
                _ = try await database.query(
                    "UPDATE operator_session_metadata SET revoked_at=?,revocation_reason='passwordChanged' WHERE username=? AND revoked_at IS NULL",
                    [.float(now.timeIntervalSince1970), .text(username)]
                )
                _ = try await database.query(
                    "UPDATE operator_session_metadata SET correlation_id=? WHERE session_id=?",
                    [.text(correlationID.uuidString.lowercased()), .text(authorizingSessionID)]
                )
                _ = try await database.query(
                    "DELETE FROM operator_sessions WHERE username=? AND session_id<>?",
                    [.text(username), .text(authorizingSessionID)]
                )
                _ = try await database.query(
                    "UPDATE operator_sessions SET expires_at=? WHERE session_id=? AND token_hash=?",
                    [.float(now.timeIntervalSince1970), .text(authorizingSessionID), .text(authorizingHash)]
                )
                try faultInjector?("after-prior-session-revocation")
                _ = try await database.query(
                    "INSERT INTO operator_sessions(session_id,username,token_hash,created_at,expires_at) VALUES(?,?,?,?,?)",
                    [
                        .text(replacementSessionID.uuidString.lowercased()), .text(username), .text(replacementHash),
                        .float(now.timeIntervalSince1970), .float(replacementExpiry.timeIntervalSince1970),
                    ]
                )
                _ = try await database.query(
                    "INSERT INTO operator_session_metadata(session_id,username,issued_at,last_seen_at,client_identity_digest,correlation_id) VALUES(?,?,?,?,?,?)",
                    [
                        .text(replacementSessionID.uuidString.lowercased()), .text(username), .float(now.timeIntervalSince1970),
                        .float(now.timeIntervalSince1970), clientIdentityDigest.map { .text($0) } ?? .null,
                        .text(correlationID.uuidString.lowercased()),
                    ]
                )
                try faultInjector?("after-replacement-session-insert")
                try await appendOperatorSecurityAudit(
                    operation: "passwordChange", outcome: "success", actor: "operator:\(username)", channel: "portal",
                    clientIdentityDigest: clientIdentityDigest, correlationID: correlationID, now: now
                )
                try faultInjector?("after-password-audit-insert")
            }
        } catch {
            try? await appendOperatorSecurityAudit(
                operation: "passwordChange", outcome: "failure", actor: "operator:\(username)",
                channel: "portal", clientIdentityDigest: clientIdentityDigest,
                correlationID: correlationID, detailCode: "passwordChangeTransactionFailed", now: now
            )
            throw error
        }
        await operationObserver?("after-password-commit")
        return replacement
    }

    public func resetOperatorPasswordOffline(
        username: String = defaultOperatorUsername,
        newPassword: String,
        correlationID: UUID = UUID(),
        now: Date = Date()
    ) async throws {
        let clientIdentityDigest = OperatorPasswordHasher.sha256Hex(Data("offline-maintenance".utf8))
        let usernameDigest = OperatorPasswordHasher.sha256Hex(Data(username.lowercased().utf8))
        let reservation = try await reserveOperatorAuthenticationAttempt(
            scope: .offlineReset,
            clientIdentityDigest: clientIdentityDigest,
            usernameDigest: usernameDigest,
            now: now
        )
        guard reservation.allowed else {
            try? await appendOperatorSecurityAudit(
                operation: "passwordReset", outcome: "rateLimited", actor: "operator-recovery",
                channel: "offline", clientIdentityDigest: clientIdentityDigest,
                correlationID: correlationID, detailCode: "durableThrottle", now: now
            )
            throw ServiceAPIError(
                code: .rateLimited,
                message: "Offline password reset is temporarily throttled",
                retryable: true
            )
        }
        do {
            try OperatorPasswordHasher.validate(newPassword)
            let salt = OperatorPasswordHasher.randomSalt()
            let passwordHash = try OperatorPasswordHasher.hash(password: newPassword, salt: salt)
            try await transaction(.interactive(estimatedEncodedBytes: 0)) {
                let updated = try await database.query(
                    "UPDATE operator_accounts SET password_salt=?,password_hash=?,iterations=? WHERE username=? RETURNING username",
                    [
                        .text(salt.base64EncodedString()), .text(passwordHash.base64EncodedString()),
                        .integer(OperatorPasswordHasher.iterations), .text(username),
                    ]
                )
                guard !updated.isEmpty else {
                    throw ServiceAPIError(code: .notFound, message: "Operator account does not exist")
                }
                _ = try await database.query(
                    "UPDATE operator_session_metadata SET revoked_at=?,revocation_reason='offlinePasswordReset' WHERE username=? AND revoked_at IS NULL",
                    [.float(now.timeIntervalSince1970), .text(username)]
                )
                _ = try await database.query("DELETE FROM operator_sessions WHERE username=?", [.text(username)])
                try await completeReservedOperatorAuthenticationSuccess(
                    scope: .offlineReset,
                    clientIdentityDigest: clientIdentityDigest,
                    usernameDigest: usernameDigest,
                    now: now
                )
                try await appendOperatorSecurityAudit(
                    operation: "passwordReset", outcome: "success", actor: "operator-recovery", channel: "offline",
                    clientIdentityDigest: clientIdentityDigest, correlationID: correlationID,
                    detailCode: "sessionsRevoked", now: now
                )
            }
        } catch {
            let failure = try? await recordReservedOperatorAuthenticationFailure(
                scope: .offlineReset,
                clientIdentityDigest: clientIdentityDigest,
                usernameDigest: usernameDigest,
                auditOperation: "passwordReset",
                auditActor: "operator-recovery",
                auditChannel: "offline",
                correlationID: correlationID,
                detailCode: "offlineResetRejected",
                now: now
            )
            if failure?.allowed == false {
                throw ServiceAPIError(
                    code: .rateLimited,
                    message: "Offline password reset is temporarily throttled",
                    retryable: true
                )
            }
            throw error
        }
    }

    private func consumeSetupToken(
        _ token: String,
        clientIdentityDigest: String?,
        correlationID: UUID,
        channel: String,
        now: Date
    ) async throws {
        guard let pending = try await database.query(
            "SELECT token_hash FROM operator_setup_tokens WHERE consumed_at IS NULL"
        ).first,
            let expectedHash = pending.column("token_hash")?.string
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "First-run setup is not available")
        }
        let provided = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        guard OperatorPasswordHasher.constantTimeEquals(Data(provided.utf8), Data(expectedHash.utf8)) else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "First-run setup token is invalid")
        }
        _ = try await database.query(
            "UPDATE operator_setup_tokens SET consumed_at=? WHERE token_hash=? AND consumed_at IS NULL",
            [.float(now.timeIntervalSince1970), .text(expectedHash)]
        )
        try await appendOperatorSecurityAudit(
            operation: "setupTokenConsume", outcome: "success", actor: "operator:onboarding",
            channel: channel, clientIdentityDigest: clientIdentityDigest,
            correlationID: correlationID, detailCode: "tokenConsumed", now: now
        )
    }
}
