//
//  ErrorExtensions.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-10.
//
import Foundation
import SwiftAnthropic
import SwiftOpenAI

extension Error {
    /// Converts this Error to a user-friendly message, accounting for known custom error types.
    func asFriendlyString() -> String {
        // 1. Check for CustomOpenAIProviderError
        if let openAIError = self as? CustomOpenAIProviderError {
            switch openAIError {
            case let .invalidToken(code, message):
                return "Request failed with code \(code): \(message)"
            case let .invalidModel(code, message):
                return "Model invalid (code \(code)): \(message)"
            case let .requestFailed(code, message):
                return "Request failed (code \(code)): \(message)"
            case let .invalidResponse(code, message):
                return "Invalid response (code \(code)): \(message)"
            case let .streamingNotSupported(code, message):
                return "Streaming not supported (code \(code)): \(message)"
            case let .rateLimitExceeded(code, message):
                return "Rate limit exceeded (code \(code)): \(message)"
            case let .serverError(code, message):
                return "Server error (code \(code)): \(message)"
            case let .serviceUnavailable(code, message):
                return "Service unavailable (code \(code)): \(message)"
            case let .requestTooLarge(code, message):
                return "Request too large (code \(code)): \(message)"
            }
        }

        // 2. Check if this is a struct conforming to Error like OpenAIErrorResponse
        //    (You'd need `extension OpenAIErrorResponse: Error` in order to cast successfully.)
        if let openAIResponse = self as? OpenAIErrorResponse {
            // The nested error details, e.g.:
            let inner = openAIResponse.error
            let code = inner.code ?? "(no code)"
            let message = inner.message ?? "(no message)"

            // Special handling for the "no additional details" case
            if message == "(no additional details)" || message.contains("no additional details") {
                return "OpenAI error: Request failed. This often occurs when the request is too large. Try reducing the number of selected files."
            }

            return "OpenAI error (\(code)): \(message)"
        }

        // 3. Check for APIError from your enum
        if let apiErr = self as? SwiftOpenAI.APIError {
            // You already have .displayDescription for each case
            return apiErr.displayDescription
        }

        if let apiErr = self as? SwiftAnthropic.APIError {
            // You already have .displayDescription for each case
            return apiErr.displayDescription
        }

        if let localizedError = self as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty
        {
            return description
        }

        // 4. Fallback to NSError bridging:
        let nsError = self as NSError
        let domain = nsError.domain
        let code = nsError.code

        // Also show the `Error`’s default string (often "someEnumCase(...)")
        return "Unknown error [\(domain), code \(code)]: \(self)"
    }
}
