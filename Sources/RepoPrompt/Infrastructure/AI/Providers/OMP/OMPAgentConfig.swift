import Foundation

struct OMPAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let modelString: String?

    init(
        commandName: String = "omp",
        additionalPathHints: [String] = CLIPathHints.omp,
        enableDebugLogging: Bool = false,
        modelString: String? = nil
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
    }
}
