import Foundation

struct OMPAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool

    init(
        commandName: String = "omp",
        additionalPathHints: [String] = CLIPathHints.omp,
        enableDebugLogging: Bool = false
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
    }
}
