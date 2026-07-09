import Foundation

final class GeminiProvider: OpenAIProvider {
    init(apiKey: String) {
        let baseURL = URL(string: "https://generativelanguage.googleapis.com")!
        super.init(
            apiKey: apiKey,
            baseURL: baseURL,
            configuredMaxTokens: nil,
            overrideVersion: "v1beta",
            transportOwner: .gemini
        )
    }

    /// NEW – per-model overrides
    override func providerSpecificMaxTokens(for model: AIModel) -> Int? {
        switch model {
        case .geminiPro25, .geminiFlash25, .gemini3p1ProPreview, .gemini3FlashPreview:
            65536
        default:
            // Default for "regular" Gemini models
            8192
        }
    }

    override func testAPIKey(model: AIModel = .gemini2flashlite) async throws -> Bool {
        let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        do {
            let stream = try await streamMessage(testMessage, model: model)
            var response = ""

            for try await result in stream {
                if let content = result.text {
                    response += content
                }
                if result.type == "message_stop" {
                    break
                }
            }
            return response.lowercased().contains("hello")
        } catch {
            print("Gemini API Key Test Failed: \(error)")
            return false
        }
    }
}
