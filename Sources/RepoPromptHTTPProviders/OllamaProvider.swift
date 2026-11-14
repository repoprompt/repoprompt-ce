//
//  OllamaProvider.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-12-16.
//

import Foundation

package final class OllamaProvider: OpenAIProvider {
    package init(host: any OpenAIProviderHost, baseURL: URL) {
        // Ollama runs locally. No API key is required, just the base URL.
        super.init(host: host, baseURL: baseURL)
    }
}
