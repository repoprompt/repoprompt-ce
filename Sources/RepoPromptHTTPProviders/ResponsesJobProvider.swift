import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import SwiftOpenAI

package protocol ResponsesJobProvider {
    func createBackgroundResponse(
        _ message: RepoPromptDomainRuntime.AIMessage,
        model: AIModel,
        maxTokens: Int?
    ) async throws -> ResponseModel

    func fetchResponse(id: String) async throws -> ResponseModel
    func streamResponse(id: String) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>
    func cancelResponse(id: String) async throws -> ResponseModel
}
