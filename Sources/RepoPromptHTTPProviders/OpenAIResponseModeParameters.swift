import Foundation
import SwiftOpenAI

/// Adds the Responses reasoning mode until SwiftOpenAI exposes it natively.
/// Encode the SDK value first so attachments, token limits, service tier, and
/// future SDK parameters keep their existing representation.
struct OpenAIResponseModeParameters: Encodable {
    let parameters: ModelResponseParameter
    let mode: String

    private enum CodingKeys: String, CodingKey {
        case reasoning
    }

    private enum ReasoningKeys: String, CodingKey {
        case mode
    }

    func encode(to encoder: Encoder) throws {
        try parameters.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        var reasoning = container.nestedContainer(keyedBy: ReasoningKeys.self, forKey: .reasoning)
        try reasoning.encode(mode, forKey: .mode)
    }
}
