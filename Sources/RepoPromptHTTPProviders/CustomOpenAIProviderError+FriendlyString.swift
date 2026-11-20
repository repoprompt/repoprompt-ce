import Foundation
import RepoPromptAIContracts
import RepoPromptFoundation

/// Preserve the measured pre-extraction NSError bridge. These are Swift case ordinals,
/// not the independent HTTP status carried by each case; userInfo remains empty.
extension CustomOpenAIProviderError: CustomNSError {
    package static var errorDomain: String {
        "RepoPromptApp.CustomOpenAIProviderError"
    }

    package var errorCode: Int {
        switch self {
        case .invalidToken: 0
        case .invalidModel: 1
        case .requestFailed: 2
        case .invalidResponse: 3
        case .streamingNotSupported: 4
        case .rateLimitExceeded: 5
        case .serverError: 6
        case .serviceUnavailable: 7
        case .requestTooLarge: 8
        }
    }

    package var errorUserInfo: [String: Any] {
        [:]
    }
}

extension CustomOpenAIProviderError: FriendlyErrorRepresentable {
    package var friendlyErrorString: String {
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
