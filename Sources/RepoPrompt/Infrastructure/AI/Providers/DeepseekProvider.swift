//
//  DeepseekProvider.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-03.
//

import Foundation
import SwiftOpenAI

final class DeepSeekProvider: OpenAIProvider {
    init(apiKey: String) {
        let baseURL = URL(string: "https://api.deepseek.com")!
        super.init(
            apiKey: apiKey,
            baseURL: baseURL,
            configuredMaxTokens: nil,
            overrideVersion: "v1",
            transportOwner: .deepseek
        )
    }

    override func testAPIKey(model: AIModel = .deepseekChat) async throws -> Bool {
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
            return response.lowercased().contains("hello")
        } catch {
            print("DeepSeek API Key Test Failed: \(error.asFriendlyString())")
            return false
        }
    }
}
