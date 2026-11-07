import Foundation
import RepoPromptFoundation

package struct ACPLaunchEnvironment: Equatable {
    package let environment: [String: String]
    package let shellEnvironmentSource: ShellEnvironmentSource?

    package init(environment: [String: String], shellEnvironmentSource: ShellEnvironmentSource? = nil) {
        self.environment = environment
        self.shellEnvironmentSource = shellEnvironmentSource
    }
}

package enum AgentCLILaunchDiagnostics {
    package static func fallbackEnvironmentHint(for source: ShellEnvironmentSource?) -> String? {
        switch source {
        case .enrichedFallback:
            "Environment was built from RepoPrompt's fallback PATH because login-shell capture failed or timed out; PATH may not match Terminal."
        case .previousCapturedFallback:
            "Environment reused the last captured shell PATH because login-shell capture failed or timed out; PATH may be stale."
        case .capturedLoginShell, .inheritedRichEnvironment, .none:
            nil
        }
    }

    package static func appendFallbackEnvironmentHint(to message: String, source: ShellEnvironmentSource?) -> String {
        guard let hint = fallbackEnvironmentHint(for: source) else { return message }
        return "\(message) \(hint)"
    }
}
