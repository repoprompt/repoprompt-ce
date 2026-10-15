import Foundation
import RepoPromptDomainRuntime
import RepoPromptPersistence

/// Overseer-only integration point for the independent app-wide profile-isolation work. This does
/// not move any unrelated app data. Debug never writes the previously mixed/release legacy root.
struct OverseerContinuityLocations {
    let databaseURL: URL
    let profile: String
    let legacyDirectory: URL

    /// Links and ownership are imported only from this same profile's directory.
    var legacyFactsPolicy: OverseerLegacyPolicy {
        .sameProfile
    }
}

enum OverseerLegacyPolicy {
    /// Only used for a caller-proven same-profile source (temporary test stores included).
    case sameProfile
    /// Mixed debug/release sources are retained, never silently promoted into live authority.
    case userReview
}

/// One typed adapter per legacy unit, all sharing one transactional database. Legacy sources are
/// read-only; malformed/future rows and whole documents are archived, never moved or overwritten.
final class OverseerContinuityRepository: @unchecked Sendable {
    /// The only production path seam. When #1381 lands, compose `base` from
    /// AppProfileLocations.current.applicationSupportRoot (or its filesystem identity),
    /// for both the database and legacy input. No adapter owns a second path policy.
    static func production(fileManager: FileManager = .default) -> OverseerContinuityLocations {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if DEBUG
            let base = support.appendingPathComponent("RepoPrompt CE Debug", isDirectory: true)
            let profile = "repoprompt-ce-debug-overseer-v1"
        #else
            let base = support.appendingPathComponent("RepoPrompt CE", isDirectory: true)
            let profile = "repoprompt-ce-release-overseer-v1"
        #endif
        return .init(
            databaseURL: base.appendingPathComponent("Overseer/continuity.sqlite"),
            profile: profile,
            legacyDirectory: base
        )
    }

    let database: OverseerContinuityStore
    let legacyURL: URL
    let legacyPolicy: OverseerLegacyPolicy
    private let kind: OverseerContinuityKind
    private let mode: AgentSessionOversightPersistenceMode
    private let lock = NSLock()
    private var failure: String?
    private var migration: String?

    init(
        databaseURL: URL,
        profile: String,
        legacyURL: URL,
        kind: OverseerContinuityKind,
        mode: AgentSessionOversightPersistenceMode,
        legacyPolicy: OverseerLegacyPolicy
    ) {
        database = OverseerContinuityStore(databaseURL: databaseURL, profile: profile)
        self.legacyURL = legacyURL
        self.kind = kind
        self.mode = mode
        self.legacyPolicy = legacyPolicy
    }

    var diagnostic: String? {
        lock.withLock { failure ?? migration }
    }

    var performsFileIO: Bool {
        mode.performsProductionFileIO
    }

    func load() throws -> [OverseerContinuityRow] {
        guard mode.performsProductionFileIO else { return [] }
        do {
            // Open/validate the destination before attempting an import, never the reverse.
            _ = try database.engineSettings()
            do { try preserveLegacy() }
            catch { lock.withLock { migration = "Legacy source preserved for recovery; import could not complete (\(error)). Existing database continuity and new live approvals remain usable." } }
            let rows = try database.rows(kind: kind)
            lock.withLock { failure = nil }
            return rows
        } catch {
            lock.withLock { failure = "Continuity open failed (\(error)). Live user-approved authority remains usable; saving will retry. Source: \(legacyURL.lastPathComponent)." }
            throw error
        }
    }

    func commit(operationID: UUID, mutations: [OverseerContinuityMutation], origin: String) throws -> OverseerContinuityReceipt {
        guard mode.performsProductionFileIO else { throw OverseerContinuityError.unsafeLocation }
        do {
            let receipt = try database.commit(operationID: operationID, origin: origin, mutations: mutations)
            lock.withLock { failure = nil }
            return receipt
        } catch {
            lock.withLock { failure = "Continuity save failed (\(error)). The current live decision still applies in this process; it is not durably saved or shared. Saving will retry." }
            throw error
        }
    }

    private func preserveLegacy() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyURL.path) else { return }
        // Bound the read, reject aliases, and verify that the original inode/bytes did not change.
        let before = try fm.attributesOfItem(atPath: legacyURL.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
              let size = before[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024
        else {
            lock.withLock { migration = "Legacy continuity preserved in place; unsupported file or size. New user decisions remain usable." }
            return
        }
        let bytes = try Data(contentsOf: legacyURL)
        let after = try fm.attributesOfItem(atPath: legacyURL.path)
        guard before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.size] as? NSNumber == after[.size] as? NSNumber
        else {
            lock.withLock { migration = "Legacy continuity changed while being read; activation deferred, original untouched." }
            return
        }
        let digest = OverseerContinuityStore.digest(bytes)
        // Never probe the legacy flock: even a short shared lock can poison an older release
        // process's one-shot exclusive acquisition. Read/copy bytes only, without touching its lock.
        let reason = legacyPolicy == .sameProfile ? "same_profile_migration" : "user_review_required"
        let source = OverseerLegacySource(id: "\(kind.rawValue):\(OverseerContinuityStore.digest(Data(legacyURL.path.utf8))):\(digest)", path: legacyURL.path, digest: digest, bytes: bytes, reason: reason)
        let rows = Self.legacyRows(bytes, kind: kind)
        try database.archive(source, rows: rows)
        if rows.contains(where: { $0.mutation == nil }) {
            lock.withLock { migration = "Some legacy \(kind.rawValue) entries could not be validated (including any malformed terminal history). Their original bytes are preserved for recovery; only independently validated entries can restore. Existing database rows are unchanged." }
        }
        if legacyPolicy == .sameProfile {
            // Stable operation ID is kept in the ledger; archive outcomes make subsequent opens
            // idempotent even when the caller died immediately after activation.
            _ = try database.activateLegacy(sourceID: source.id, operationID: UUID(), origin: "same-profile-migration")
        } else {
            lock.withLock { migration = "Legacy \(kind.rawValue) continuity is preserved for explicit recovery (\(reason)); no unknown saved authority was activated. New user approvals remain usable." }
        }
    }

    static func scopeRow(_ grant: DomainDelegationScopeGrant) throws -> OverseerContinuityRow {
        let anchor: String?
        let workspace: String?
        switch grant.kind {
        case let .session(target): anchor = target.uuidString
            workspace = nil
        case let .tree(root): anchor = root.uuidString
            workspace = nil
        case let .workspace(id): anchor = nil
            workspace = id.uuidString
        case .allSessions: anchor = nil
            workspace = nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try .init(
            kind: .scope,
            id: grant.id.uuidString,
            parentID: grant.parentScopeID?.uuidString,
            ownerID: grant.granteeSessionID.uuidString,
            anchorID: anchor,
            workspaceID: workspace,
            capabilities: grant.capabilities.map(\.rawValue),
            expiresAt: grant.guardrails.expiresAt,
            payload: encoder.encode(grant)
        )
    }

    private static func legacyRows(_ bytes: Data, kind: OverseerContinuityKind) -> [OverseerLegacyRow] {
        guard let document = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = document["version"] as? Int, (1 ... (kind == .scope ? 2 : 1)).contains(version)
        else {
            return [.init(ordinal: 0, raw: bytes, mutation: nil, outcome: "rejected_document_schema")]
        }
        let key = kind == .scope ? "scopes" : kind == .link ? "links" : "worktrees"
        let values = document[key] as? [Any] ?? []
        let decoder = JSONDecoder()
        if kind == .worktree { decoder.dateDecodingStrategy = .iso8601 }
        var result: [OverseerLegacyRow] = []
        if let raw = document["revoked_scope_ids"] {
            guard let strings = raw as? [String], strings.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                return [.init(ordinal: 0, raw: bytes, mutation: nil, outcome: "rejected_terminal_history")]
            }
        }
        let revoked = Set((document["revoked_scope_ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
        // Terminal identities precede grants, so a stale grant in the same document never wins.
        for id in revoked.sorted(by: { $0.uuidString < $1.uuidString }) {
            result.append(.init(ordinal: result.count, raw: Data(id.uuidString.utf8), mutation: .revokeScope(id.uuidString), outcome: "review"))
        }
        var pending: [(Data, OverseerContinuityMutation?)] = values.map { value in
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])) ?? Data()
            let mutation: OverseerContinuityMutation? = switch kind {
            case .scope:
                (try? decoder.decode(DomainDelegationScopeGrant.self, from: data)).flatMap { try? .grant(scopeRow($0)) }
            case .link:
                (try? decoder.decode(AgentSessionOversightIntent.self, from: data)).flatMap { pair in
                    guard !pair.isSelfPair else { return nil }
                    return .put(.init(kind: .link, id: pair.continuityID, ownerID: pair.observerSessionID.uuidString, anchorID: pair.targetSessionID.uuidString, payload: data), expectedRevision: nil)
                }
            case .worktree:
                (try? decoder.decode(WorktreeOwnershipRecord.self, from: data)).map { .put(.init(kind: .worktree, id: $0.worktreeID, ownerID: $0.createdBySessionID?.uuidString, payload: data), expectedRevision: nil) }
            }
            return (data, mutation)
        }
        // Parents before attenuated children. Invalid/missing/cyclic chains remain recoverable rows.
        if kind == .scope {
            var seen = Set<String>()
            var ordered: [(Data, OverseerContinuityMutation?)] = []
            while !pending.isEmpty {
                guard let i = pending.firstIndex(where: { _, mutation in
                    guard case let .grant(row) = mutation else { return true }
                    return row.parentID == nil || row.parentID.map(seen.contains) == true
                }) else { ordered += pending
                    break
                }
                let item = pending.remove(at: i)
                if case let .grant(row) = item.1 { seen.insert(row.id) }
                ordered.append(item)
            }
            pending = ordered
        }
        for (data, mutation) in pending {
            result.append(.init(ordinal: result.count, raw: data, mutation: mutation, outcome: mutation == nil ? "rejected_row" : "review"))
        }
        return result
    }
}

extension AgentSessionOversightIntent {
    var continuityID: String {
        observerSessionID.uuidString + ":" + targetSessionID.uuidString
    }
}
