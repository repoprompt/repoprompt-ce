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
            // Debug-owned enumeration is verbatim: a workspace name may itself look temporary.
            for workspace in try plan.children(workspaceRoot, selection: .verbatim) where workspace.lastPathComponent.hasPrefix("Workspace-") {
                let recovery = workspace.appendingPathComponent("AgentSessions/.self-compact-recovery")
                try preserveTree(recovery, relative: "Workspaces/" + workspace.lastPathComponent + "/AgentSessions/.self-compact-recovery")
            }
        }
    }

    /// Capture both stores through the existing snapshot verifier. Recovery is allowed
    /// only on these disposable copies; no release-side lock or live-store mutation.
    mutating func preserveDebugOracleState(workspaceIDs: Set<String>) throws {
        let retained = Set(workspaceIDs.compactMap(UUID.init(uuidString:)))
        guard !retained.isEmpty else { return }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("rpce-oracle-retention-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let releaseRelative = DomainPersistenceCoordinator.runtimeDirectoryName(profileIdentifier: source.profileIdentifier) + "/oracle"
        let debugRelative = DomainPersistenceCoordinator.runtimeDirectoryName(profileIdentifier: locations.profileIdentifier) + "/oracle"
        let releaseCopy = staging.appendingPathComponent("release")
        let debugCopy = staging.appendingPathComponent("debug")
        let merged = staging.appendingPathComponent("merged")
        try captureOracleTree(source.applicationSupportRoot.appendingPathComponent(releaseRelative), to: releaseCopy)
        try captureOracleTree(locations.applicationSupportRoot.appendingPathComponent(debugRelative), to: debugCopy)
        try plan.verify()
        let cancellation = plan.cancellation
        do {
            try OracleDebugRetention.combine(releaseRoot: releaseCopy, debugRoot: debugCopy, destination: merged, retainedWorkspaceIDs: retained) {
                try cancellation?.check()
            }
        } catch let failure as DebugStateSnapshot.Failure {
            throw failure
        } catch {
            throw DebugStateSnapshot.Failure.oracleRetention(error.localizedDescription)
        }
        plan.entries.removeAll { $0.relativePath.hasPrefix(debugRelative + "/") }
        for key in Array(plan.generated.keys) where key.hasPrefix(debugRelative + "/") {
            plan.generated.removeValue(forKey: key)
        }
        func collect(_ directory: URL, relative: String) throws -> [String: Data] {
            var result: [String: Data] = [:]
            for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
                try plan.cancellation?.check()
                let path = relative + "/" + url.lastPathComponent
                if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    try result.merge(collect(url, relative: path)) { _, new in new }
                } else {
                    result[path] = try Data(contentsOf: url)
                }
            }
            return result
        }
        let generated = try collect(merged, relative: debugRelative)
        plan.generated.merge(generated) { _, new in new }
    }

    private mutating func captureOracleTree(_ directory: URL, to destination: URL) throws {
        let fm = FileManager.default
        // Observe the nearest existing ancestor even when the optional store is absent.
        // Appearance of a runtime/store directory must invalidate this capture.
        if !fm.fileExists(atPath: directory.path) {
            var missing = directory
            while !fm.fileExists(atPath: missing.deletingLastPathComponent().path) {
                missing.deleteLastPathComponent()
            }
            let parent = missing.deletingLastPathComponent()
            let children = try plan.children(parent)
            // The ancestor may have appeared between probing and recording membership.
            // Never bless a listing that already contains the supposedly absent child.
            guard !children.contains(where: { $0.lastPathComponent == missing.lastPathComponent }) else {
                throw DebugStateSnapshot.Failure.sourceChanged
            }
            return
        }
        for url in try plan.children(directory, selection: .init(excluding: ["locks", "claims"])) {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            switch try DebugStateSnapshot.kind(url) {
            case .directory:
                try captureOracleTree(url, to: target)
            case .file:
                let bytes = try plan.read(url)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target)
            }
        }
    }

    private mutating func preserveTree(_ directory: URL, relative: String) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try locations.validateMetadataFile(directory)
        // Verbatim: debug-owned recovery bytes keep every name, temporaries included.
        for url in try plan.children(directory, selection: .verbatim) {
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
