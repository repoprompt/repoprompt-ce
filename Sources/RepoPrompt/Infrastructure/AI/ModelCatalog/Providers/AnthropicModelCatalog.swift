import Foundation

enum AnthropicModelCatalog {
    struct Record: Codable, Equatable {
        let id: String
        let displayName: String
        let efforts: [ClaudeCodeEffortLevel]
        let adaptiveThinking: Bool
    }

    private static let cache = ProviderModelDiscoveryCache<Record>(key: "AnthropicDiscoveredModels", identity: { $0.id })

    static func fetch(apiKey: String, client: any HTTPClient = DefaultHTTPClient.discoveryClient) async throws -> [Record] {
        var records: [Record] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
            var request = URLRequest(url: components.url!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let response = try await client.data(for: request)
            guard response.http.statusCode == 200,
                  let page = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let entries = page["data"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
            records.append(contentsOf: parse(entries))
            guard page["has_more"] as? Bool == true else { break }
            guard let next = page["last_id"] as? String, !next.isEmpty, seen.insert(next).inserted else {
                throw URLError(.badServerResponse)
            }
            cursor = next
        } while true
        return records
    }

    static func records(defaults: UserDefaults = .standard) -> [Record] {
        cache.current(defaults: defaults)
    }

    static func record(for id: String, defaults: UserDefaults = .standard) -> Record? {
        cache.remembered(defaults: defaults).first { $0.id == id }
    }

    static func parse(_ entries: [[String: Any]]) -> [Record] {
        entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let capabilities = entry["capabilities"] as? [String: Any] ?? [:]
            let effort = capabilities["effort"] as? [String: Any] ?? [:]
            let efforts = ["low", "medium", "high", "xhigh", "max"].compactMap { level -> ClaudeCodeEffortLevel? in
                guard effort["supported"] as? Bool != false,
                      (effort[level] as? [String: Any])?["supported"] as? Bool == true else { return nil }
                return ClaudeCodeEffortLevel.parse(level)
            }
            let thinking = capabilities["thinking"] as? [String: Any] ?? [:]
            let thinkingTypes = thinking["types"] as? [String: Any] ?? [:]
            return Record(
                id: id,
                displayName: entry["display_name"] as? String ?? id,
                efforts: efforts,
                adaptiveThinking: thinking["supported"] as? Bool != false && (thinkingTypes["adaptive"] as? [String: Any])?["supported"] as? Bool == true
            )
        }
    }

    @discardableResult
    static func save(_ records: [Record], defaults: UserDefaults = .standard) -> Bool {
        cache.save(records, defaults: defaults)
    }

    static func models(defaults: UserDefaults = .standard) -> [AIModel] {
        records(defaults: defaults).flatMap { record in
            [.anthropicCustom(name: record.id)] + record.efforts.map {
                .anthropicCustomReasoning(name: record.id, effort: $0)
            }
        }
    }
}
