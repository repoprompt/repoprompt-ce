import Combine
import Foundation

/// Preparation state is keyed by composer tab: a rewrite keeps running when its session is not
/// visible, and another session can prepare its own at the same time.
@MainActor
final class AgentRepromptUIStore: ObservableObject {
    /// Preparation, not a keystroke deadline, distinguishes the first Return from the next.
    /// This only chooses the UI action; operation validation and fresh claim admission still apply.
    func hasPreparedDraft(tabID: UUID, text: String) -> Bool {
        presentations[tabID] != nil || recoveries[tabID]?.draftAtInvalidation.utf8.elementsEqual(text.utf8) == true
            || hasCancelledDraft(tabID: tabID, text: text)
    }

    struct CancelledDraft: Equatable {
        let id = UUID()
        let text: String
    }

    private(set) var cancelledDrafts: [UUID: CancelledDraft] = [:]

    func rememberCancelledDraft(tabID: UUID, text: String) {
        cancelledDrafts[tabID] = .init(text: text)
    }

    func hasCancelledDraft(tabID: UUID, text: String) -> Bool {
        cancelledDrafts[tabID]?.text.utf8.elementsEqual(text.utf8) == true
    }

    func clearCancelledDraft(tabID: UUID) {
        cancelledDrafts[tabID] = nil
    }

    func restoreCancelledDraft(_ draft: CancelledDraft?, tabID: UUID, currentDraft: String) {
        guard cancelledDrafts[tabID] == nil, let draft, draft.text.utf8.elementsEqual(currentDraft.utf8) else { return }
        cancelledDrafts[tabID] = draft
    }

    struct SubmittedDraft: Equatable {
        let tabID: UUID
        let recovery: Recovery?
        let publication: DraftUpdate?
        let autoSend: AutoSendRequest?
        let cancelledDraft: CancelledDraft?
    }

    func submittedDraftSnapshot(tabID: UUID) -> SubmittedDraft {
        .init(
            tabID: tabID,
            recovery: recoveries[tabID],
            publication: draftUpdate?.tabID == tabID ? draftUpdate : nil,
            autoSend: autoSendRequests[tabID],
            cancelledDraft: cancelledDrafts[tabID]
        )
    }

    /// Completion can arrive after a tab switch or a newer preparation. Only retire captured state.
    func clearSubmittedDraft(_ snapshot: SubmittedDraft) {
        if recoveries[snapshot.tabID] == snapshot.recovery { recoveries[snapshot.tabID] = nil }
        if draftUpdate == snapshot.publication { draftUpdate = nil }
        if autoSendRequests[snapshot.tabID] == snapshot.autoSend {
            autoSendRequests[snapshot.tabID] = nil
        }
        if cancelledDrafts[snapshot.tabID] == snapshot.cancelledDraft { cancelledDrafts[snapshot.tabID] = nil }
    }

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
        currentTabID == tabID && presentations[tabID]?.phase.isBusy != true
    }

    struct AutoSendRequest: Equatable {
        let operationID: UUID
        let tabID: UUID
        let text: String
        let generation: UInt64
    }

    /// Set only when the composer shows the text to send and can dispatch it. Consuming a request
    /// is one-shot, so it must wait for a live submit target rather than be spent on a stale one.
    func autoSendReadyID(tabID: UUID?, visibleDraft: String, canSubmit: Bool) -> UUID? {
        guard canSubmit, let tabID, let request = autoSendRequests[tabID], request.text == visibleDraft else { return nil }
        return request.operationID
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

    /// One-shot request for a specific tab's composer to retake native focus after Re-prompt
    /// chrome (for example the disclosure popover) closes. The composer applies it only when
    /// its tab matches and focus is not owned by another live field or window.
    struct ComposerFocusRequest: Equatable {
        let id = UUID()
        let tabID: UUID
    }

    @Published var composerFocusRestoreRequest: ComposerFocusRequest?

    func requestComposerFocus(tabID: UUID?) {
        guard let tabID else { return }
        composerFocusRestoreRequest = .init(tabID: tabID)
    }

    @Published var autoSendRequests: [UUID: AutoSendRequest] = [:]
    @Published var oneShotDisclosureRequest: OneShotDisclosureRequest?
    @Published var presentations: [UUID: Presentation] = [:]
    @Published var draftUpdate: DraftUpdate?
    @Published var pendingQuestionsByTab: [UUID: AgentAskUserPendingState] = [:]
    @Published var recoveries: [UUID: Recovery] = [:]

    func recover(tabID: UUID, text: String, originalDraft: String, reason: String, currentDraft: String, requiresDecision: Bool = false) {
        guard !text.isEmpty, text != originalDraft else { return }
        recoveries[tabID] = .init(text: text, originalDraft: originalDraft, reason: reason, draftAtInvalidation: currentDraft, requiresDecision: requiresDecision)
    }
}
