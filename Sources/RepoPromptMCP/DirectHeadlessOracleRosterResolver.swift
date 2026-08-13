import Foundation
import MCP
import RepoPromptDomainRuntime

struct DirectHeadlessOracleRosterResolver: OracleRosterResolver {
    static let providerID = "codexExec"

    private let settingsStore: DomainDirectSettingsStore

    init(settingsStore: DomainDirectSettingsStore) {
        self.settingsStore = settingsStore
    }

    func resolveRoster(for request: OracleRosterResolutionRequest) async throws -> OracleRoster {
        await settingsStore.bootstrap()
        let primaryValue = try await settingsStore.effectiveValue(for: OracleRosterContract.primarySettingKey)
        let additionalValue = try await settingsStore.effectiveValue(for: OracleRosterContract.additionalSettingKey)

        let configuredPrimary: String
        switch primaryValue {
        case .null:
            configuredPrimary = "default"
        case let .string(value):
            configuredPrimary = value
        default:
            throw MCPError.internalError("Oracle model setting has an invalid value type.")
        }

        let additional: [String]
        switch additionalValue {
        case let .stringArray(values):
            additional = values
        default:
            throw MCPError.internalError("Additional Oracle model setting has an invalid value type.")
        }

        return try OracleRoster(
            primaryModelID: request.primaryModelOverride ?? configuredPrimary,
            additionalModelIDs: additional,
            providerID: Self.providerID
        )
    }
}
