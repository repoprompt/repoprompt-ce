import Foundation

struct AgentTaskRoutingEnvelopeBuilder {
    enum Rejection: Error, Equatable {
        case empty
        case tooManyCharacters
        case tooManyBytes
        case unsupportedContent
        case invalidCandidateCount
    }

    static let maximumCharacters = 4000
    static let maximumUTF8Bytes = 16 * 1024
    static let maximumCandidates = 12

    func build(
        requestID: UUID,
        text: String,
        scope: AgentTaskRoutingScope = .primarySession,
        decisionStage: AgentTaskRoutingDecisionStage = .model,
        customInstructions: String? = nil,
        candidates: [AgentTaskRoutingCandidateDescriptor],
        containsAttachments: Bool = false,
        containsTaggedPaths: Bool = false,
        invokesWorkflowOrSlashCommand: Bool = false
    ) throws -> AgentTaskRoutingRequest {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw Rejection.empty }
        guard task.count <= Self.maximumCharacters else { throw Rejection.tooManyCharacters }
        guard task.utf8.count <= Self.maximumUTF8Bytes else { throw Rejection.tooManyBytes }
        guard !containsAttachments, !containsTaggedPaths, !invokesWorkflowOrSlashCommand else {
            throw Rejection.unsupportedContent
        }
        guard (2 ... Self.maximumCandidates).contains(candidates.count) else { throw Rejection.invalidCandidateCount }
        return AgentTaskRoutingRequest(
            requestID: requestID,
            contractVersion: AgentTaskRoutingRequest.currentContractVersion,
            task: task,
            scope: scope,
            decisionStage: decisionStage,
            customInstructions: customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            candidates: candidates
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
