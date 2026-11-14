import Foundation
import RepoPromptAIContracts
import SwiftOpenAI

struct BackgroundResponseJob: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case queued
        case inProgress
        case completed
        case failed
        case cancelled
        case unknown
    }

    let id: String
    let provider: AIProviderType
    let model: AIModel
    let createdAt: Date

    var status: Status
    var lastError: String?
    var lastUsage: ChatTokenInfo?

    init(
        id: String,
        provider: AIProviderType,
        model: AIModel,
        createdAt: Date,
        status: Status,
        lastError: String? = nil,
        lastUsage: ChatTokenInfo? = nil
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.createdAt = createdAt
        self.status = status
        self.lastError = lastError
        self.lastUsage = lastUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(AIProviderType.self, forKey: .provider)
        let modelRawValue = try container.decode(String.self, forKey: .model)
        guard let decodedModel = AIModel.fromModelName(modelRawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .model,
                in: container,
                debugDescription: "Unknown model raw value: \(modelRawValue)"
            )
        }
        model = decodedModel
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = try container.decode(Status.self, forKey: .status)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastUsage = try container.decodeIfPresent(ChatTokenInfo.self, forKey: .lastUsage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(model.rawValue, forKey: .model)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(lastUsage, forKey: .lastUsage)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case model
        case createdAt
        case status
        case lastError
        case lastUsage
    }
}

extension BackgroundResponseJob.Status {
    static func from(_ status: ResponseModel.Status?) -> BackgroundResponseJob.Status {
        switch status {
        case .some(.queued):
            .queued
        case .some(.inProgress):
            .inProgress
        case .some(.completed):
            .completed
        case .some(.failed):
            .failed
        case .some(.cancelled):
            .cancelled
        case .some(.incomplete):
            .failed
        case .none:
            .unknown
        }
    }
}

extension BackgroundResponseJob {
    static func errorMessage(from response: ResponseModel) -> String? {
        response.error?.message ?? response.incompleteDetails?.reason
    }

    static func usage(from response: ResponseModel) -> ChatTokenInfo? {
        guard let usage = response.usage else { return nil }
        return ChatTokenInfo(
            promptTokens: usage.inputTokens,
            completionTokens: usage.outputTokens,
            cost: nil
        )
    }
}
