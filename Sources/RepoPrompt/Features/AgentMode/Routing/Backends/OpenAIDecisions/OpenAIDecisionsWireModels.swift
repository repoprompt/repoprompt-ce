import Foundation

/// Backend-private projection of the public Decisions choice contract.
struct OpenAIDecisionsWireRequest: Encodable, Equatable {
    struct Question: Encodable, Equatable {
        struct Choice: Encodable, Equatable {
            let value: String
            let description: String?
        }

        let type: String = "choice"
        let name: String
        let instructions: String
        let choices: [Choice]
    }

    let model: String
    let input: String
    let questions: [Question]
}

struct OpenAIDecisionsWireResponse: Decodable, Equatable {
    struct Probability: Codable, Equatable {
        let value: String
        let probability: Double
    }

    enum Answer: Decodable, Equatable {
        case choice(name: String?, choice: String, probabilities: [Probability], confidence: Double)
        case refusal(name: String?)

        private enum CodingKeys: String, CodingKey { case type, name, choice, probabilities, confidence }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "choice":
                self = try .choice(
                    name: container.decodeIfPresent(String.self, forKey: .name),
                    choice: container.decode(String.self, forKey: .choice),
                    probabilities: container.decode([Probability].self, forKey: .probabilities),
                    confidence: container.decode(Double.self, forKey: .confidence)
                )
            case "refusal":
                self = try .refusal(name: container.decodeIfPresent(String.self, forKey: .name))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported Decisions answer type")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .choice(name, choice, probabilities, confidence):
                try container.encode("choice", forKey: .type)
                try container.encodeIfPresent(name, forKey: .name)
                try container.encode(choice, forKey: .choice)
                try container.encode(probabilities, forKey: .probabilities)
                try container.encode(confidence, forKey: .confidence)
            case let .refusal(name):
                try container.encode("refusal", forKey: .type)
                try container.encodeIfPresent(name, forKey: .name)
            }
        }
    }

    struct Usage: Decodable, Equatable {
        struct InputDetails: Decodable, Equatable {
            let cachedTokens: Int
            let cacheWriteTokens: Int
            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
                case cacheWriteTokens = "cache_write_tokens"
            }
        }

        struct OutputDetails: Decodable, Equatable {
            let reasoningTokens: Int
            enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
        }

        let inputTokens: Int
        let inputTokensDetails: InputDetails
        let outputTokens: Int
        let outputTokensDetails: OutputDetails
        let totalTokens: Int
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case inputTokensDetails = "input_tokens_details"
            case outputTokens = "output_tokens"
            case outputTokensDetails = "output_tokens_details"
            case totalTokens = "total_tokens"
        }
    }

    let model: String
    let answers: [Answer]
    let usage: Usage
}

/// Only the structured error code is retained; message text is deliberately discarded.
struct OpenAIDecisionsWireError: Decodable, Equatable {
    struct Detail: Decodable, Equatable {
        let type: String?
        let code: String?
    }

    let error: Detail
}
