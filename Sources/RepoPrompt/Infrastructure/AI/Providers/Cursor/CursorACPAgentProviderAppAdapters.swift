import Foundation
import RepoPromptACPProviders
import RepoPromptDomainRuntime

extension CursorACPAgentProvider {
    init(
        config: CursorAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: CursorACPLaunchResolver = CursorACPLaunchResolver()
    ) {
        self.init(
            config: config,
            repoPromptMCPConfiguration: repoPromptMCPConfiguration,
            launchResolver: launchResolver,
            toolNames: ACPAppToolNameResolution.current,
            projectMCPApproval: CursorAppProjectMCPApproval()
        )
    }
}

private struct CursorAppProjectMCPApproval: CursorACPProjectMCPApproval {
    var cleanupArtifactKind: String {
        CursorIntegrationConfiguration.cleanupArtifactKind
    }

    func cursorDataDirectoryURL(workingDirectory: String, environment: [String: String]) -> URL {
        CursorIntegrationConfiguration.cursorDataDirectoryURL(workingDirectory: workingDirectory, environment: environment)
    }

    func prepareProjectMCPApproval(
        workingDirectory: String,
        cursorDataDirectory: URL,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration,
        cleanupAfterRun: Bool
    ) throws -> ACPLaunchCleanupArtifact? {
        try CursorIntegrationConfiguration.prepareProjectMCPApproval(
            workingDirectory: workingDirectory,
            cursorDataDirectory: cursorDataDirectory,
            repoPromptMCPConfiguration: repoPromptMCPConfiguration,
            cleanupAfterRun: cleanupAfterRun
        )
    }

    func cleanupProjectMCPApproval(leaseID: UUID) {
        CursorIntegrationConfiguration.cleanupProjectMCPApproval(leaseID: leaseID)
    }
}
