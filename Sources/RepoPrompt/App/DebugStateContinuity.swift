import Foundation
import RepoPromptDomainRuntime
import RepoPromptPersistence
import RepoPromptShared

extension DebugStateBootstrap.Builder {
    /// Keep same-profile approvals and their intact carriers together. Retention never
    /// activates authority; the live owners still revalidate every restored record.
    mutating func preserveDebugContinuity() throws {
        let fm = FileManager.default
        let root = locations.applicationSupportRoot
        var identities = DebugStateSnapshot.ContinuityIdentities()
        let database = root.appendingPathComponent("Overseer/continuity.sqlite")
        if fm.fileExists(atPath: database.path) {
            try plan.add(database, as: "Overseer/continuity.sqlite", database: true)
            identities = try DebugStateSnapshot.continuityIdentities(database)
        }
        let legacyFiles: [(String, OverseerContinuityKind)] = [
            (AgentSessionOversightIntentStore.filename, .link),
            (DelegationScopeStore.filename, .scope),
            (WorktreeOwnershipStore.filename, .worktree)
        ]
        for (name, kind) in legacyFiles {
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                let legacy = try OverseerContinuityRepository.legacyBackingIdentities(plan.read(url), kind: kind)
                identities.sessions.formUnion(legacy.sessions)
                identities.workspaces.formUnion(legacy.workspaces)
                try plan.add(url, as: name)
            }
        }
        guard !identities.sessions.isEmpty || !identities.workspaces.isEmpty else { return }
        var retained = Self(
            locations: locations, releasePreferences: previousPreferences,
            sourceOverride: locations, retainedIdentities: identities
        )
        try retained.addWorkspaces()
        guard let retainedIndexData = retained.plan.generated["Workspaces/workspacesIndex.json"],
              let productionIndexData = plan.generated["Workspaces/workspacesIndex.json"] else { throw DebugStateSnapshot.Failure.unsafeFile }
        let retainedIndex = try JSONSerialization.jsonObject(with: retainedIndexData) as? [[String: Any]] ?? []
        let productionIndex = try JSONSerialization.jsonObject(with: productionIndexData) as? [[String: Any]] ?? []
        let replacedDirectories = productionIndex.compactMap { row -> String? in
            guard let id = row["id"] as? String, retained.retainedWorkspaceIDs.contains(id),
                  let uuid = UUID(uuidString: id), let name = row["name"] as? String else { return nil }
            return "Workspaces/" + DomainWorkspaceStoragePath.directoryName(name: name, id: uuid) + "/"
        }
        plan.entries.removeAll { entry in replacedDirectories.contains { entry.relativePath.hasPrefix($0) } }
        for key in Array(plan.generated.keys) where replacedDirectories.contains(where: { key.hasPrefix($0) }) {
            plan.generated.removeValue(forKey: key)
        }
        plan.entries += retained.plan.entries
        plan.observed.merge(retained.plan.observed) { old, _ in old }
        plan.directories.merge(retained.plan.directories) { old, _ in old }
        for (key, data) in retained.plan.generated where key.hasPrefix("Workspaces/") && key != "Workspaces/workspacesIndex.json" {
            plan.generated[key] = data
        }
        let index = productionIndex.filter { row in
            !((row["id"] as? String).map { retained.retainedWorkspaceIDs.contains($0) } ?? false)
        } + retainedIndex
        plan.generated["Workspaces/workspacesIndex.json"] = try json(index)
        let windows = root.appendingPathComponent("windowSessions.json")
        if fm.fileExists(atPath: windows.path), var prior = try object(windows) as? [String: Any] {
            let entries = (prior["windows"] as? [[String: Any]] ?? []).filter {
                ($0["workspaceID"] as? String).map { retained.retainedWorkspaceIDs.contains($0) } ?? false
            }
            if !entries.isEmpty {
                let production = plan.entries.first { $0.relativePath == "windowSessions.json" }
                let baseline = try production.map { try object($0.source) as? [String: Any] } ?? nil
                prior["windows"] = (baseline?["windows"] as? [[String: Any]] ?? []).filter {
                    !(($0["workspaceID"] as? String).map { retained.retainedWorkspaceIDs.contains($0) } ?? false)
                } + entries
                plan.entries.removeAll { $0.relativePath == "windowSessions.json" }
                plan.generated["windowSessions.json"] = try json(prior)
            }
        }
        plan.generated["debugSeedRetainedContinuity.json"] = try json([
            "version": 1,
            "retainedWorkspaceIDs": retained.retainedWorkspaceIDs.sorted(),
            "policy": "Same-profile approvals and their intact workspace/session backing survive ordinary refresh. Missing endpoints remain recorded for runtime revalidation, never manufactured."
        ])
    }
}

extension DebugStateSnapshot {
    typealias ContinuityIdentities = OverseerContinuityStore.BackingIdentities

    static func continuityIdentities(_ url: URL) throws -> ContinuityIdentities {
        _ = try stamp(url)
        return try OverseerContinuityStore(databaseURL: url, profile: OverseerContinuityRepository.productionProfile)
            .readOnlyBackingIdentities()
    }
}
