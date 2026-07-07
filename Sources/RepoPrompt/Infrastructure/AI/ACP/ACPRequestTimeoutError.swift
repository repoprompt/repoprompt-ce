import Foundation

struct ACPRequestTimeoutError: Error, Equatable, LocalizedError {
    let method: String
    let timeoutSeconds: TimeInterval
    let launchDescription: String?
    let diagnosticHint: String?
    let agentIdentity: String?

    var errorDescription: String? {
        var message = "ACP request \(method) timed out after \(Self.formattedTimeout(timeoutSeconds))."
        if let launchDescription, !launchDescription.isEmpty {
            message += " Launched: `\(launchDescription)`."
        }
        if let agentIdentity, !agentIdentity.isEmpty {
            message += " Agent: `\(agentIdentity)`."
        }
        if let diagnosticHint, !diagnosticHint.isEmpty {
            message += " \(diagnosticHint)"
        }
        return message
    }

    private static func formattedTimeout(_ seconds: TimeInterval) -> String {
        if seconds.rounded(.towardZero) == seconds {
            return "\(Int(seconds))s"
        }
        return String(format: "%.1fs", seconds)
    }
}
