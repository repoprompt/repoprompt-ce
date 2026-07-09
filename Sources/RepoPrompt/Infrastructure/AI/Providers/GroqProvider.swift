//
//  GroqProvider.swift
//  RepoPrompt
//
//  Created by AI Assistant on 2025-07-15.
//

import Foundation
import SwiftOpenAI

final class GroqProvider: OpenAIProvider {
    init(apiKey: String) {
        let baseURL = URL(string: "https://api.groq.com/openai")!
        super.init(
            apiKey: apiKey,
            baseURL: baseURL,
            configuredMaxTokens: 16384, // Set max output tokens to 16,384
            overrideVersion: "v1",
            transportOwner: .groq
        )
    }

    override func testAPIKey(model: AIModel = .groqKimi) async throws -> Bool {
        let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        do {
            let stream = try await streamMessage(testMessage, model: model)
            var response = ""
            for try await result in stream {
                if let text = result.text {
                    response += text
                }
                if result.type == "message_stop" {
                    break
                }
            }
            // Check for a common greeting word
            return response.lowercased().contains("hello") || response.lowercased().contains("hi")
        } catch {
            print("Groq API Key Test Failed: \(error.asFriendlyString())")
            return false
        }
    }
}
