import Foundation
import RepoPromptDomainRuntime
import RepoPromptShared

enum DirectHeadlessExperimentProfile {
    enum ValidationError: Error, Equatable {
        case invalidProfile
        case explicitIsolatedWorkspaceRequired
        case profileInsideWorkspace
    }

    /// An explicit profile and a single root are required before granting fixture edits.
    /// The profile lives outside the editable root; no tool can replace its authority.
    static func isEnabled(environment: [String: String], locations: DirectHeadlessRuntimeLocations) throws -> Bool {
        guard let identifier = environment[PromptExperimentAgentProfile.environmentKey] else { return false }
        guard identifier == PromptExperimentAgentProfile.identifier else { throw ValidationError.invalidProfile }
        guard locations.usesExplicitProfileDirectory,
              locations.profileIdentifier != "default", locations.workingDirectories.count == 1
        else { throw ValidationError.explicitIsolatedWorkspaceRequired }
        let root = locations.workingDirectories[0].standardizedFileURL.resolvingSymlinksInPath().path
        let profile = locations.storageDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard profile != root, !profile.hasPrefix(root + "/") else { throw ValidationError.profileInsideWorkspace }
        return true
    }

    static var restrictedToolNames: Set<String> {
        Set(MCPDomainToolCatalog.orderedToolNames).subtracting(PromptExperimentAgentProfile.toolNames)
    }
}
