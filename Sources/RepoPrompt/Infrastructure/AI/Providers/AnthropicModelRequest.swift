import Foundation
import SwiftAnthropic

/// Adds advertised Messages capabilities while retaining the SDK's message encoder
/// and transport. Legacy budget-based thinking remains on the existing SDK path.
struct AnthropicModelRequest: Encodable {
    let parameters: MessageParameter
    let effort: ClaudeCodeEffortLevel?
    let adaptiveThinking: Bool

    private enum CodingKeys: String, CodingKey {
        case thinking
        case outputConfig = "output_config"
    }

    func encode(to encoder: Encoder) throws {
        try parameters.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        if adaptiveThinking {
            try container.encode(["type": "adaptive"], forKey: .thinking)
        }
        if let effort {
            try container.encode(["effort": effort.rawValue], forKey: .outputConfig)
        }
    }

    func request(apiKey: String, betaHeaders: [String]) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw AIProviderError.invalidModel }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !betaHeaders.isEmpty { request.setValue(betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(self)
        return request
    }
}
