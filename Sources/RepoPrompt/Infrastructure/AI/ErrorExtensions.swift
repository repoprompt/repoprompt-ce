//
//  ErrorExtensions.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-10.
//
import Foundation
import RepoPromptFoundation
import SwiftAnthropic
import SwiftOpenAI

extension Error {
    /// Converts this Error to a user-friendly message, accounting for known custom error types.
    func asFriendlyString() -> String {
        // 1. Ask provider-specific errors for their stable user-facing message.
        if let friendlyError = self as? FriendlyErrorRepresentable {
            return friendlyError.friendlyErrorString
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

        // 4. Fallback to NSError bridging:
        let nsError = self as NSError
        let domain = nsError.domain
        let code = nsError.code

        // Also show the `Error`’s default string (often "someEnumCase(...)")
        return "Unknown error [\(domain), code \(code)]: \(self)"
    }
}
