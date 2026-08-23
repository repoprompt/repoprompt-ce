import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import SQLiteNIO

public extension SQLiteServiceStore {
    func authorityStore_upsertComposerAttachment(_ record: StoredComposerAttachment) async throws {
        let wire = record.wire
        _ = try await database.query("INSERT INTO composer_attachments(attachment_id,actor_id,project_id,session_id,turn_id,schema_version,lifecycle,display_name,media_type,byte_size,digest,pixel_width,pixel_height,staged_path,persistent_path,expires_at,lease_submission_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(attachment_id) DO UPDATE SET session_id=excluded.session_id,turn_id=excluded.turn_id,lifecycle=excluded.lifecycle,staged_path=excluded.staged_path,persistent_path=excluded.persistent_path,expires_at=excluded.expires_at,lease_submission_id=excluded.lease_submission_id,updated_at=excluded.updated_at", [.text(wire.attachmentID.uuidString), .text(record.actorID), .text(record.projectID.uuidString), record.sessionID.map { .text($0.uuidString) } ?? .null, record.turnID.map { .text($0.uuidString) } ?? .null, .integer(wire.schemaVersion), .text(wire.lifecycle.rawValue), .text(wire.displayName), .text(wire.mediaType), .integer(wire.byteSize), .text(wire.digest), .integer(wire.pixelWidth), .integer(wire.pixelHeight), record.stagedPath.map(SQLiteData.text) ?? .null, record.persistentPath.map(SQLiteData.text) ?? .null, wire.expiresAt.map { .float($0.timeIntervalSince1970) } ?? .null, record.leaseSubmissionID.map { .text($0.uuidString) } ?? .null, .float(record.createdAt.timeIntervalSince1970), .float(record.updatedAt.timeIntervalSince1970)])
    }

    func authorityStore_composerAttachment(attachmentID: UUID) async throws -> StoredComposerAttachment? {
        guard let row = try await database.query("SELECT * FROM composer_attachments WHERE attachment_id=?", [.text(attachmentID.uuidString)]).first else { return nil }
        return try decodeComposerAttachment(row)
    }

    func authorityStore_composerAttachments(actorID: String? = nil, projectID: UUID? = nil, lifecycle: ComposerAttachmentLifecycle? = nil) async throws -> [StoredComposerAttachment] {
        var clauses: [String] = []
        var bindings: [SQLiteData] = []
        if let actorID { clauses.append("actor_id=?"); bindings.append(.text(actorID)) }
        if let projectID { clauses.append("project_id=?"); bindings.append(.text(projectID.uuidString)) }
        if let lifecycle { clauses.append("lifecycle=?"); bindings.append(.text(lifecycle.rawValue)) }
        let suffix = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return try await database.query("SELECT * FROM composer_attachments\(suffix) ORDER BY created_at", bindings).map(decodeComposerAttachment)
    }

    func authorityStore_deleteComposerAttachment(attachmentID: UUID) async throws {
        _ = try await database.query("DELETE FROM composer_attachments WHERE attachment_id=?", [.text(attachmentID.uuidString)])
    }

    func persistAcceptedAttachmentManifest(turnID: UUID, sessionID: UUID, manifest: AgentTurnContentWire, totalBytes: Int, at date: Date) async throws {
        let json = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        _ = try await database.query("INSERT INTO accepted_attachment_manifests(turn_id,session_id,schema_version,manifest_json,total_bytes,created_at) VALUES(?,?,1,?,?,?) ON CONFLICT(turn_id) DO NOTHING", [.text(turnID.uuidString), .text(sessionID.uuidString), .text(json), .integer(totalBytes), .float(date.timeIntervalSince1970)])
    }

    private func decodeComposerAttachment(_ row: SQLiteRow) throws -> StoredComposerAttachment {
        guard let attachmentID = row.column("attachment_id")?.string.flatMap(UUID.init(uuidString:)), let projectID = row.column("project_id")?.string.flatMap(UUID.init(uuidString:)), let lifecycle = ComposerAttachmentLifecycle(rawValue: row.column("lifecycle")?.string ?? "") else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Composer attachment record is invalid") }
        let wire = ComposerAttachmentWire(schemaVersion: row.column("schema_version")?.integer ?? 1, attachmentID: attachmentID, displayName: row.column("display_name")?.string ?? "image", mediaType: row.column("media_type")?.string ?? "application/octet-stream", byteSize: row.column("byte_size")?.integer ?? 0, digest: row.column("digest")?.string ?? "", pixelWidth: row.column("pixel_width")?.integer ?? 0, pixelHeight: row.column("pixel_height")?.integer ?? 0, lifecycle: lifecycle, expiresAt: row.column("expires_at")?.double.map(Date.init(timeIntervalSince1970:)))
        return StoredComposerAttachment(wire: wire, actorID: row.column("actor_id")?.string ?? "", projectID: projectID, sessionID: row.column("session_id")?.string.flatMap(UUID.init(uuidString:)), turnID: row.column("turn_id")?.string.flatMap(UUID.init(uuidString:)), stagedPath: row.column("staged_path")?.string, persistentPath: row.column("persistent_path")?.string, leaseSubmissionID: row.column("lease_submission_id")?.string.flatMap(UUID.init(uuidString:)), createdAt: Date(timeIntervalSince1970: row.column("created_at")?.double ?? 0), updatedAt: Date(timeIntervalSince1970: row.column("updated_at")?.double ?? 0))
    }
}
