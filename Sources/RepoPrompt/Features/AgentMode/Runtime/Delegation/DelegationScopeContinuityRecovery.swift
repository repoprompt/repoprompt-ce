import Foundation
import RepoPromptDomainRuntime

/// Preserved mixed-source descriptions, not restored authority. The user's explicit UI action
/// approves new root grant identities; it can never revive a revoked old ID or lift attenuation.
struct DelegationScopeRecoveryOffer: Identifiable {
    let id: String
    let grants: [DomainDelegationScopeGrant]
    let retainedOtherRows: Int
}

extension DelegationScopeStore {
    func recoveryOffers(now: Date) -> [DelegationScopeRecoveryOffer] {
        guard repository.performsFileIO, repository.legacyPolicy == .userReview,
              let sources = try? repository.database.legacySources() else { return [] }
        return sources.compactMap { source in
            guard source.id.hasPrefix("scope:"),
                  let json = try? JSONSerialization.jsonObject(with: source.bytes) as? [String: Any],
                  let version = json["version"] as? Int, (1 ... 2).contains(version),
                  let rows = json["scopes"] as? [Any] else { return nil }
            if let raw = json["revoked_scope_ids"] {
                guard let ids = raw as? [String], ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { return nil }
            }
            let revoked = Set((json["revoked_scope_ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
            let grants = rows.compactMap { value -> DomainDelegationScopeGrant? in
                guard let bytes = try? JSONSerialization.data(withJSONObject: value),
                      let grant = try? JSONDecoder().decode(DomainDelegationScopeGrant.self, from: bytes),
                      grant.parentScopeID == nil, !revoked.contains(grant.id),
                      grant.guardrails.expiresAt.map({ $0 > now }) ?? true else { return nil }
                // Do not ask again when saved continuity already covers this exact description.
                // Suppressing a proposal can never create or widen authority.
                guard !restoredDescriptions.contains(where: {
                    $0.parentScopeID == nil && $0.granteeSessionID == grant.granteeSessionID
                        && $0.kind == grant.kind && $0.capabilities == grant.capabilities && $0.guardrails == grant.guardrails
                }) else { return nil }
                return grant
            }
            guard !grants.isEmpty else { return nil }
            return .init(id: source.id, grants: grants, retainedOtherRows: rows.count - grants.count)
        }
    }
}
