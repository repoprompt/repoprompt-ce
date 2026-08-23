import Crypto
import Foundation
import RepoPromptRuntimeModel

public struct OperatorSecurityAuditRecord: Codable, Sendable {
    public let auditID: UUID
    public let operation: String
    public let outcome: String
    public let actor: String
    public let channel: String
    public let clientIdentityDigest: String?
    public let correlationID: UUID
    public let detailCode: String?
    public let createdAt: Date
}

public struct OperatorSessionRecord: Codable, Sendable {
    public let sessionID: UUID
    public let username: String
    public let issuedAt: Date
    public let lastSeenAt: Date
    public let expiresAt: Date?
    public let revokedAt: Date?
    public let revocationReason: String?
    public let current: Bool
}

public struct MaintenanceReceiptEvidence: Sendable, Equatable {
    public let archiveSHA256: String
    public let manifestSHA256: String
    public let source: MigrationSourceEvidence
    public let verifierFingerprint: String?
    public let recipientFingerprints: [String]
    public let sidecarSHA256: String
    public let toolVersion: String
    public let toolDigest: String

    public init(
        archiveSHA256: String,
        manifestSHA256: String,
        source: MigrationSourceEvidence,
        verifierFingerprint: String?,
        recipientFingerprints: [String],
        sidecarSHA256: String,
        toolVersion: String,
        toolDigest: String
    ) {
        self.archiveSHA256 = archiveSHA256
        self.manifestSHA256 = manifestSHA256
        self.source = source
        self.verifierFingerprint = verifierFingerprint
        self.recipientFingerprints = recipientFingerprints
        self.sidecarSHA256 = sidecarSHA256
        self.toolVersion = toolVersion
        self.toolDigest = toolDigest
    }
}

public struct MaintenanceReceiptRecord: Codable, Sendable {
    public let receiptID: UUID
    public let operation: String
    public let outcome: String
    public let archiveSHA256: String
    public let manifestSHA256: String
    public let sourceStoreID: UUID
    public let sourceSchemaVersion: Int
    public let sourceGlobalSequence: Int64
    public let verifierFingerprint: String?
    public let recipientFingerprints: [String]
    public let sidecarSHA256: String
    public let toolVersion: String
    public let toolDigest: String
    public let correlationID: UUID
    public let createdAt: Date
}

public enum OperatorAuthenticationScope: String, Sendable {
    case setup
    case login
    case offlineReset
}

public struct OperatorAuthenticationAdmission: Sendable {
    public let allowed: Bool
    public let retryAfterSeconds: Int?
}

extension SQLiteServiceStore {
    public func operatorAuthenticationAdmission(
        scope: OperatorAuthenticationScope,
        clientIdentityDigest: String,
        usernameDigest: String,
        now: Date = Date()
    ) async throws -> OperatorAuthenticationAdmission {
        let key = operatorThrottleKey(scope: scope, clientIdentityDigest: clientIdentityDigest, usernameDigest: usernameDigest)
        guard let row = try await database.query(
            "SELECT window_started_at,attempt_count,blocked_until FROM operator_auth_throttle_buckets WHERE bucket_key=?",
            [.text(key)]
        ).first else { return .init(allowed: true, retryAfterSeconds: nil) }
        let timestamp = now.timeIntervalSince1970
        if let blockedUntil = row.column("blocked_until")?.double, blockedUntil > timestamp {
            return .init(allowed: false, retryAfterSeconds: max(1, Int(ceil(blockedUntil - timestamp))))
        }
        let windowStarted = row.column("window_started_at")?.double ?? timestamp
        let attempts = row.column("attempt_count")?.integer ?? 0
        if timestamp - windowStarted < 60, attempts >= 5 {
            return .init(allowed: false, retryAfterSeconds: max(1, Int(ceil(60 - (timestamp - windowStarted)))))
        }
        return .init(allowed: true, retryAfterSeconds: nil)
    }

    public func reserveOperatorAuthenticationAttempt(
        scope: OperatorAuthenticationScope,
        clientIdentityDigest: String,
        usernameDigest: String,
        now: Date = Date()
    ) async throws -> OperatorAuthenticationAdmission {
        let key = operatorThrottleKey(
            scope: scope,
            clientIdentityDigest: clientIdentityDigest,
            usernameDigest: usernameDigest
        )
        return try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            let timestamp = now.timeIntervalSince1970
            let row = try await database.query(
                "SELECT window_started_at,attempt_count,consecutive_failures,blocked_until FROM operator_auth_throttle_buckets WHERE bucket_key=?",
                [.text(key)]
            ).first
            let priorWindow = row?.column("window_started_at")?.double ?? timestamp
            let withinWindow = timestamp - priorWindow < 60
            let windowStarted = withinWindow ? priorWindow : timestamp
            let attempts = withinWindow ? (row?.column("attempt_count")?.integer ?? 0) : 0
            let failures = row?.column("consecutive_failures")?.integer ?? 0
            let priorBlock = row?.column("blocked_until")?.double
            if let priorBlock, priorBlock > timestamp {
                return .init(
                    allowed: false,
                    retryAfterSeconds: max(1, Int(ceil(priorBlock - timestamp)))
                )
            }
            if attempts >= 5 {
                let blockedUntil = max(priorBlock ?? 0, windowStarted + 60)
                _ = try await database.query(
                    "UPDATE operator_auth_throttle_buckets SET blocked_until=?,updated_at=? WHERE bucket_key=?",
                    [.float(blockedUntil), .float(timestamp), .text(key)]
                )
                return .init(
                    allowed: false,
                    retryAfterSeconds: max(1, Int(ceil(blockedUntil - timestamp)))
                )
            }
            _ = try await database.query(
                "INSERT INTO operator_auth_throttle_buckets(bucket_key,scope,client_identity_digest,username_digest,window_started_at,attempt_count,consecutive_failures,blocked_until,updated_at) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(bucket_key) DO UPDATE SET window_started_at=excluded.window_started_at,attempt_count=excluded.attempt_count,consecutive_failures=excluded.consecutive_failures,blocked_until=excluded.blocked_until,updated_at=excluded.updated_at",
                [
                    .text(key), .text(scope.rawValue), .text(clientIdentityDigest), .text(usernameDigest),
                    .float(windowStarted), .integer(attempts + 1), .integer(failures), .null,
                    .float(timestamp),
                ]
            )
            return .init(allowed: true, retryAfterSeconds: nil)
        }
    }

    public func recordReservedOperatorAuthenticationFailure(
        scope: OperatorAuthenticationScope,
        clientIdentityDigest: String,
        usernameDigest: String,
        auditOperation: String,
        auditActor: String,
        auditChannel: String,
        correlationID: UUID,
        detailCode: String,
        now: Date = Date()
    ) async throws -> OperatorAuthenticationAdmission {
        let key = operatorThrottleKey(
            scope: scope,
            clientIdentityDigest: clientIdentityDigest,
            usernameDigest: usernameDigest
        )
        return try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            let timestamp = now.timeIntervalSince1970
            let row = try await database.query(
                "SELECT window_started_at,attempt_count,consecutive_failures,blocked_until FROM operator_auth_throttle_buckets WHERE bucket_key=?",
                [.text(key)]
            ).first
            let windowStarted = row?.column("window_started_at")?.double ?? timestamp
            let attempts = max(1, row?.column("attempt_count")?.integer ?? 0)
            let failures = (row?.column("consecutive_failures")?.integer ?? 0) + 1
            let priorBlock = row?.column("blocked_until")?.double
            let blockedUntil: Double? = if failures >= 10 {
                max(priorBlock ?? 0, timestamp + 15 * 60)
            } else if attempts >= 5 {
                max(priorBlock ?? 0, windowStarted + 60)
            } else {
                priorBlock.flatMap { $0 > timestamp ? $0 : nil }
            }
            _ = try await database.query(
                "INSERT INTO operator_auth_throttle_buckets(bucket_key,scope,client_identity_digest,username_digest,window_started_at,attempt_count,consecutive_failures,blocked_until,updated_at) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(bucket_key) DO UPDATE SET attempt_count=excluded.attempt_count,consecutive_failures=excluded.consecutive_failures,blocked_until=excluded.blocked_until,updated_at=excluded.updated_at",
                [
                    .text(key), .text(scope.rawValue), .text(clientIdentityDigest), .text(usernameDigest),
                    .float(windowStarted), .integer(attempts), .integer(failures),
                    blockedUntil.map { .float($0) } ?? .null, .float(timestamp),
                ]
            )
            try await appendOperatorSecurityAudit(
                operation: auditOperation,
                outcome: blockedUntil.map { $0 > timestamp } == true ? "rateLimited" : "failure",
                actor: auditActor,
                channel: auditChannel,
                clientIdentityDigest: clientIdentityDigest,
                correlationID: correlationID,
                detailCode: detailCode,
                now: now
            )
            return .init(
                allowed: blockedUntil.map { $0 <= timestamp } ?? true,
                retryAfterSeconds: blockedUntil.map { max(1, Int(ceil($0 - timestamp))) }
            )
        }
    }

    func completeReservedOperatorAuthenticationSuccess(
        scope: OperatorAuthenticationScope,
        clientIdentityDigest: String,
        usernameDigest: String,
        now: Date
    ) async throws {
        if scope == .offlineReset {
            let key = operatorThrottleKey(
                scope: scope,
                clientIdentityDigest: clientIdentityDigest,
                usernameDigest: usernameDigest
            )
            _ = try await database.query(
                "UPDATE operator_auth_throttle_buckets SET consecutive_failures=0,blocked_until=NULL,updated_at=? WHERE bucket_key=?",
                [.float(now.timeIntervalSince1970), .text(key)]
            )
        } else {
            try await clearOperatorAuthenticationThrottle(
                scope: scope,
                clientIdentityDigest: clientIdentityDigest,
                usernameDigest: usernameDigest
            )
        }
    }

    public func clearOperatorAuthenticationThrottle(
        scope: OperatorAuthenticationScope,
        clientIdentityDigest: String,
        usernameDigest: String
    ) async throws {
        let key = operatorThrottleKey(
            scope: scope,
            clientIdentityDigest: clientIdentityDigest,
            usernameDigest: usernameDigest
        )
        _ = try await database.query(
            "DELETE FROM operator_auth_throttle_buckets WHERE bucket_key=?",
            [.text(key)]
        )
    }

    public func recordOperatorAuthenticationResult(
        scope: OperatorAuthenticationScope,
        clientIdentityDigest: String,
        usernameDigest: String,
        succeeded: Bool,
        now: Date = Date()
    ) async throws -> OperatorAuthenticationAdmission {
        if succeeded {
            try await completeReservedOperatorAuthenticationSuccess(
                scope: scope,
                clientIdentityDigest: clientIdentityDigest,
                usernameDigest: usernameDigest,
                now: now
            )
            return .init(allowed: true, retryAfterSeconds: nil)
        }
        let reservation = try await reserveOperatorAuthenticationAttempt(
            scope: scope,
            clientIdentityDigest: clientIdentityDigest,
            usernameDigest: usernameDigest,
            now: now
        )
        guard reservation.allowed else { return reservation }
        return try await recordReservedOperatorAuthenticationFailure(
            scope: scope,
            clientIdentityDigest: clientIdentityDigest,
            usernameDigest: usernameDigest,
            auditOperation: scope.rawValue,
            auditActor: "anonymous",
            auditChannel: scope == .offlineReset ? "offline" : "portal",
            correlationID: UUID(),
            detailCode: "authenticationRejected",
            now: now
        )
    }

    public func appendOperatorSecurityAudit(
        operation: String,
        outcome: String,
        actor: String,
        channel: String,
        clientIdentityDigest: String?,
        correlationID: UUID,
        detailCode: String? = nil,
        now: Date = Date()
    ) async throws {
        _ = try await database.query(
            "INSERT INTO operator_security_audit(audit_id,operation,outcome,actor,channel,client_identity_digest,correlation_id,detail_code,created_at) VALUES(?,?,?,?,?,?,?,?,?)",
            [
                .text(UUID().uuidString.lowercased()), .text(operation), .text(outcome), .text(actor), .text(channel),
                clientIdentityDigest.map { .text($0) } ?? .null, .text(correlationID.uuidString.lowercased()),
                detailCode.map { .text($0) } ?? .null, .float(now.timeIntervalSince1970),
            ]
        )
    }

    public func operatorSecurityAudit(limit: Int = 100) async throws -> [OperatorSecurityAuditRecord] {
        let bounded = min(max(limit, 1), 500)
        return try await database.query(
            "SELECT audit_id,operation,outcome,actor,channel,client_identity_digest,correlation_id,detail_code,created_at FROM operator_security_audit ORDER BY created_at DESC,audit_id DESC LIMIT ?",
            [.integer(bounded)]
        ).map { row in
            OperatorSecurityAuditRecord(
                auditID: try requireUUID(row.column("audit_id")?.string),
                operation: row.column("operation")?.string ?? "unknown",
                outcome: row.column("outcome")?.string ?? "unknown",
                actor: row.column("actor")?.string ?? "unknown",
                channel: row.column("channel")?.string ?? "unknown",
                clientIdentityDigest: row.column("client_identity_digest")?.string,
                correlationID: try requireUUID(row.column("correlation_id")?.string),
                detailCode: row.column("detail_code")?.string,
                createdAt: Date(timeIntervalSince1970: row.column("created_at")?.double ?? 0)
            )
        }
    }

    public func operatorSessions(currentToken: String?, now: Date = Date()) async throws -> [OperatorSessionRecord] {
        let currentHash = currentToken.map { OperatorPasswordHasher.sha256Hex(Data($0.utf8)) }
        return try await database.query(
            "SELECT m.session_id,m.username,m.issued_at,m.last_seen_at,m.revoked_at,m.revocation_reason,s.expires_at,s.token_hash FROM operator_session_metadata m LEFT JOIN operator_sessions s ON s.session_id=m.session_id ORDER BY m.issued_at DESC"
        ).map { row in
            OperatorSessionRecord(
                sessionID: try requireUUID(row.column("session_id")?.string),
                username: row.column("username")?.string ?? Self.defaultOperatorUsername,
                issuedAt: Date(timeIntervalSince1970: row.column("issued_at")?.double ?? 0),
                lastSeenAt: Date(timeIntervalSince1970: row.column("last_seen_at")?.double ?? 0),
                expiresAt: row.column("expires_at")?.double.map(Date.init(timeIntervalSince1970:)),
                revokedAt: row.column("revoked_at")?.double.map(Date.init(timeIntervalSince1970:)),
                revocationReason: row.column("revocation_reason")?.string,
                current: currentHash != nil && row.column("token_hash")?.string == currentHash
            )
        }.filter { $0.revokedAt != nil || ($0.expiresAt?.timeIntervalSince(now) ?? -1) > 0 }
    }

    public func revokeAllOperatorSessions(
        username: String = defaultOperatorUsername,
        reason: String,
        exceptToken: String? = nil,
        auditActor: String? = nil,
        auditChannel: String? = nil,
        clientIdentityDigest: String? = nil,
        correlationID: UUID? = nil,
        now: Date = Date()
    ) async throws -> Int {
        let exceptHash = exceptToken.map { OperatorPasswordHasher.sha256Hex(Data($0.utf8)) }
        do {
            return try await transaction(.interactive(estimatedEncodedBytes: 0)) {
                let rows = try await database.query(
                    "SELECT s.session_id,s.token_hash,m.revoked_at FROM operator_sessions s JOIN operator_session_metadata m ON m.session_id=s.session_id WHERE s.username=?",
                    [.text(username)]
                )
                let revoked = rows.filter {
                    $0.column("revoked_at")?.double == nil
                        && (exceptHash == nil || $0.column("token_hash")?.string != exceptHash)
                }
                for row in revoked {
                    guard let sessionID = row.column("session_id")?.string else { continue }
                    _ = try await database.query(
                        "UPDATE operator_session_metadata SET revoked_at=?,revocation_reason=? WHERE session_id=?",
                        [.float(now.timeIntervalSince1970), .text(reason), .text(sessionID)]
                    )
                    _ = try await database.query("DELETE FROM operator_sessions WHERE session_id=?", [.text(sessionID)])
                }
                if let auditActor, let auditChannel, let correlationID {
                    try await appendOperatorSecurityAudit(
                        operation: "sessionRevokeAll", outcome: "success", actor: auditActor,
                        channel: auditChannel, clientIdentityDigest: clientIdentityDigest,
                        correlationID: correlationID, detailCode: "revoked=\(revoked.count)", now: now
                    )
                }
                return revoked.count
            }
        } catch {
            if let auditActor, let auditChannel, let correlationID {
                try? await appendOperatorSecurityAudit(
                    operation: "sessionRevokeAll", outcome: "failure", actor: auditActor,
                    channel: auditChannel, clientIdentityDigest: clientIdentityDigest,
                    correlationID: correlationID, detailCode: "sessionRevokeRejected", now: now
                )
            }
            throw error
        }
    }

    public func maintenanceReceipts(limit: Int = 100) async throws -> [MaintenanceReceiptRecord] {
        let bounded = min(max(limit, 1), 500)
        return try await database.query("SELECT * FROM maintenance_receipts ORDER BY created_at DESC,receipt_id DESC LIMIT ?", [.integer(bounded)]).map { row in
            let fingerprints = try decoder.decode([String].self, from: Data((row.column("recipient_fingerprints_json")?.string ?? "[]").utf8))
            return MaintenanceReceiptRecord(
                receiptID: try requireUUID(row.column("receipt_id")?.string),
                operation: row.column("operation")?.string ?? "unknown",
                outcome: row.column("outcome")?.string ?? "unknown",
                archiveSHA256: row.column("archive_sha256")?.string ?? "",
                manifestSHA256: row.column("manifest_sha256")?.string ?? "",
                sourceStoreID: try requireUUID(row.column("source_store_id")?.string),
                sourceSchemaVersion: row.column("source_schema_version")?.integer ?? 0,
                sourceGlobalSequence: Int64(row.column("source_global_sequence")?.integer ?? 0),
                verifierFingerprint: row.column("verifier_fingerprint")?.string,
                recipientFingerprints: fingerprints,
                sidecarSHA256: row.column("sidecar_sha256")?.string ?? "",
                toolVersion: row.column("tool_version")?.string ?? "unknown",
                toolDigest: row.column("tool_digest")?.string ?? "unknown",
                correlationID: try requireUUID(row.column("correlation_id")?.string),
                createdAt: Date(timeIntervalSince1970: row.column("created_at")?.double ?? 0)
            )
        }
    }

    public func recordMaintenanceReceipt(
        operation: String,
        outcome: String,
        archiveSHA256: String,
        manifestSHA256: String,
        source: MigrationSourceEvidence,
        verifierFingerprint: String?,
        recipientFingerprints: [String],
        sidecarSHA256: String,
        toolVersion: String,
        toolDigest: String,
        correlationID: UUID = UUID(),
        now: Date = Date()
    ) async throws {
        let evidence = MaintenanceReceiptEvidence(
            archiveSHA256: archiveSHA256,
            manifestSHA256: manifestSHA256,
            source: source,
            verifierFingerprint: verifierFingerprint,
            recipientFingerprints: recipientFingerprints,
            sidecarSHA256: sidecarSHA256,
            toolVersion: toolVersion,
            toolDigest: toolDigest
        )
        let retainedBytes = try encodeText(recipientFingerprints.sorted()).utf8.count
        try await transaction(.interactive(estimatedEncodedBytes: retainedBytes)) {
            try await insertMaintenanceReceipt(
                operation: operation,
                outcome: outcome,
                evidence: evidence,
                correlationID: correlationID,
                now: now
            )
        }
    }

    func insertMaintenanceReceipt(
        operation: String,
        outcome: String,
        evidence: MaintenanceReceiptEvidence,
        correlationID: UUID,
        now: Date
    ) async throws {
        let fingerprints = try encodeText(evidence.recipientFingerprints.sorted())
        _ = try await database.query(
            "INSERT INTO maintenance_receipts(receipt_id,operation,outcome,archive_sha256,manifest_sha256,source_store_id,source_schema_version,source_global_sequence,verifier_fingerprint,recipient_fingerprints_json,sidecar_sha256,tool_version,tool_digest,correlation_id,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [
                .text(UUID().uuidString.lowercased()), .text(operation), .text(outcome),
                .text(evidence.archiveSHA256), .text(evidence.manifestSHA256),
                .text(evidence.source.storeID.uuidString.lowercased()),
                .integer(evidence.source.schemaVersion), .integer(Int(evidence.source.nextGlobalSequence)),
                evidence.verifierFingerprint.map { .text($0) } ?? .null, .text(fingerprints),
                .text(evidence.sidecarSHA256), .text(evidence.toolVersion), .text(evidence.toolDigest),
                .text(correlationID.uuidString.lowercased()), .float(now.timeIntervalSince1970),
            ]
        )
        try await appendOperatorSecurityAudit(
            operation: operation,
            outcome: outcome,
            actor: "operator-maintenance",
            channel: "offline",
            clientIdentityDigest: nil,
            correlationID: correlationID,
            detailCode: "maintenanceReceipt",
            now: now
        )
    }

    func operatorThrottleKey(scope: OperatorAuthenticationScope, clientIdentityDigest: String, usernameDigest: String) -> String {
        SHA256.hash(data: Data("\(scope.rawValue)\u{0}\(clientIdentityDigest)\u{0}\(usernameDigest)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
