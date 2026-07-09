//
//  FireworksProvider.swift
//  RepoPrompt
//
//  Created by Your Name on 2024-07-29.
//

import Foundation
import SwiftOpenAI

final class FireworksProvider: OpenAIProvider {
    init(apiKey: String) {
        let baseURL = URL(string: "https://api.fireworks.ai/inference")!
        super.init(
            apiKey: apiKey,
            baseURL: baseURL,
            configuredMaxTokens: nil, // Use model-specific max tokens
            overrideVersion: "v1",
            transportOwner: .fireworks
        )
    }

    /// Override to provide model-specific max tokens
    override func providerSpecificMaxTokens(for model: AIModel) -> Int? {
        model.maxTokens
    }

    override func testAPIKey(model: AIModel = .fireworksDeepseekV3p1Terminus) async throws -> Bool {
        let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        do {
            // Use a model known to exist on Fireworks for testing
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
            print("Fireworks AI API Key Test Failed: \(error.asFriendlyString())")
            return false
        }
    }
}
