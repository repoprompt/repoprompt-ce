import AppKit
import Foundation
import RepoPromptDomainRuntime
import RepoPromptShared

/// Runs once per *process launch*, before settings, windows, catalogs or agents
/// acquire their stores. A normal launch is always a fresh production snapshot;
/// clean mode is an argument, never a persisted preference.
enum DebugStateBootstrap {
    static let cleanSlateArgument = "--debug-clean-slate"
    private static let fm = FileManager.default
    @MainActor private static var appProfileLease: DebugProfileAccessLease?

    @MainActor static func runIfNeeded() throws {
        guard MCPFilesystemIdentity.current.buildFlavor == .debug,
              !AppLaunchConfiguration.isUnitTestProcess,
              !AppLaunchConfiguration.current.suppressesNonessentialLaunchSideEffects else { return }
        // The short startup lock protects concurrent seeds; an already-running
        // debug app must also be absent, because its ordinary stores are live.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: AppProfileLocations.current.preferencesDomain)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        else {
            throw DebugStateSnapshot.Failure.unsafeDestination
        }
        let lease = try DebugProfileAccessLease.acquire(locations: .current, exclusive: true)
        let start = Date()
        let defaults = UserDefaults.standard
        let release = AppProfileLocations(identity: .repoPromptCE(.release))
        let prior = defaults.persistentDomain(forName: AppProfileLocations.current.preferencesDomain) ?? [:]
        let clean = ProcessInfo.processInfo.arguments.contains(cleanSlateArgument)
        let preferenceDirectory = release.homeDirectory.appendingPathComponent("Library/Preferences")
        let sourcePreferencesURL = preferenceDirectory.appendingPathComponent(release.preferencesDomain + ".plist")
        let priorPreferencesURL = preferenceDirectory.appendingPathComponent(AppProfileLocations.current.preferencesDomain + ".plist")
        try AppProfileLocations.current.validateMetadataFile(priorPreferencesURL)
        if fm.fileExists(atPath: priorPreferencesURL.path),
           try ((fm.attributesOfItem(atPath: priorPreferencesURL.path)[.referenceCount] as? NSNumber)?.intValue ?? 1) != 1
        {
            throw DebugStateSnapshot.Failure.unsafeDestination
        }
        let receipt = try seed(
            locations: .current,
            cleanSlate: clean,
            releasePreferences: nil,
            previousPreferences: prior,
            preferenceSourceURL: clean ? nil : sourcePreferencesURL,
            previousPreferenceFileURL: priorPreferencesURL,
            profileLease: lease
        )
        let preferencesURL = AppProfileLocations.current.applicationSupportRoot.appendingPathComponent("seedPreferences.plist")
        let preferences = try PropertyListSerialization.propertyList(from: Data(contentsOf: preferencesURL), format: nil) as? [String: Any] ?? [:]
        defaults.setPersistentDomain(preferences, forName: AppProfileLocations.current.preferencesDomain)
        try lease.allowWriters()
        appProfileLease = lease
        print("[DebugStateSeed] schema=\(receipt.version) clean=\(receipt.cleanSlate) files=\(receipt.copiedFiles) bytes=\(receipt.copiedBytes) captureSeconds=\(receipt.seconds) totalSeconds=\(Date().timeIntervalSince(start))")
    }

    static func seed(
        locations: AppProfileLocations,
        cleanSlate: Bool,
        releasePreferences: [String: Any]?,
        previousPreferences: [String: Any] = [:],
        preferenceSourceURL: URL? = nil,
        previousPreferenceFileURL: URL? = nil,
        profileLease: DebugProfileAccessLease? = nil
    ) throws -> DebugStateSnapshot.Receipt {
        let startedAt = Date()
        guard locations.identity.buildFlavor == .debug else { throw DebugStateSnapshot.Failure.unsafeDestination }
        let lease = try profileLease ?? DebugProfileAccessLease.acquire(locations: locations, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        let priorData: Data
        if let url = previousPreferenceFileURL, fm.fileExists(atPath: url.path) {
            _ = try DebugStateSnapshot.stamp(url)
            priorData = try Data(contentsOf: url)
        } else {
            priorData = try PropertyListSerialization.data(fromPropertyList: previousPreferences, format: .binary, options: 0)
        }
        var lastError: Error = DebugStateSnapshot.Failure.sourceChanged
        for _ in 0 ..< 3 {
            do {
                var builder = Builder(locations: locations, releasePreferences: releasePreferences ?? [:], previousPreferences: previousPreferences)
                var hasReleasePreferences = releasePreferences != nil
                if !cleanSlate, let url = preferenceSourceURL, fm.fileExists(atPath: url.path) {
                    let bytes = try builder.plan.read(url)
                    guard let preferences = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
                        throw DebugStateSnapshot.Failure.unsafeFile
                    }
                    builder.releasePreferences = preferences
                    hasReleasePreferences = true
                }
                // Absence is not an empty production domain. Preserve debug defaults when
                // there is no source, and never source DEBUG-only diagnostics from release.
                var preferences = cleanSlate ? [:] : (hasReleasePreferences ? builder.releasePreferences : previousPreferences)
                if !cleanSlate {
                    for key in ["claudeRawEventLoggingEnabled", "claudeRawEventLogFilePath", "enableAgentModePerfDiagnostics", "emitAgentModePerfDiagnosticsToOSLog"] {
                        preferences.removeValue(forKey: key)
                        if let value = previousPreferences[key] { preferences[key] = value }
                    }
                }
                // Materialize every custom metadata source by value inside this
                // debug profile, not back into its production custom directory.
                preferences.removeValue(forKey: "GlobalCustomStorageURL")
                let preferencesData = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
                let plan = try cleanSlate ? DebugStateSnapshot.Plan() : builder.build()
                return try DebugStateSnapshot(locations: locations).publish(
                    plan: plan, cleanSlate: cleanSlate, preferences: preferencesData, previousPreferences: priorData, startedAt: startedAt, profileLease: lease
                )
            } catch DebugStateSnapshot.Failure.sourceChanged {
                lastError = DebugStateSnapshot.Failure.sourceChanged
            }
        }
        throw lastError
    }

    struct Builder {
        let locations: AppProfileLocations
        var releasePreferences: [String: Any]
        var previousPreferences: [String: Any] = [:]
        var sourceOverride: AppProfileLocations?
        var retainedIdentities: DebugStateSnapshot.ContinuityIdentities?
        var retainedWorkspaceIDs = Set<String>()
        var plan = DebugStateSnapshot.Plan()
        var mappings: [(URL, URL)] = []
        var source: AppProfileLocations {
            sourceOverride ?? AppProfileLocations(identity: .repoPromptCE(.release), homeDirectory: locations.homeDirectory)
        }

        mutating func build() throws -> DebugStateSnapshot.Plan {
            let root = source.applicationSupportRoot
            mappings = [(root, locations.applicationSupportRoot), (source.savedPromptsRoot, locations.savedPromptsRoot)]
            // Only app-owned mutable state, never provider homes/auth, caches,
            // install resources, runtime downloads, IPC claims or process locks.
            for name in ["Settings", "Presets", "Partitions", "Workflows"] {
                try addTree(root.appendingPathComponent(name), relative: name)
            }
            for name in ["SavedPrompts.json", "ContextBuilderPrompts.json"] {
                let url = source.savedPromptsRoot.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { try plan.add(url, as: "SavedPrompts/" + name) }
            }
            let windows = root.appendingPathComponent("windowSessions.json")
            if fm.fileExists(atPath: windows.path) { try plan.add(windows, as: "windowSessions.json") }
            try addWorkspaces()
            try addTree(root.appendingPathComponent(runtimePath + "/oracle"), relative: runtimePath + "/oracle")
            // Cross-profile grants are evidence, not authority. Preserve their
            // exact snapshot separately; #1376 opens only its new debug-owned DB.
            for name in ["agentSessionOversightLinks.json", "delegationScopes.json", "delegationWorktreeOwnership.json"] {
                let url = root.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { try plan.add(url, as: "ProductionContinuity/" + name) }
            }
            let database = root.appendingPathComponent("Overseer/continuity.sqlite")
            if fm.fileExists(atPath: database.path) {
                try plan.add(database, as: "ProductionContinuity/continuity.sqlite", database: true)
            }
            try preserveDebugContinuity()
            try preserveDebugOwnedState()
            plan.generated["debugSeedSources.json"] = try json([
                "version": 1,
                "profile": locations.preferencesDomain,
                "files": plan.entries.map { ["source": $0.source.path, "destination": $0.relativePath] },
                "controlSources": plan.observed.keys.map(\.path).sorted(),
                "preservedNotActivated": ["Production oversight grants and provider resume handles"],
                "preservedNotSeeded": ["Workspace folders outside the live catalog", "Source recovery/backup trees and Git data", "Rebuildable indexes, locks and runtime claims"]
            ])
            return plan
        }

        private var runtimePath: String {
            DomainPersistenceCoordinator.runtimeDirectoryName(profileIdentifier: source.profileIdentifier)
        }

        mutating func object(_ url: URL) throws -> Any {
            try JSONSerialization.jsonObject(with: plan.read(url))
        }

        mutating func addWorkspaces() throws {
            let workspaceRoot = (releasePreferences["GlobalCustomStorageURL"] as? String).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? source.workspaceRoot
            let indexURL = workspaceRoot.appendingPathComponent("workspacesIndex.json")
            var index = fm.fileExists(atPath: indexURL.path) ? try object(indexURL) as? [[String: Any]] ?? [] : []
            var files: [String: URL] = [:]
            for entry in index {
                guard let id = entry["id"] as? String, let name = entry["name"] as? String,
                      let uuid = UUID(uuidString: id) else { throw DebugStateSnapshot.Failure.unsafeFile }
                let custom = (entry["customStoragePath"] as? String).flatMap(URL.init(string:))
                let directory = custom ?? workspaceRoot.appendingPathComponent(DomainWorkspaceStoragePath.directoryName(name: name, id: uuid))
                files[id] = directory.appendingPathComponent("workspace.json")
            }
            let runtime = source.applicationSupportRoot.appendingPathComponent(runtimePath)
            let catalog = runtime.appendingPathComponent("workspace-catalog.json")
            var deleted = Set<String>()
            if fm.fileExists(atPath: catalog.path) {
                guard let document = try object(catalog) as? [String: Any],
                      (document["version"] as? Int) == 1,
                      let entries = document["entries"] as? [[String: Any]] else { throw DebugStateSnapshot.Failure.unsafeFile }
                for entry in document["deletions"] as? [[String: Any]] ?? [] {
                    guard let id = entry["workspaceID"] as? String else { throw DebugStateSnapshot.Failure.unsafeFile }
                    deleted.insert(id)
                }
                files = [:]
                for entry in entries {
                    guard let id = entry["workspaceID"] as? String,
                          let path = entry["fileURL"] as? String, let url = URL(string: path), url.isFileURL
                    else {
                        throw DebugStateSnapshot.Failure.unsafeFile
                    }
                    files[id] = url
                }
            }
            let tombstones = runtime.appendingPathComponent("deletion-tombstones")
            if fm.fileExists(atPath: tombstones.path) {
                for url in try plan.children(tombstones) where url.pathExtension == "json" {
                    guard let record = try object(url) as? [String: Any],
                          (record["version"] as? Int) == 1,
                          let id = record["workspaceID"] as? String else { throw DebugStateSnapshot.Failure.unsafeFile }
                    deleted.insert(id)
                }
            }
            let journalDirectory = runtime.appendingPathComponent("working-journals")
            var journals: [String: [String: Any]] = [:]
            if fm.fileExists(atPath: journalDirectory.path) {
                for url in try plan.children(journalDirectory) where url.pathExtension == "json" {
                    guard let record = try object(url) as? [String: Any], (record["version"] as? Int) == 1,
                          let id = record["workspaceID"] as? String,
                          let path = record["fileURL"] as? String, let file = URL(string: path), file.isFileURL
                    else {
                        throw DebugStateSnapshot.Failure.unsafeFile
                    }
                    journals[id] = record
                    if files[id] == nil { files[id] = file }
                }
            }
            for id in deleted {
                files.removeValue(forKey: id)
            }
            var unavailable: [String] = []
            var seededIndex: [[String: Any]] = []
            for (id, url) in files.sorted(by: { $0.key < $1.key }) {
                if retainedIdentities != nil { try locations.validateCustomWorkspaceDirectory(url.deletingLastPathComponent()) }
                var working: Data?
                if let encoded = journals[id]?["workingDocument"] as? String {
                    guard let data = Data(base64Encoded: encoded) else { throw DebugStateSnapshot.Failure.unsafeFile }
                    working = data
                }
                // Stale index rows can reference an already-removed workspace;
                // omit only that unavailable row, not its surviving history files.
                let bytes: Data
                if fm.fileExists(atPath: url.path) { bytes = try plan.read(url) }
                else if let working { bytes = working }
                else { unavailable.append(id)
                    continue
                }
                guard var workspace = try JSONSerialization.jsonObject(with: working ?? bytes) as? [String: Any],
                      let actualID = workspace["id"] as? String, UUID(uuidString: actualID) == UUID(uuidString: id),
                      let uuid = UUID(uuidString: id), let name = workspace["name"] as? String
                else {
                    throw DebugStateSnapshot.Failure.unsafeFile
                }
                if let retainedIdentities {
                    let tabs = workspace["composeTabs"] as? [[String: Any]] ?? []
                    let sessionsDirectory = url.deletingLastPathComponent().appendingPathComponent("AgentSessions")
                    let savedSessions = fm.fileExists(atPath: sessionsDirectory.path) ? try plan.children(sessionsDirectory) : []
                    let hasSavedEndpoint = savedSessions.contains { file in
                        let name = file.deletingPathExtension().lastPathComponent
                        guard file.pathExtension == "json", name.hasPrefix("AgentSession-"),
                              let sessionID = UUID(uuidString: String(name.dropFirst("AgentSession-".count))) else { return false }
                        return retainedIdentities.sessions.contains(sessionID.uuidString)
                    }
                    guard retainedIdentities.workspaces.contains(id) || hasSavedEndpoint || tabs.contains(where: {
                        ($0["activeAgentSessionID"] as? String).map { retainedIdentities.sessions.contains($0) } ?? false
                    }) else { continue }
                    retainedWorkspaceIDs.insert(id)
                }
                // Decode against this binary before any publish or normalization.
                _ = try DomainWorkspaceDocument.decode(documentBytes: working ?? bytes, fileURL: url)
                let directory = DomainWorkspaceStoragePath.directoryName(name: name, id: uuid)
                let relative = "Workspaces/" + directory
                let destination = locations.workspaceRoot.appendingPathComponent(directory)
                mappings.insert((url.deletingLastPathComponent(), destination), at: 0)
                workspace.removeValue(forKey: "customStoragePath")
                let data = try json(rebase(workspace))
                if fm.fileExists(atPath: url.path) { try plan.add(url, as: relative + "/workspace.json", replacement: data) }
                else { plan.generated[relative + "/workspace.json"] = data }
                try addTree(url.deletingLastPathComponent(), relative: relative, excluding: ["workspace.json", "_git_data"])
                seededIndex.append([
                    "id": id, "name": name,
                    "isSystemWorkspace": workspace["isSystemWorkspace"] as? Bool ?? false,
                    "isHiddenInMenus": workspace["isHiddenInMenus"] as? Bool ?? false
                ])
            }
            index = seededIndex
            // The index can be absent in a catalog-only profile. A generated file
            // has no source inode; use a separate in-memory staging artifact.
            plan.generated["Workspaces/workspacesIndex.json"] = try json(index)
            plan.generated["debugSeedUnavailableWorkspaces.json"] = try json(unavailable)
        }

        mutating func addTree(_ directory: URL, relative: String, excluding: Set<String> = []) throws {
            guard fm.fileExists(atPath: directory.path) else { return }
            for url in try plan.children(directory) {
                let name = url.lastPathComponent
                guard !excluding.contains(name), name != "locks", name != "claims", name != "Backups", name != ".self-compact-recovery",
                      !name.hasSuffix(".lock"), !name.contains(".sb-"), !name.hasSuffix(".tmp") else { continue }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw DebugStateSnapshot.Failure.unsafeFile }
                let target = relative + "/" + name
                if values.isDirectory == true { try addTree(url, relative: target) }
                else if name == "AgentSessionIndex.json" {
                    // A rebuildable projection; copied records would retain stale
                    // file size/mtime and runtime summaries after handle detachment.
                    continue
                } else if name.hasPrefix("AgentSession-"), url.pathExtension == "json" {
                    guard var session = try object(url) as? [String: Any] else { throw DebugStateSnapshot.Failure.unsafeFile }
                    if retainedIdentities == nil {
                        for key in ["providerSessionID", "providerCleanupHandle", "codexConversationID", "codexRolloutPath", "codexMcpSessionKey", "delegationScopeID", "lastRunState", "selfCompactState"] {
                            session.removeValue(forKey: key)
                        }
                        for key in ["autoWakeOnOversightUpdates", "routineWakeIntervalEnabled", "periodicIdleWakeEnabled"] {
                            session[key] = false
                        }
                        session["worktreeMergeOperations"] = []
                    }
                    try plan.add(url, as: target, replacement: json(rebaseManagedAttachments(in: rebase(session) as? [String: Any] ?? session)))
                } else if url.pathExtension == "json", relative.contains("/Chats") {
                    try plan.add(url, as: target, replacement: json(rebase(object(url))))
                } else {
                    try plan.add(url, as: target)
                }
            }
        }

        func json(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        }

        /// Rewrite schema-owned metadata references only, never arbitrary
        /// transcript text, prompts, tool payloads or user repository paths.
        func rebase(_ value: Any, key: String? = nil) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.reduce(into: [String: Any]()) { result, pair in
                    result[pair.key] = ["fileURL", "customStoragePath", "workspaceFileURL", "agentSessionFileURL", "chatSessionFileURL"].contains(pair.key)
                        ? rebase(pair.value, key: pair.key) : pair.value
                }
            }
            if let array = value as? [Any] { return array.map { rebase($0, key: key) } }
            guard let string = value as? String, let key,
                  ["fileURL", "customStoragePath", "workspaceFileURL", "agentSessionFileURL", "chatSessionFileURL"].contains(key),
                  let url = URL(string: string), url.isFileURL else { return value }
            for (old, new) in mappings where url.standardizedFileURL.pathComponents.starts(with: old.standardizedFileURL.pathComponents) {
                let suffix = url.standardizedFileURL.pathComponents.dropFirst(old.standardizedFileURL.pathComponents.count)
                return suffix.reduce(new) { $0.appendingPathComponent($1) }.absoluteString
            }
            return value
        }
    }
}
