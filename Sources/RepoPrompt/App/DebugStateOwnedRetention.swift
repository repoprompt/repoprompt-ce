import Foundation
import RepoPromptDomainRuntime

extension DebugStateBootstrap.Builder {
    /// These are debug-owned control/recovery bytes, not the production baseline.
    /// Retain them verbatim without importing release grants or normalizing unknown formats.
    mutating func preserveDebugOwnedState() throws {
        let root = locations.applicationSupportRoot
        let runtime = DomainPersistenceCoordinator.runtimeDirectoryName(profileIdentifier: locations.profileIdentifier)
        for relative in [runtime + "/settings", "Settings/Backups", "Presets/Backups", "workspace-cleanup-backups"] {
            try preserveTree(root.appendingPathComponent(relative), relative: relative)
        }
        var workspaceRoots = [locations.workspaceRoot]
        if let path = previousPreferences["GlobalCustomStorageURL"] as? String {
            let custom = locations.customWorkspaceDirectory(selectedDirectory: URL(fileURLWithPath: path, isDirectory: true))
            try locations.validateCustomWorkspaceDirectory(custom)
            if !workspaceRoots.contains(custom) { workspaceRoots.append(custom) }
        }
        for workspaceRoot in workspaceRoots where FileManager.default.fileExists(atPath: workspaceRoot.path) {
            for workspace in try plan.children(workspaceRoot) where workspace.lastPathComponent.hasPrefix("Workspace-") {
                let recovery = workspace.appendingPathComponent("AgentSessions/.self-compact-recovery")
                try preserveTree(recovery, relative: "Workspaces/" + workspace.lastPathComponent + "/AgentSessions/.self-compact-recovery")
            }
        }
    }

    private mutating func preserveTree(_ directory: URL, relative: String) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try locations.validateMetadataFile(directory)
        for url in try plan.children(directory) {
            let target = relative + "/" + url.lastPathComponent
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw DebugStateSnapshot.Failure.unsafeFile }
            if values.isDirectory == true {
                try preserveTree(url, relative: target)
            } else {
                // A retained carrier may have already copied this exact recovery file.
                plan.entries.removeAll { $0.relativePath == target }
                plan.generated.removeValue(forKey: target)
                try plan.add(url, as: target)
            }
        }
    }
}
