import Combine
import Foundation
import RepoPromptInstrumentation

@MainActor
final class AgentComposerUIStore: ObservableObject {
    var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    @Published private(set) var props: AgentComposerProps
    @Published private(set) var revision: UInt64 = 0
    /// Presentation only: admission continues to belong to activeComposerSubmitAttempt.
    @Published var pendingSubmissions: [UUID: AgentComposerPendingSubmission] = [:]

    init(props: AgentComposerProps = .empty) {
        self.props = props
    }

    func hasPendingSubmission(tabID: UUID?) -> Bool {
        guard let tabID else { return false }
        return pendingSubmissions.values.contains { $0.sourceTabID == tabID || $0.destinationTabID == tabID }
    }

    func update(_ nextProps: AgentComposerProps) {
        guard props != nextProps else {
            #if DEBUG
                perfRecorder.recordStoreUpdate("composer", published: false)
            #endif
            return
        }
        props = nextProps
        revision &+= 1
        #if DEBUG
            perfRecorder.recordStoreUpdate("composer", published: true, details: ["revision": String(revision)])
        #endif
    }
}
