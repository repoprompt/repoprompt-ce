import RepoPromptFoundation

extension CustomOpenAIProviderError: FriendlyErrorRepresentable {
    var friendlyErrorString: String {
        switch self {
        case let .invalidToken(code, message):
            "Request failed with code \(code): \(message)"
        case let .invalidModel(code, message):
            "Model invalid (code \(code)): \(message)"
        case let .requestFailed(code, message):
            "Request failed (code \(code)): \(message)"
        case let .invalidResponse(code, message):
            "Invalid response (code \(code)): \(message)"
        case let .streamingNotSupported(code, message):
            "Streaming not supported (code \(code)): \(message)"
        case let .rateLimitExceeded(code, message):
            "Rate limit exceeded (code \(code)): \(message)"
        case let .serverError(code, message):
            "Server error (code \(code)): \(message)"
        case let .serviceUnavailable(code, message):
            "Service unavailable (code \(code)): \(message)"
        case let .requestTooLarge(code, message):
            "Request too large (code \(code)): \(message)"
        }
    }
}
