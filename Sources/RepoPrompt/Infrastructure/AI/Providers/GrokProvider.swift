//
//  GrokProvider.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-10.
//

import Foundation
import SwiftOpenAI

final class GrokProvider: OpenAIProvider {
    init(apiKey: String) {
        let baseURL = URL(string: "https://api.x.ai")! // Per user instruction
        super.init(
            apiKey: apiKey,
            baseURL: baseURL,
            configuredMaxTokens: nil, // Grok models might have their own defaults, or can be set per model
            overrideVersion: "v1", // Assuming /v1 for OpenAI compatibility
            transportOwner: .grok
        )
    }

    // Grok-specific max tokens if needed, otherwise OpenAIProvider defaults or model-specific defaults will apply
    // override func providerSpecificMaxTokens(for model: AIModel) -> Int? {
    //     switch model {
    //     case .grok3MiniBeta:
    //         return 8_192 // Example, check actual Grok limits
    //     case .grok3Beta:
    //         return 8_192 // Example
    //     default:
    //         return nil
    //     }
    // }

    override func testAPIKey(model: AIModel = .grokCodeFast1) async throws -> Bool {
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
            print("Grok AI API Key Test Failed: \(error.asFriendlyString())")
            return false
        }
    }
}
