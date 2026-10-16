import Foundation

package enum ShellEnvironmentSource: Equatable {
    case inheritedRichEnvironment
    case capturedLoginShell
    case previousCapturedFallback
    case enrichedFallback
}
