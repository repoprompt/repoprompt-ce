import Combine
import Foundation

@MainActor
final class AgentRepromptUIStore: ObservableObject {
    enum Phase: Equatable {
        case generating, clarifying, refining, completed, failed
        var isStreaming: Bool {
            self == .generating || self == .refining
        }

        var isBusy: Bool {
            self == .generating || self == .clarifying || self == .refining
        }
    }

    struct Presentation: Identifiable, Equatable {
        let id: UUID
        let sourceTabID: UUID
        let original: String
        var modelName: String
        var phase: Phase = .generating
        var startedAt = Date()
        var usesChatContext = false
        var startsWithProviderCommand = false
        var error: String?
    }

    struct PublicationIdentity: Equatable {
        let operationID: UUID
        let revision: UInt64
    }

    struct DraftUpdate: Equatable {
        let operationID: UUID
        let tabID: UUID
        let revision: UInt64
        let text: String
        var identity: PublicationIdentity {
            .init(operationID: operationID, revision: revision)
        }
    }

    /// Pending publications own the canonical draft; acknowledged publications no longer suppress final user-edit flushing.
    static func shouldFlushDraftOnDeparture(tabID: UUID, presentation: Presentation?, publication: DraftUpdate?, acknowledged: PublicationIdentity?) -> Bool {
        if presentation?.sourceTabID == tabID, presentation?.phase.isBusy == true { return false }
        return publication?.tabID != tabID || publication?.identity == acknowledged
    }

    func allowsAttachmentMutation(tabID: UUID, currentTabID: UUID?) -> Bool {
        currentTabID == tabID && (presentation?.sourceTabID != tabID || presentation?.phase.isBusy != true)
    }

    struct AutoSendRequest: Equatable {
        let operationID: UUID
        let tabID: UUID
        let text: String
        let generation: UInt64
    }

    struct OneShotDisclosureRequest: Identifiable {
        let id = UUID()
        let target: AgentComposerSubmitTarget
        let text: String
        let generation: UInt64
    }

    struct Recovery: Equatable {
        let id = UUID()
        let text: String
        let originalDraft: String
        let reason: String
        var draftAtInvalidation = ""
        var requiresDecision = false
        var bypassesPreparation = false
    }

    @Published var autoSendRequest: AutoSendRequest?
    @Published var oneShotDisclosureRequest: OneShotDisclosureRequest?
    @Published var presentation: Presentation?
    @Published var draftUpdate: DraftUpdate?
    @Published var pendingQuestions: AgentAskUserPendingState?
    @Published var recoveries: [UUID: Recovery] = [:]

    func recover(tabID: UUID, text: String, originalDraft: String, reason: String, currentDraft: String, requiresDecision: Bool = false) {
        guard !text.isEmpty, text != originalDraft else { return }
        recoveries[tabID] = .init(text: text, originalDraft: originalDraft, reason: reason, draftAtInvalidation: currentDraft, requiresDecision: requiresDecision)
    }
}
