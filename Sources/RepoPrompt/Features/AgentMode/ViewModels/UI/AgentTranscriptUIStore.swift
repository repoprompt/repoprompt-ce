import Foundation
import RepoPromptInstrumentation
import SwiftUI

struct AgentTranscriptUISnapshot: Equatable {
    var currentTabID: UUID?
    var presentation: AgentTranscriptPresentationSnapshot {
        didSet { renderEntries = nil }
    }

    var renderEntries: AgentTranscriptRenderEntries?
    var isHydrated: Bool
    var presentationRevision: Int
    var displayMaskRevision: UInt64 = 0
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
            && lhs.displayMaskRevision == rhs.displayMaskRevision
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

struct AgentTranscriptDisclosureScope {
    let store: AgentTranscriptUIStore
    let workspaceID: UUID?
    let tabID: UUID?
    let itemID: UUID

    @MainActor
    func binding(for control: String, fallback: Binding<Bool>) -> Binding<Bool> {
        let key = AgentTranscriptUIStore.DisclosureKey(workspaceID: workspaceID, tabID: tabID, itemID: itemID, control: control)
        return Binding(
            get: { store.disclosureChoice(for: key) ?? fallback.wrappedValue },
            set: {
                store.setDisclosureChoice($0, for: key)
                fallback.wrappedValue = $0
            }
        )
    }

    @MainActor
    func hasChoice(for control: String) -> Bool {
        store.disclosureChoice(for: .init(workspaceID: workspaceID, tabID: tabID, itemID: itemID, control: control)) != nil
    }
}

extension EnvironmentValues {
    @Entry var agentTranscriptDisclosureScope: AgentTranscriptDisclosureScope? = nil
}

/// The mounted row invalidates locally; only explicit interaction creates a retained choice.
@MainActor
@propertyWrapper
struct AgentTranscriptDisclosure: DynamicProperty {
    @Environment(\.agentTranscriptDisclosureScope) private var scope
    @State private var initialValue: Bool
    @State private var localChange: Bool?
    private let control: String

    init(wrappedValue: Bool, _ control: String) {
        _initialValue = State(initialValue: wrappedValue)
        self.control = control
    }

    var hasChoice: Bool {
        scope?.hasChoice(for: control) ?? false
    }

    var wrappedValue: Bool {
        get { projectedValue.wrappedValue }
        nonmutating set {
            // Preserve existing live auto-expansion rules without retaining untouched rows.
            if hasChoice {
                projectedValue.wrappedValue = newValue
            } else {
                localChange = newValue
            }
        }
    }

    var projectedValue: Binding<Bool> {
        let fallback = Binding(get: { localChange ?? initialValue }, set: { localChange = $0 })
        return scope?.binding(for: control, fallback: fallback) ?? fallback
    }
}

@MainActor
final class AgentTranscriptUIStore: ObservableObject {
    var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    @Published private(set) var snapshot: AgentTranscriptUISnapshot = .empty

    struct DisclosureKey: Hashable {
        let workspaceID: UUID?
        let tabID: UUID?
        let itemID: UUID
        let control: String
    }

    /// Only user-operated disclosures are recorded; reading a row does not populate this map.
    private var disclosureChoices: [DisclosureKey: Bool] = [:]

    func disclosureChoice(for key: DisclosureKey) -> Bool? {
        disclosureChoices[key]
    }

    func setDisclosureChoice(_ value: Bool, for key: DisclosureKey) {
        disclosureChoices[key] = value
    }

    func update(_ snapshot: AgentTranscriptUISnapshot) {
        guard self.snapshot != snapshot else {
            #if DEBUG
                perfRecorder.recordStoreUpdate("transcript", published: false)
            #endif
            return
        }
        var snapshot = snapshot
        if snapshot.renderEntries == nil {
            snapshot.renderEntries = .init(blocks: snapshot.presentation.visibleBlocks)
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
