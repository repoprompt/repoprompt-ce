//
//  ErrorExtensions.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-10.
//
import Foundation
import RepoPromptAIContracts
import RepoPromptFoundation
import RepoPromptSecureStorage
import SwiftAnthropic
import SwiftOpenAI

extension Error {
    /// Converts this Error to a user-friendly message, accounting for known custom error types.
    func asFriendlyString() -> String {
        specializedFriendlyString() ?? genericFriendlyFallback()
    }

    /// Friendly text for known error types; `nil` when only the generic fallback applies.
    private func specializedFriendlyString() -> String? {
        // 1. Ask provider-specific errors for their stable user-facing message.
        if let friendlyError = self as? FriendlyErrorRepresentable {
            return friendlyError.friendlyErrorString
        }

        if let providerMessage = providerErrorFriendlyString() {
            return providerMessage
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

        // Secure-storage errors already provide sanitized, actionable messages.
        if let keychainError = self as? KeychainService.KeychainError {
            return [keychainError.errorDescription, keychainError.recoverySuggestion]
                .compactMap(\.self)
                .joined(separator: " ")
        }

        return nil
    }

    /// Opaque diagnostics for errors with no friendlier representation.
    private func genericFriendlyFallback() -> String {
        let nsError = self as NSError
        let domain = nsError.domain
        let code = nsError.code

        // Also show the `Error`’s default string (often "someEnumCase(...)")
        return "Unknown error [\(domain), code \(code)]: \(self)"
    }

    /// The message a wrapped provider error carries, or `nil` when it only has generic diagnostics.
    private func providerErrorFriendlyString() -> String? {
        guard let providerError = self as? AIProviderError else { return nil }
        switch providerError {
        case let .apiError(source), let .unknown(source):
            guard let source else { return nil }
            if let specialized = source.specializedFriendlyString() { return specialized }
            if let described = (source as? LocalizedError)?.errorDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines), !described.isEmpty
            {
                return described
            }
            if let described = ((source as NSError).userInfo[NSLocalizedDescriptionKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !described.isEmpty
            {
                return described
            }
            return source.genericFriendlyFallback()
        default:
            guard let described = providerError.errorDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines), !described.isEmpty
            else { return nil }
            return described
        }
    }
}
