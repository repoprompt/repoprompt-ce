import Foundation
import RepoPromptInstrumentation

struct AgentTranscriptUISnapshot: Equatable {
    var currentTabID: UUID?
    var presentation: AgentTranscriptPresentationSnapshot
    var isHydrated: Bool
    var presentationRevision: Int
    var followBindingState: AgentModeViewModel.ActiveTranscriptFollowBindingState
    var activeSessionLoadInProgressTabID: UUID?
    var activeBashLiveExecutionByItemID: [UUID: AgentModeViewModel.BashLiveExecutionState]
    var runtimeFooterByItemID: [UUID: AgentMessageRuntimeFooter]
    var fallbackFollowArmingState: AgentModeViewModel.AgentTranscriptAutoFollowArmingState
    var archivedBlocks: [AgentTranscriptRenderBlock]
    var panePresentation: AgentTranscriptPanePresentation
    var paneTarget: AgentTranscriptPaneTarget

    static let empty = AgentTranscriptUISnapshot(
        currentTabID: nil,
        presentation: .empty,
        isHydrated: false,
        presentationRevision: 0,
        followBindingState: .init(),
        activeSessionLoadInProgressTabID: nil,
        activeBashLiveExecutionByItemID: [:],
        runtimeFooterByItemID: [:],
        fallbackFollowArmingState: .armed,
        archivedBlocks: [],
        panePresentation: .restoring,
        paneTarget: .unresolved
    )

    /// Custom equality uses `presentationRevision` as a cheap fingerprint for
    /// the full `AgentTranscriptPresentationSnapshot`. The revision is bumped
    /// by `AgentModeViewModel` whenever the presentation content changes, so
    /// matching revisions (and matching tab scope) imply identical rows /
    /// blocks / anchors without walking the large arrays. Other fields remain
    /// compared directly because they can change independently of the
    /// transcript presentation (follow state, live bash, runtime footers,
    /// archived blocks, etc.).
    static func == (lhs: AgentTranscriptUISnapshot, rhs: AgentTranscriptUISnapshot) -> Bool {
        lhs.currentTabID == rhs.currentTabID
            && lhs.presentationRevision == rhs.presentationRevision
            && lhs.presentation.tabID == rhs.presentation.tabID
            && lhs.isHydrated == rhs.isHydrated
            && lhs.followBindingState == rhs.followBindingState
            && lhs.activeSessionLoadInProgressTabID == rhs.activeSessionLoadInProgressTabID
            && lhs.fallbackFollowArmingState == rhs.fallbackFollowArmingState
            && lhs.activeBashLiveExecutionByItemID == rhs.activeBashLiveExecutionByItemID
            && lhs.runtimeFooterByItemID == rhs.runtimeFooterByItemID
            && lhs.archivedBlocks == rhs.archivedBlocks
            && lhs.panePresentation == rhs.panePresentation
            && lhs.paneTarget == rhs.paneTarget
    }
}

@MainActor
final class AgentTranscriptUIStore: ObservableObject {
    var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    @Published private(set) var snapshot: AgentTranscriptUISnapshot = .empty

    func update(_ snapshot: AgentTranscriptUISnapshot) {
        guard self.snapshot != snapshot else {
            #if DEBUG
                perfRecorder.recordStoreUpdate("transcript", published: false)
            #endif
            return
        }
        #if DEBUG
            perfRecorder.recordStoreUpdate(
                "transcript",
                published: true,
                details: [
                    "tabID": perfRecorder.shortID(snapshot.currentTabID),
                    "presentationRevision": String(snapshot.presentationRevision),
                    "visibleRows": String(snapshot.presentation.visibleRows.count),
                    "workingRows": String(snapshot.presentation.workingRows.count),
                    "runtimeFooters": String(snapshot.runtimeFooterByItemID.count),
                    "liveBash": String(snapshot.activeBashLiveExecutionByItemID.count),
                    "archivedBlocks": String(snapshot.archivedBlocks.count)
                ]
            )
        #endif
        self.snapshot = snapshot
    }
}
