import Foundation

/// Capability for the canonical owner of one launch configuration.
package protocol LaunchConfigLease: Sendable {
    var url: URL { get }
    func release()
}

/// Provider-neutral launch lifetime and data, with a provider-owned typed payload.
package struct HeadlessLaunchContext<LaunchEnvironment> {
    package let runID: UUID
    package let configURL: URL?
    package let configLease: (any LaunchConfigLease)?
    /// Working directory for the agent. Defaults to temp directory to avoid macOS security popups.
    package let workingDirectory: String
    package let environment: [String: String]
    package let launchEnvironment: LaunchEnvironment?

    package init(
        runID: UUID,
        configURL: URL? = nil,
        configLease: (any LaunchConfigLease)? = nil,
        workingDirectory: String? = nil,
        environment: [String: String],
        launchEnvironment: LaunchEnvironment? = nil
    ) {
        self.runID = runID
        self.configLease = configLease
        self.configURL = configLease?.url ?? configURL
        self.workingDirectory = workingDirectory ?? FileManager.default.temporaryDirectory.path
        self.environment = environment
        self.launchEnvironment = launchEnvironment
    }
}
