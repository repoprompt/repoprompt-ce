//
//  OllamaProvider.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-12-16.
//

import Foundation

final class OllamaProvider: OpenAIProvider {
    init(baseURL: URL) {
        // Ollama runs locally. No API key is required, just the base URL.
        super.init(baseURL: baseURL, transportOwner: .ollama)
    }
}
