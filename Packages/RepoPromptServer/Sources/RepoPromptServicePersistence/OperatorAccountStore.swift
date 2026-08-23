import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

extension SQLiteServiceStore {
    public static let defaultOperatorUsername = "operator"
    public static let operatorSessionDuration: TimeInterval = 12 * 60 * 60

    public func hasOperatorAccount() async throws -> Bool {
        let count = try await connection.query("SELECT COUNT(*) AS count FROM operator_accounts").first?.column("count")?.integer ?? 0
        return count > 0
    }

    public func issueOperatorSetupToken() async throws -> String {
        _ = try await connection.query("DELETE FROM operator_setup_tokens")
        let token = OperatorPasswordHasher.randomToken()
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        _ = try await connection.query(
            "INSERT INTO operator_setup_tokens(token_hash,created_at) VALUES(?,CURRENT_TIMESTAMP)",
            [.text(hash)]
        )
        return token
    }

    public func createOperatorAccount(username: String = defaultOperatorUsername, password: String, setupToken: String?, allowMissingSetupToken: Bool = false) async throws {
        guard try await hasOperatorAccount() == false else {
            throw ServiceAPIError(code: .invalidRequest, message: "Operator account already exists")
        }
        try OperatorPasswordHasher.validate(password)
        try await consumeSetupToken(setupToken, allowMissing: allowMissingSetupToken)
        let salt = OperatorPasswordHasher.randomSalt()
        let hash = try OperatorPasswordHasher.hash(password: password, salt: salt)
        _ = try await connection.query(
            "INSERT INTO operator_accounts(username,password_salt,password_hash,iterations,created_at) VALUES(?,?,?,?,CURRENT_TIMESTAMP)",
            [
                .text(username),
                .text(salt.base64EncodedString()),
                .text(hash.base64EncodedString()),
                .integer(OperatorPasswordHasher.iterations)
            ]
        )
    }

    public func verifyOperatorPassword(username: String = defaultOperatorUsername, password: String) async throws -> Bool {
        guard let row = try await connection.query(
            "SELECT password_salt,password_hash,iterations FROM operator_accounts WHERE username=?",
            [.text(username)]
        ).first,
              let salt = Data(base64Encoded: row.column("password_salt")?.string ?? ""),
              let hash = Data(base64Encoded: row.column("password_hash")?.string ?? ""),
              let iterations = row.column("iterations")?.integer
        else { return false }
        return OperatorPasswordHasher.verify(password, salt: salt, hash: hash, iterations: iterations)
    }

    public func createOperatorSession(username: String = defaultOperatorUsername, now: Date = Date()) async throws -> String {
        let token = OperatorPasswordHasher.randomToken() + OperatorPasswordHasher.randomToken()
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        let expires = now.addingTimeInterval(Self.operatorSessionDuration)
        _ = try await connection.query(
            "INSERT INTO operator_sessions(session_id,username,token_hash,created_at,expires_at) VALUES(?,?,?,CURRENT_TIMESTAMP,?)",
            [.text(UUID().uuidString), .text(username), .text(hash), .float(expires.timeIntervalSince1970)]
        )
        return token
    }

    public func operatorSessionUsername(token: String, now: Date = Date()) async throws -> String? {
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        guard let row = try await connection.query(
            "SELECT username,expires_at FROM operator_sessions WHERE token_hash=?",
            [.text(hash)]
        ).first,
              let username = row.column("username")?.string,
              let expires = row.column("expires_at")?.double
        else { return nil }
        guard expires > now.timeIntervalSince1970 else {
            _ = try await connection.query("DELETE FROM operator_sessions WHERE token_hash=?", [.text(hash)])
            return nil
        }
        return username
    }

    public func deleteOperatorSession(token: String) async throws {
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        _ = try await connection.query("DELETE FROM operator_sessions WHERE token_hash=?", [.text(hash)])
    }

    private func consumeSetupToken(_ token: String?, allowMissing: Bool) async throws {
        guard let pending = try await connection.query("SELECT token_hash FROM operator_setup_tokens WHERE consumed_at IS NULL").first,
              let expectedHash = pending.column("token_hash")?.string
        else {
            if allowMissing { return }
            throw ServiceAPIError(code: .invalidRequest, message: "First-run setup is not available")
        }
        if allowMissing {
            _ = try await connection.query(
                "UPDATE operator_setup_tokens SET consumed_at=CURRENT_TIMESTAMP WHERE token_hash=?",
                [.text(expectedHash)]
            )
            return
        }
        let provided = OperatorPasswordHasher.sha256Hex(Data((token ?? "").utf8))
        guard OperatorPasswordHasher.constantTimeEquals(Data(provided.utf8), Data(expectedHash.utf8)) else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "First-run setup token is invalid")
        }
        _ = try await connection.query(
            "UPDATE operator_setup_tokens SET consumed_at=CURRENT_TIMESTAMP WHERE token_hash=?",
            [.text(expectedHash)]
        )
    }
}
