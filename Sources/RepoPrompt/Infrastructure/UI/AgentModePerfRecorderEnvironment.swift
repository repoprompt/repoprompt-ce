import RepoPromptInstrumentation
import SwiftUI

extension EnvironmentValues {
    @Entry var agentModePerfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
}
