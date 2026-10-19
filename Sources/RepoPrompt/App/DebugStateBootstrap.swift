import AppKit
import Foundation
import RepoPromptC
import RepoPromptDomainRuntime
import RepoPromptShared

/// Runs once per *process launch*, before settings, windows, catalogs or agents
/// acquire their stores. A normal launch is always a fresh production snapshot;
/// clean mode is an argument, never a persisted preference.
enum DebugStateBootstrap {
    static let cleanSlateArgument = "--debug-clean-slate"
    /// A live release app keeps writing. Only the first attempt captures the whole
    /// profile; later attempts reuse unchanged captured bytes and derived records, so
    /// each retry costs roughly one stat/listing pass instead of a full re-capture.
    static let captureAttempts = 10
    static let captureRetryDelay: TimeInterval = 0.25
    private static let fm = FileManager.default
    @MainActor private static var appProfileLease: DebugProfileAccessLease?

    /// SIGTERM is how conductor, `kill` and logout stop the app. Before AppKit runs (and before
    /// `AppTerminationSignalRouter` is installed) its default disposition would kill the process
    /// mid-publication and orphan a partial stage. While preparing, an async-signal-safe
    /// handler records SIGTERM synchronously (atomic `sigaction` swap, so no install window
    /// or pending callback can lose it) and preparation stops at the next safe point.
    /// `finish()` reinstates the previous disposition before reading the request, then
    /// delivers it, so the process still terminates; a later SIGTERM uses the old disposition.
    struct TerminationRequest {
        static func install() -> TerminationRequest? {
            rpce_startup_sigterm_install() == 0 ? TerminationRequest() : nil
        }

        var isRequested: Bool {
            rpce_startup_sigterm_requested() != 0
        }

        func finish(deliver: () -> Void = { raise(SIGTERM) }) {
            _ = rpce_startup_sigterm_restore()
            if isRequested { deliver() }
        }
    }

    /// Whether an isolated empty profile can recover from a failed launch: production-source
    /// capture failures, yes. A live debug owner, unsafe destination/profile location or a
    /// cancellation would fail identically in clean mode, so Start Empty is not offered.
    static func startEmptyCanRecover(from error: Error) -> Bool {
        guard let failure = error as? DebugStateSnapshot.Failure else { return false }
        switch failure {
        case .sourceChanged, .unsafeFile, .duplicateDestination, .database, .unsupportedWAL: return true
        case .cancelled, .unsafeDestination: return false
        }
    }

    @MainActor static func runIfNeeded(forceCleanSlate: Bool = false) throws {
        guard MCPFilesystemIdentity.current.buildFlavor == .debug,
              !AppLaunchConfiguration.isUnitTestProcess,
              !AppLaunchConfiguration.current.suppressesNonessentialLaunchSideEffects else { return }
        // If the handler cannot be installed, SIGTERM keeps its default (immediate) behavior.
        let termination = TerminationRequest.install()
        defer { termination?.finish() }
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
        let clean = forceCleanSlate || ProcessInfo.processInfo.arguments.contains(cleanSlateArgument)
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
            profileLease: lease,
            cancellation: termination.map { request in .init { request.isRequested } }
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
        profileLease: DebugProfileAccessLease? = nil,
        captureCache: DebugStateSnapshot.CaptureCache = .init(),
        retryDelay: TimeInterval = captureRetryDelay,
        cancellation: DebugStateSnapshot.Cancellation? = nil,
        afterCapture: ((Int) throws -> Void)? = nil
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
        for attempt in 0 ..< captureAttempts {
            if attempt > 0, retryDelay > 0 { Thread.sleep(forTimeInterval: retryDelay) }
            try cancellation?.check()
            do {
                var builder = Builder(locations: locations, releasePreferences: releasePreferences ?? [:], previousPreferences: previousPreferences)
                builder.plan.cache = captureCache
                builder.plan.cancellation = cancellation
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
                var plan = try cleanSlate ? DebugStateSnapshot.Plan() : builder.build()
                // Clean mode publishes too: its swap must honor the same stop request.
                plan.cancellation = cancellation
                try afterCapture?(attempt)
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
        var mappings: [(URL, URL)] = [] {
            didSet { mappingsContextID = nil }
        }

        var mappingsContextID: Int?
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

        /// Rebased records depend on the mapping table, which grows as workspaces are added.
        mutating func mappingsContext() -> Int {
            if let id = mappingsContextID { return id }
            let id = plan.cache.context(mappings.flatMap { [$0.0.absoluteString, $0.1.absoluteString] })
            mappingsContextID = id
            return id
        }

        /// Parse/rebase/re-encode work dominates a capture; retries reuse an unchanged
        /// source's record instead of transforming every session again.
        mutating func derived(_ url: URL, kind: String, transform: (Self, Data) throws -> Data) throws -> Data {
            let context = mappingsContext()
            if let data = try plan.cachedDerivation(url, kind: kind, context: context) { return data }
            let source = try plan.capture(url, retain: false)
            let data = try transform(self, source.data)
            plan.cache.storeDerived(data, kind: kind, url: url, stamp: source.stamp, context: context)
            return data
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
            var journalURLs: [String: URL] = [:]
            if fm.fileExists(atPath: journalDirectory.path) {
                for url in try plan.children(journalDirectory) where url.pathExtension == "json" {
                    guard let record = try object(url) as? [String: Any], (record["version"] as? Int) == 1,
                          let id = record["workspaceID"] as? String,
                          let path = record["fileURL"] as? String, let file = URL(string: path), file.isFileURL
                    else {
                        throw DebugStateSnapshot.Failure.unsafeFile
                    }
                    journals[id] = record
                    journalURLs[id] = url
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
                let encodedWorking = journals[id]?["workingDocument"] as? String
                // Stale index rows can reference an already-removed workspace;
                // omit only that unavailable row, not its surviving history files.
                let saved = fm.fileExists(atPath: url.path) ? try plan.read(url) : nil
                guard saved != nil || encodedWorking != nil else {
                    unavailable.append(id)
                    continue
                }
                // A working journal supersedes the saved document; the stamp of whichever
                // carrier supplied the bytes identifies the parsed, decoded and rebased results.
                let documentURL = encodedWorking == nil ? url : journalURLs[id]
                guard let uuid = UUID(uuidString: id), let documentURL, let documentStamp = plan.observed[documentURL] else {
                    throw DebugStateSnapshot.Failure.unsafeFile
                }
                var documentBytes: Data?
                func document() throws -> Data {
                    if let cached = documentBytes { return cached }
                    let data: Data
                    if let encodedWorking {
                        guard let decoded = Data(base64Encoded: encodedWorking) else { throw DebugStateSnapshot.Failure.unsafeFile }
                        data = decoded
                    } else if let saved {
                        data = saved
                    } else {
                        throw DebugStateSnapshot.Failure.unsafeFile
                    }
                    documentBytes = data
                    return data
                }
                let recordKey = documentURL.path + "\u{0}" + url.path + "\u{0}" + id
                var parsed: [String: Any]?
                var record: DebugStateSnapshot.CaptureCache.WorkspaceRecord
                if let cached = plan.cache.workspaceRecord(recordKey, stamp: documentStamp) {
                    record = cached
                } else {
                    guard let workspace = try JSONSerialization.jsonObject(with: document()) as? [String: Any],
                          let actualID = workspace["id"] as? String, UUID(uuidString: actualID) == uuid,
                          let name = workspace["name"] as? String
                    else {
                        throw DebugStateSnapshot.Failure.unsafeFile
                    }
                    record = .init(
                        name: name,
                        isSystemWorkspace: workspace["isSystemWorkspace"] as? Bool ?? false,
                        isHiddenInMenus: workspace["isHiddenInMenus"] as? Bool ?? false,
                        activeAgentSessionIDs: (workspace["composeTabs"] as? [[String: Any]] ?? []).compactMap { $0["activeAgentSessionID"] as? String }
                    )
                    parsed = workspace
                    plan.cache.storeWorkspaceRecord(record, recordKey, stamp: documentStamp)
                }
                if let retainedIdentities {
                    let sessionsDirectory = url.deletingLastPathComponent().appendingPathComponent("AgentSessions")
                    let savedSessions = fm.fileExists(atPath: sessionsDirectory.path) ? try plan.children(sessionsDirectory) : []
                    let hasSavedEndpoint = savedSessions.contains { file in
                        let name = file.deletingPathExtension().lastPathComponent
                        guard file.pathExtension == "json", name.hasPrefix("AgentSession-"),
                              let sessionID = UUID(uuidString: String(name.dropFirst("AgentSession-".count))) else { return false }
                        return retainedIdentities.sessions.contains(sessionID.uuidString)
                    }
                    guard retainedIdentities.workspaces.contains(id) || hasSavedEndpoint
                        || record.activeAgentSessionIDs.contains(where: { retainedIdentities.sessions.contains($0) }) else { continue }
                    retainedWorkspaceIDs.insert(id)
                }
                // Decode against this binary before any publish or normalization.
                if !record.decoded {
                    _ = try DomainWorkspaceDocument.decode(documentBytes: document(), fileURL: url)
                    record.decoded = true
                    plan.cache.storeWorkspaceRecord(record, recordKey, stamp: documentStamp)
                }
                let directory = DomainWorkspaceStoragePath.directoryName(name: record.name, id: uuid)
                let relative = "Workspaces/" + directory
                let destination = locations.workspaceRoot.appendingPathComponent(directory)
                mappings.insert((url.deletingLastPathComponent(), destination), at: 0)
                let context = mappingsContext()
                let data: Data
                if let cached = plan.cache.derived(kind: "workspace-document", url: documentURL, stamp: documentStamp, context: context) {
                    data = cached
                } else {
                    guard var workspace = try parsed ?? (JSONSerialization.jsonObject(with: document()) as? [String: Any]) else {
                        throw DebugStateSnapshot.Failure.unsafeFile
                    }
                    workspace.removeValue(forKey: "customStoragePath")
                    data = try json(rebase(workspace))
                    plan.cache.storeDerived(data, kind: "workspace-document", url: documentURL, stamp: documentStamp, context: context)
                }
                if saved != nil { try plan.add(url, as: relative + "/workspace.json", replacement: data) }
                else { plan.generated[relative + "/workspace.json"] = data }
                try addTree(url.deletingLastPathComponent(), relative: relative, excluding: ["workspace.json", "_git_data"])
                seededIndex.append([
                    "id": id, "name": record.name,
                    "isSystemWorkspace": record.isSystemWorkspace,
                    "isHiddenInMenus": record.isHiddenInMenus
                ])
            }
            index = seededIndex
            // The index can be absent in a catalog-only profile. A generated file
            // has no source inode; use a separate in-memory staging artifact.
            plan.generated["Workspaces/workspacesIndex.json"] = try json(index)
            plan.generated["debugSeedUnavailableWorkspaces.json"] = try json(unavailable)
        }

        /// Never seeded from an app-owned tree: locks/claims, source backups and recovery
        /// trees, and the rebuildable session index (copied records would retain stale
        /// file size/mtime and runtime summaries after handle detachment).
        static let ownedTreeExclusions: Set<String> = ["locks", "claims", "Backups", ".self-compact-recovery", "AgentSessionIndex.json"]

        mutating func addTree(_ directory: URL, relative: String, excluding: Set<String> = []) throws {
            guard fm.fileExists(atPath: directory.path) else { return }
            // The same selection governs enumeration and verification: skipped names can
            // neither be published nor invalidate the capture when production churns them.
            let selection = DebugStateSnapshot.Selection(excluding: excluding.union(Self.ownedTreeExclusions))
            for url in try plan.children(directory, selection: selection) {
                let name = url.lastPathComponent
                let target = relative + "/" + name
                if try DebugStateSnapshot.kind(url) == .directory { try addTree(url, relative: target) }
                else if name.hasPrefix("AgentSession-"), url.pathExtension == "json" {
                    let baseline = retainedIdentities == nil
                    let data = try derived(url, kind: baseline ? "agent-session-baseline" : "agent-session-retained") { builder, bytes in
                        guard var session = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw DebugStateSnapshot.Failure.unsafeFile }
                        if baseline {
                            for key in ["providerSessionID", "providerCleanupHandle", "codexConversationID", "codexRolloutPath", "codexMcpSessionKey", "delegationScopeID", "lastRunState", "selfCompactState"] {
                                session.removeValue(forKey: key)
                            }
                            for key in ["autoWakeOnOversightUpdates", "routineWakeIntervalEnabled", "periodicIdleWakeEnabled"] {
                                session[key] = false
                            }
                            session["worktreeMergeOperations"] = []
                        }
                        return try builder.json(builder.rebaseManagedAttachments(in: builder.rebase(session) as? [String: Any] ?? session))
                    }
                    try plan.add(url, as: target, replacement: data)
                } else if url.pathExtension == "json", relative.contains("/Chats") {
                    let data = try derived(url, kind: "chat") { builder, bytes in
                        try builder.json(builder.rebase(JSONSerialization.jsonObject(with: bytes)))
                    }
                    try plan.add(url, as: target, replacement: data)
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
