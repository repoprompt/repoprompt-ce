//
//  DeepseekProvider.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-03.
//

import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import SwiftOpenAI

package final class DeepSeekProvider: OpenAIProvider {
    package init(host: any OpenAIProviderHost, apiKey: String) {
        let baseURL = URL(string: "https://api.deepseek.com")!
        super.init(
            host: host,
            apiKey: apiKey,
            baseURL: baseURL,
            configuredMaxTokens: nil,
            overrideVersion: "v1"
        )
    }

    override package func testAPIKey(model: AIModel = .deepseekChat) async throws -> Bool {
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
            print("DeepSeek API Key Test Failed: \(host.friendlyErrorDescription(error))")
            return false
        }
    }
}
