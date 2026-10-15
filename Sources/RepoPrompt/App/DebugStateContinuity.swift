import Foundation
import RepoPromptC
import RepoPromptDomainRuntime
import RepoPromptShared

extension DebugStateBootstrap.Builder {
    /// A production baseline is not a revocation of this profile's explicit
    /// approvals. Keep the owning workspace and backing sessions together: a DB
    /// row alone cannot restore an endpoint whose compose tab disappeared.
    mutating func preserveDebugContinuity() throws {
        let fm = FileManager.default
        let root = locations.applicationSupportRoot
        var identities = DebugStateSnapshot.ContinuityIdentities()
        let database = root.appendingPathComponent("Overseer/continuity.sqlite")
        if fm.fileExists(atPath: database.path) {
            try plan.add(database, as: "Overseer/continuity.sqlite", database: true)
            identities = try DebugStateSnapshot.continuityIdentities(database)
        }
        for name in ["agentSessionOversightLinks.json", "delegationScopes.json", "delegationWorktreeOwnership.json"] {
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                let document = try object(url)
                identities.collectLegacy(document)
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
        // Same workspace UUID means the same authority context. Prefer its intact
        // debug-owned document, not production tabs with coincident session IDs.
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
    struct ContinuityIdentities {
        var sessions = Set<String>()
        var workspaces = Set<String>()

        mutating func collectLegacy(_ value: Any) {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if let string = child as? String, let id = UUID(uuidString: string) {
                        if ["observerSessionID", "targetSessionID", "granteeSessionID", "createdBySessionID"].contains(key) {
                            sessions.insert(id.uuidString)
                        }
                    }
                    if key == "workspace", let payload = child as? [String: String],
                       let value = payload["_0"], let id = UUID(uuidString: value) { workspaces.insert(id.uuidString) }
                    if key == "tree", let payload = child as? [String: String],
                       let value = payload["_0"], let id = UUID(uuidString: value) { sessions.insert(id.uuidString) }
                    collectLegacy(child)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    collectLegacy(child)
                }
            }
        }
    }

    /// Read only the existing debug authority's profile and endpoint columns.
    /// This does not migrate, activate, normalize or rewrite its records. Future
    /// or wrong-profile DBs stay intact and are rejected by the owning store.
    static func continuityIdentities(_ url: URL) throws -> ContinuityIdentities {
        _ = try stamp(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 100) ?? Data()
        guard header.count == 100, header.prefix(16) == Data("SQLite format 3\0".utf8) else { throw Failure.unsafeFile }
        guard header[18] != 2 else { throw Failure.unsupportedWAL }
        var db: OpaquePointer?
        let code = try sqlite3_open_v2(physicalPath(url), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
        guard code == SQLITE_OK, let db else { if let db { sqlite3_close_v2(db) }
            throw Failure.database(code)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 250)
        func rows(_ sql: String) throws -> [[String?]] {
            var statement: OpaquePointer?
            let prepare = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            guard prepare == SQLITE_OK, let statement else { throw Failure.database(prepare) }
            defer { sqlite3_finalize(statement) }
            var result: [[String?]] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw Failure.database(step) }
                result.append((0 ..< sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                })
            }
        }
        guard try rows("PRAGMA user_version").first?.first == "1",
              try rows("SELECT profile FROM profile_state WHERE singleton=1").first?.first == "repoprompt-ce-debug-overseer-v1" else { return .init() }
        var result = ContinuityIdentities()
        for row in try rows("SELECT owner_id,anchor_id,workspace_id FROM continuity_rows WHERE terminal=0") {
            for value in row.prefix(2) {
                if let value, let id = UUID(uuidString: value) { result.sessions.insert(id.uuidString) }
            }
            if let value = row[2], let id = UUID(uuidString: value) { result.workspaces.insert(id.uuidString) }
        }
        return result
    }
}
