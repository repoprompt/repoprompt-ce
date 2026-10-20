import Combine
import Foundation

@MainActor
final class AgentRepromptUIStore: ObservableObject {
    enum Phase: Equatable { case generating, clarifying, gatheringContext, refining, reviewing, failed }
    struct Presentation: Identifiable, Equatable {
        let id: UUID
        let sourceTabID: UUID
        let original: String
        var modelName: String
        var phase: Phase = .generating
        var questions: [AgentRepromptResult.Question] = []
        var consults: [AgentRepromptConsultResult] = []
        var isGatheringContext = false
        var consultKinds: [AgentRepromptContextRequest.Kind] = []
        var contextStartedAt = Date()
        var error: String?
        var hasUnresolvedQuestions = false
    }

    struct Recovery: Equatable {
        let text: String
        let originalDraft: String
        let reason: String
        var draftAtInvalidation: String = ""
    }

    @Published var presentation: Presentation?
    @Published var pendingQuestions: AgentAskUserPendingState?
    @Published var reviewText = ""
    @Published var recoveries: [UUID: Recovery] = [:]

    var canApprove: Bool {
        presentation?.phase == .reviewing
            && !reviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && reviewText.utf8.count <= 64 * 1024
    }

    func recover(tabID: UUID, originalDraft: String, reason: String, currentDraft: String? = nil) {
        guard presentation?.phase == .reviewing, !reviewText.isEmpty else { return }
        recoveries[tabID] = .init(text: reviewText, originalDraft: originalDraft, reason: reason, draftAtInvalidation: currentDraft ?? originalDraft)
    }
}
