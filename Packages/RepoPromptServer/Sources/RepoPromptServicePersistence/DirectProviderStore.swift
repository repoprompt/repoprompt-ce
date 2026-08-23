import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import SQLiteNIO

public extension SQLiteServiceStore {
    func directProviderConfigurations() async throws -> [DirectProviderConfiguration] {
        try await database.query(
            "SELECT configuration_json FROM provider_direct_configurations ORDER BY provider_id"
        ).map { row in
            guard let json = row.column("configuration_json")?.string else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Direct provider configuration is corrupt", retryable: false)
            }
            return try decoder.decode(DirectProviderConfiguration.self, from: Data(json.utf8))
        }
    }

    func directProviderConfiguration(providerID: ProviderSettingsID) async throws -> DirectProviderConfiguration? {
        guard let json = try await database.query(
            "SELECT configuration_json FROM provider_direct_configurations WHERE provider_id=?",
            [.text(providerID.rawValue)]
        ).first?.column("configuration_json")?.string else { return nil }
        return try decoder.decode(DirectProviderConfiguration.self, from: Data(json.utf8))
    }

    @discardableResult
    func upsertDirectProviderConfiguration(
        _ value: DirectProviderConfiguration,
        expectedRevision: Int64,
        audit: ProviderConnectionAuditMutation? = nil
    ) async throws -> DirectProviderConfiguration {
        let retainedBytes = try retainedInputBytes(value, additional: retainedProviderAuditBytes(audit))
        return try await transaction(.interactive(estimatedEncodedBytes: retainedBytes)) {
            guard value.providerID.isDirectAPI, value.revision == expectedRevision + 1 else {
                throw ServiceAPIError(code: .invalidRequest, message: "Direct provider configuration revision is invalid")
            }
            let observed = Int64(try await database.query(
                "SELECT revision FROM provider_direct_configurations WHERE provider_id=?",
                [.text(value.providerID.rawValue)]
            ).first?.column("revision")?.integer ?? 0)
            guard observed == expectedRevision else {
                throw ServiceAPIError(code: .staleRevision, message: "Direct provider configuration revision is stale", currentRevision: observed)
            }
            let json = String(decoding: try encoder.encode(value), as: UTF8.self)
            _ = try await database.query(
                "INSERT INTO provider_direct_configurations(provider_id,configuration_json,revision,updated_at) VALUES(?,?,?,?) ON CONFLICT(provider_id) DO UPDATE SET configuration_json=excluded.configuration_json,revision=excluded.revision,updated_at=excluded.updated_at",
                [.text(value.providerID.rawValue), .text(json), .integer(Int(value.revision)), .float(value.updatedAt.timeIntervalSince1970)]
            )
            if let audit {
                try await appendProviderConnectionAuditInTransaction(
                    providerID: value.providerID,
                    connectionID: nil,
                    mutation: audit
                )
            }
            return value
        }
    }

    func authorityStore_providerModelCatalogs() async throws -> [ProviderModelCatalogSnapshot] {
        try await database.query(
            "SELECT provider_id,catalog_json,revision,refreshed_at FROM provider_model_catalogs ORDER BY provider_id"
        ).map { row in
            guard let rawProviderID = row.column("provider_id")?.string,
                  let providerID = ProviderSettingsID(rawValue: rawProviderID),
                  let json = row.column("catalog_json")?.string,
                  let revision = row.column("revision")?.integer,
                  let refreshedAt = row.column("refreshed_at")?.double
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider model catalog is corrupt", retryable: false)
            }
            let models = try decoder.decode([ProviderModelCatalogEntry].self, from: Data(json.utf8))
            return ProviderModelCatalogSnapshot(providerID: providerID, models: models, revision: Int64(revision), refreshedAt: Date(timeIntervalSince1970: refreshedAt))
        }
    }

    func authorityStore_providerModelCatalog(providerID: ProviderSettingsID) async throws -> ProviderModelCatalogSnapshot? {
        guard let row = try await database.query(
            "SELECT catalog_json,revision,refreshed_at FROM provider_model_catalogs WHERE provider_id=?",
            [.text(providerID.rawValue)]
        ).first,
        let json = row.column("catalog_json")?.string,
        let revision = row.column("revision")?.integer,
        let refreshedAt = row.column("refreshed_at")?.double
        else { return nil }
        return ProviderModelCatalogSnapshot(
            providerID: providerID,
            models: try decoder.decode([ProviderModelCatalogEntry].self, from: Data(json.utf8)),
            revision: Int64(revision),
            refreshedAt: Date(timeIntervalSince1970: refreshedAt)
        )
    }

    @discardableResult
    func authorityStore_replaceProviderModelCatalog(
        providerID: ProviderSettingsID,
        models: [ProviderModelCatalogEntry],
        expectedRevision: Int64
    ) async throws -> ProviderModelCatalogSnapshot {
        let retainedBytes = try retainedInputBytes(models)
        return try await transaction(.interactive(estimatedEncodedBytes: retainedBytes)) {
            let observed = Int64(try await database.query(
                "SELECT revision FROM provider_model_catalogs WHERE provider_id=?",
                [.text(providerID.rawValue)]
            ).first?.column("revision")?.integer ?? 0)
            guard observed == expectedRevision else {
                throw ServiceAPIError(code: .staleRevision, message: "Provider model catalog revision is stale", currentRevision: observed)
            }
            let refreshedAt = Date()
            let next = ProviderModelCatalogSnapshot(providerID: providerID, models: models, revision: observed + 1, refreshedAt: refreshedAt)
            let json = String(decoding: try encoder.encode(models), as: UTF8.self)
            _ = try await database.query(
                "INSERT INTO provider_model_catalogs(provider_id,catalog_json,revision,refreshed_at) VALUES(?,?,?,?) ON CONFLICT(provider_id) DO UPDATE SET catalog_json=excluded.catalog_json,revision=excluded.revision,refreshed_at=excluded.refreshed_at",
                [.text(providerID.rawValue), .text(json), .integer(Int(next.revision)), .float(refreshedAt.timeIntervalSince1970)]
            )
            return next
        }
    }
}
