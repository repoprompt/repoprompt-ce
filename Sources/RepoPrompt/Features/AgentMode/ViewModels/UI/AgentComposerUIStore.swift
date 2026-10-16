import Combine
import Foundation
import RepoPromptInstrumentation

@MainActor
final class AgentComposerUIStore: ObservableObject {
    var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    @Published private(set) var props: AgentComposerProps
    @Published private(set) var revision: UInt64 = 0

    init(props: AgentComposerProps = .empty) {
        self.props = props
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
