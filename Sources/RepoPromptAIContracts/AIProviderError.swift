import Foundation

package enum AIProviderError: Error {
    case missingOllamaURL
    case missingAzureConfiguration
    case missingAPIKey
    case missingURL
    case providerNotConfigured
    case invalidModel
    case invalidSystemPrompt
    case messageCreationFailed
    case invalidResponse(detail: String) // Add associated value 'detail'
    case invalidConfiguration(detail: String) // Added for configuration issues
    case apiError(source: Error?) // Added for underlying API errors
    case unknown(source: Error?) // Added for other unexpected errors
}

extension AIProviderError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .missingOllamaURL:
            "Missing Ollama URL."
        case .missingAzureConfiguration:
            "Missing Azure OpenAI configuration."
        case .missingAPIKey:
            "Missing API key."
        case .missingURL:
            "Missing provider URL."
        case .providerNotConfigured:
            "Provider is not configured."
        case .invalidModel:
            "Invalid model."
        case .invalidSystemPrompt:
            "Invalid system prompt."
        case .messageCreationFailed:
            "Failed to create provider message."
        case let .invalidResponse(detail), let .invalidConfiguration(detail):
            detail
        case let .apiError(source), let .unknown(source):
            source?.localizedDescription ?? String(describing: self)
        }
    }
}
