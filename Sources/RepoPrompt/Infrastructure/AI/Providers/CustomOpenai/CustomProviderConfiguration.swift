import Foundation

struct CustomProviderConfiguration: Codable {
    let url: String
    let defaultModel: String
    let headers: [String: String]
    let name: String
    var enabledModels: Set<String>
    private static let defaultTemperature = 0.3
    var maxTokens: Int? // Add the new optional maxTokens property
    var userPreferredModel: String?
    var includeContentTypeHeader: Bool = false // Add flag for Content-Type header
    var httpCredentialConsentEndpoint: String? = nil
    var apiVersion: String? = nil // NEW: optional API version (e.g., "v1", "v4")

    enum CodingKeys: String, CodingKey {
        case url, defaultModel, headers, name, enabledModels, maxTokens, userPreferredModel, includeContentTypeHeader, apiVersion, httpCredentialConsentEndpoint
    }

    /// Custom decoder to handle backwards compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        defaultModel = try container.decode(String.self, forKey: .defaultModel)
        headers = try container.decode([String: String].self, forKey: .headers)
        name = try container.decode(String.self, forKey: .name)
        enabledModels = try container.decode(Set<String>.self, forKey: .enabledModels)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        userPreferredModel = try container.decodeIfPresent(String.self, forKey: .userPreferredModel)
        // Default to false for backwards compatibility
        includeContentTypeHeader = try container.decodeIfPresent(Bool.self, forKey: .includeContentTypeHeader) ?? false
        httpCredentialConsentEndpoint = try container.decodeIfPresent(String.self, forKey: .httpCredentialConsentEndpoint)
        apiVersion = try container.decodeIfPresent(String.self, forKey: .apiVersion) // may be nil for legacy
    }

    /// Manual initializer
    init(url: String, defaultModel: String, headers: [String: String], name: String, enabledModels: Set<String> = [], maxTokens: Int? = nil, userPreferredModel: String? = nil, includeContentTypeHeader: Bool = false, apiVersion: String? = nil, httpCredentialConsentEndpoint: String? = nil) throws { // Add maxTokens, includeContentTypeHeader, apiVersion
        guard !url.isEmpty else {
            throw AIProviderError.missingURL
        }
        guard !defaultModel.isEmpty else {
            throw AIProviderError.invalidModel
        }
        guard !name.isEmpty else {
            throw AIProviderError.providerNotConfigured
        }

        self.url = url
        self.defaultModel = defaultModel
        self.headers = headers
        self.name = name
        self.enabledModels = enabledModels
        self.maxTokens = maxTokens // Initialize the new property
        self.userPreferredModel = userPreferredModel
        self.includeContentTypeHeader = includeContentTypeHeader // Initialize the new flag
        self.apiVersion = apiVersion
        self.httpCredentialConsentEndpoint = httpCredentialConsentEndpoint
    }

    var effectiveDefaultModel: String {
        userPreferredModel?.isEmpty == false ? userPreferredModel! : defaultModel
    }

    static func load() throws -> CustomProviderConfiguration {
        guard let data = UserDefaults.standard.data(forKey: "CustomProviderConfig") else {
            throw AIProviderError.providerNotConfigured
        }
        return try JSONDecoder().decode(CustomProviderConfiguration.self, from: data)
    }

    static func save(_ config: CustomProviderConfiguration) throws {
        let data = try JSONEncoder().encode(config)
        UserDefaults.standard.set(data, forKey: "CustomProviderConfig")
    }

    static func save(_ config: CustomProviderConfiguration, apiKey: String, keyManager: KeyManager) async throws {
        try ProviderEndpointConsent.validate(config.url, credentialBearing: ProviderEndpointConsent.hasCredentials(apiKey: apiKey, customHeaders: config.headers), consentEndpoint: config.httpCredentialConsentEndpoint)
        try save(config)
        try await keyManager.saveAPIKey(apiKey, for: .customProvider)
    }

    static func revokeHTTPConsent(defaults: UserDefaults = .standard) throws {
        guard let data = defaults.data(forKey: "CustomProviderConfig") else { return }
        var config = try JSONDecoder().decode(CustomProviderConfiguration.self, from: data)
        config.httpCredentialConsentEndpoint = nil
        try defaults.set(JSONEncoder().encode(config), forKey: "CustomProviderConfig")
    }

    static func delete() {
        UserDefaults.standard.removeObject(forKey: "CustomProviderConfig")
    }

    mutating func updateModelSettings(model: String, isEnabled: Bool) {
        if isEnabled {
            enabledModels.insert(model)
        } else {
            enabledModels.remove(model)
        }
    }

    func toProvider(apiKey: String) -> CustomOpenAIProvider {
        // Note: The factory currently doesn't use this method directly for instantiation.
        // If it did, we would need to pass self.maxTokens and includeContentTypeHeader here.
        CustomOpenAIProvider(
            baseURL: url,
            apiKey: apiKey,
            defaultModel: defaultModel,
            defaultTemperature: Self.defaultTemperature,
            customHeaders: headers,
            configuredMaxTokens: maxTokens,
            includeContentTypeHeader: includeContentTypeHeader,
            apiVersion: apiVersion,
            httpCredentialConsentEndpoint: httpCredentialConsentEndpoint
        )
    }
}
