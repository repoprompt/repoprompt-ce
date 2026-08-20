import Foundation

public enum DirectProviderContentTypePolicy: String, Codable, CaseIterable, Sendable {
    case applicationJSON
}

/// Revisioned, non-secret configuration for a direct HTTPS provider. Fixed-host
/// providers keep `baseURL == nil` unless Desktop persists a custom URL (OpenAI).
/// Custom OpenAI-compatible and Azure persist a public HTTPS base URL. Ollama
/// persists Desktop's URL (default localhost). Azure / OpenAI / custom may
/// persist `apiVersion`; the API key stays in the vault.
public struct DirectProviderConfiguration: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let baseURL: String?
    public let preferredModel: String?
    public let maximumOutputTokens: Int
    public let customHeaders: [String: String]
    public let contentTypePolicy: DirectProviderContentTypePolicy
    public let apiVersion: String?
    public let enabledModels: [String]
    public let includeDefaultModels: Bool
    public let useCustomSettings: Bool
    public let includeContentTypeHeader: Bool
    public let showServiceTierVariants: Bool
    public let revision: Int64
    public let updatedAt: Date

    public init(
        providerID: ProviderSettingsID,
        baseURL: String? = nil,
        preferredModel: String? = nil,
        maximumOutputTokens: Int = 4096,
        customHeaders: [String: String] = [:],
        contentTypePolicy: DirectProviderContentTypePolicy = .applicationJSON,
        apiVersion: String? = nil,
        enabledModels: [String] = [],
        includeDefaultModels: Bool = true,
        useCustomSettings: Bool = true,
        includeContentTypeHeader: Bool = false,
        showServiceTierVariants: Bool = false,
        revision: Int64 = 1,
        updatedAt: Date = Date()
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.preferredModel = preferredModel
        self.maximumOutputTokens = maximumOutputTokens
        self.customHeaders = customHeaders
        self.contentTypePolicy = contentTypePolicy
        self.apiVersion = apiVersion
        self.enabledModels = enabledModels
        self.includeDefaultModels = includeDefaultModels
        self.useCustomSettings = useCustomSettings
        self.includeContentTypeHeader = includeContentTypeHeader
        self.showServiceTierVariants = showServiceTierVariants
        self.revision = revision
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case providerID, baseURL, preferredModel, maximumOutputTokens, customHeaders
        case contentTypePolicy, apiVersion, enabledModels, includeDefaultModels
        case useCustomSettings, includeContentTypeHeader, showServiceTierVariants
        case revision, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(ProviderSettingsID.self, forKey: .providerID)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        preferredModel = try container.decodeIfPresent(String.self, forKey: .preferredModel)
        maximumOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maximumOutputTokens) ?? 4096
        customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        contentTypePolicy = try container.decodeIfPresent(DirectProviderContentTypePolicy.self, forKey: .contentTypePolicy) ?? .applicationJSON
        apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion)
        enabledModels = try container.decodeIfPresent([String].self, forKey: .enabledModels) ?? []
        includeDefaultModels = try container.decodeIfPresent(Bool.self, forKey: .includeDefaultModels) ?? true
        useCustomSettings = try container.decodeIfPresent(Bool.self, forKey: .useCustomSettings) ?? true
        includeContentTypeHeader = try container.decodeIfPresent(Bool.self, forKey: .includeContentTypeHeader) ?? false
        showServiceTierVariants = try container.decodeIfPresent(Bool.self, forKey: .showServiceTierVariants) ?? false
        revision = try container.decode(Int64.self, forKey: .revision)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// Desktop picker: custom is allowlist + preferred; OpenRouter unions defaults
    /// when `includeDefaultModels` is on. Diff/Content-Type toggles are persist-only.
    public func resolvedCatalog(discovered: [ProviderModelCatalogEntry]) -> [ProviderModelCatalogEntry] {
        let extras = allowlistedModelIDs
        switch providerID {
        case .customOpenAICompatible:
            return catalog(from: discovered, allowed: extras, includeDiscovered: false)
        case .openRouter:
            return catalog(from: discovered, allowed: extras, includeDiscovered: includeDefaultModels)
        case .openAIAPI:
            let merged = Self.merging(discovered, extras: extras)
            guard showServiceTierVariants else {
                return merged.map {
                    ProviderModelCatalogEntry(
                        id: $0.id,
                        providerRawValue: $0.providerRawValue,
                        displayName: $0.displayName,
                        description: $0.description,
                        isProviderDefault: $0.isProviderDefault,
                        reasoningEfforts: $0.reasoningEfforts,
                        defaultReasoningEffort: $0.defaultReasoningEffort,
                        serviceTier: $0.serviceTier,
                        speedModes: $0.speedModes,
                        serviceTiers: [],
                        supportsNativeImages: $0.supportsNativeImages,
                        supportsSteering: $0.supportsSteering
                    )
                }
            }
            return merged
        default:
            return Self.merging(discovered, extras: extras)
        }
    }

    public func allowsLaunchModel(_ model: String) -> Bool {
        switch providerID {
        case .customOpenAICompatible:
            allowlistedModelIDs.contains(model)
        case .openRouter:
            includeDefaultModels || allowlistedModelIDs.contains(model)
        default:
            true
        }
    }

    public var allowlistedModelIDs: Set<String> {
        var allowed = Set(enabledModels)
        if let preferredModel, !preferredModel.isEmpty { allowed.insert(preferredModel) }
        return allowed
    }

    private func catalog(
        from discovered: [ProviderModelCatalogEntry],
        allowed: Set<String>,
        includeDiscovered: Bool
    ) -> [ProviderModelCatalogEntry] {
        let base = includeDiscovered ? discovered : discovered.filter { allowed.contains($0.id) }
        return Self.merging(base, extras: allowed)
    }

    private static func merging(_ models: [ProviderModelCatalogEntry], extras: Set<String>) -> [ProviderModelCatalogEntry] {
        var next = models
        for id in extras where !next.contains(where: { $0.id == id }) {
            next.append(ProviderModelCatalogEntry(id: id, displayName: id))
        }
        return next.sorted { $0.id < $1.id }
    }
}

/// Full replacement avoids omitted-versus-null ambiguity. Credential material
/// is intentionally absent and enters only through the Headless runtime port.
public struct UpdateDirectProviderConfigurationRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let baseURL: String?
    public let preferredModel: String?
    public let maximumOutputTokens: Int
    public let customHeaders: [String: String]
    public let contentTypePolicy: DirectProviderContentTypePolicy
    public let apiVersion: String?
    public let enabledModels: [String]
    public let includeDefaultModels: Bool
    public let useCustomSettings: Bool
    public let includeContentTypeHeader: Bool
    public let showServiceTierVariants: Bool

    public init(
        expectedRevision: Int64,
        baseURL: String?,
        preferredModel: String?,
        maximumOutputTokens: Int,
        customHeaders: [String: String],
        contentTypePolicy: DirectProviderContentTypePolicy = .applicationJSON,
        apiVersion: String? = nil,
        enabledModels: [String] = [],
        includeDefaultModels: Bool = true,
        useCustomSettings: Bool = true,
        includeContentTypeHeader: Bool = false,
        showServiceTierVariants: Bool = false
    ) {
        self.expectedRevision = expectedRevision
        self.baseURL = baseURL
        self.preferredModel = preferredModel
        self.maximumOutputTokens = maximumOutputTokens
        self.customHeaders = customHeaders
        self.contentTypePolicy = contentTypePolicy
        self.apiVersion = apiVersion
        self.enabledModels = enabledModels
        self.includeDefaultModels = includeDefaultModels
        self.useCustomSettings = useCustomSettings
        self.includeContentTypeHeader = includeContentTypeHeader
        self.showServiceTierVariants = showServiceTierVariants
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision, baseURL, preferredModel, maximumOutputTokens, customHeaders
        case contentTypePolicy, apiVersion, enabledModels, includeDefaultModels
        case useCustomSettings, includeContentTypeHeader, showServiceTierVariants
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expectedRevision = try container.decode(Int64.self, forKey: .expectedRevision)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        preferredModel = try container.decodeIfPresent(String.self, forKey: .preferredModel)
        maximumOutputTokens = try container.decode(Int.self, forKey: .maximumOutputTokens)
        customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        contentTypePolicy = try container.decodeIfPresent(DirectProviderContentTypePolicy.self, forKey: .contentTypePolicy) ?? .applicationJSON
        apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion)
        enabledModels = try container.decodeIfPresent([String].self, forKey: .enabledModels) ?? []
        includeDefaultModels = try container.decodeIfPresent(Bool.self, forKey: .includeDefaultModels) ?? true
        useCustomSettings = try container.decodeIfPresent(Bool.self, forKey: .useCustomSettings) ?? true
        includeContentTypeHeader = try container.decodeIfPresent(Bool.self, forKey: .includeContentTypeHeader) ?? false
        showServiceTierVariants = try container.decodeIfPresent(Bool.self, forKey: .showServiceTierVariants) ?? false
    }
}

public struct ProviderModelCatalogSnapshot: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let models: [ProviderModelCatalogEntry]
    public let revision: Int64
    public let refreshedAt: Date

    public init(providerID: ProviderSettingsID, models: [ProviderModelCatalogEntry], revision: Int64, refreshedAt: Date = Date()) {
        self.providerID = providerID
        self.models = models
        self.revision = revision
        self.refreshedAt = refreshedAt
    }
}

public struct DirectProviderEndpoint: Codable, Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int
    public let basePath: String

    public init(scheme: String, host: String, port: Int, basePath: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.basePath = basePath
    }
}
