import Foundation

enum GrokModelCatalog {
    private static let cache = ProviderModelDiscoveryCache<String>(key: "GrokDiscoveredChatModels", identity: { $0 })

    static func names(defaults: UserDefaults = .standard) -> [String] {
        cache.current(defaults: defaults)
    }

    @discardableResult
    static func save(_ names: [String], defaults: UserDefaults = .standard) -> Bool {
        cache.save(names, defaults: defaults)
    }

    static func parse(_ models: [[String: Any]]) -> [String] {
        models.compactMap { model in
            guard let id = model["id"] as? String, !id.isEmpty,
                  (model["input_modalities"] as? [String])?.contains("text") == true,
                  (model["output_modalities"] as? [String])?.contains("text") == true else { return nil }
            return id
        }
    }

    static func fetch(apiKey: String, client: any HTTPClient = DefaultHTTPClient.discoveryClient) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/language-models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let response = try await client.data(for: request)
        guard response.http.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let models = body["models"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        return parse(models)
    }
}
