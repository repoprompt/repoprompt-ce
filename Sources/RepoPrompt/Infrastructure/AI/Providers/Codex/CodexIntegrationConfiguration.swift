import Darwin
import Foundation
import OSLog
import RepoPromptShared

/// Codex-specific integration configuration helpers.
///
/// This namespace owns Codex CLI config.toml parsing/mutation, RepoPrompt MCP
/// installation/repair, and Codex runtime override construction.
enum CodexIntegrationConfiguration {
    static let toolTimeoutDefaultsKey = "CodexToolTimeoutMigratedV5"
    // Codex applies this timeout to every tool on the MCP server. Preserve the existing
    // multi-hour budget because Oracle and Context Builder remain synchronous and have no
    // per-tool timeout exemption.
    static let desiredToolTimeoutSeconds = MCPTimeoutPolicy.codexServerActiveTimeoutSeconds
    static let desiredSupportsParallelToolCalls = true
    static let desiredToolOutputTokenLimit = 25000

    static let directOnlyToolNamespace = "mcp__RepoPromptCE"

    // RepoPrompt owns the RepoPromptCE MCP block's launch/policy keys, the global
    // tool output limit already managed by this integration, and exactly these two
    // [features.code_mode] keys: enabled and direct_only_tool_namespaces. Other
    // user-authored TOML is preserved; ambiguous/conflicting code-mode layouts fail
    // before any write.

    /// Serializes in-process read-modify-write access to RepoPrompt's owned Codex config across concurrent
    /// Codex startup/provisioning paths. Cross-process writers remain outside this lock's scope.
    private static let fileLock = NSLock()
    private static let provisioningLogger = Logger(subsystem: "com.pvncher.repoprompt.ce", category: "CodexMCPProvisioning")
    private static let tomlBareKeyCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    private static let repoPromptMCPConfiguration = RepoPromptMCPServerConfiguration.repoPrompt
    private static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName
    /// Delimits the MCP blocks mirrored from the user's normal Codex home into RepoPrompt's
    /// isolated Codex home. Only this generated region is replaced on later launches; all other
    /// user-authored isolated-home configuration remains untouched.
    private static let managedExternalMCPBeginMarker = "# BEGIN RepoPrompt CE managed external Codex MCP servers"
    private static let managedExternalMCPEndMarker = "# END RepoPrompt CE managed external Codex MCP servers"
    /// This region is distinct from the read-only import above. It contains only a
    /// connection explicitly created from RepoPrompt Settings and is never populated
    /// from the user's global Codex config.
    private static let settingsManagedMCPBeginMarker = "# BEGIN RepoPrompt CE Settings managed Codex MCP connections"
    private static let settingsManagedMCPEndMarker = "# END RepoPrompt CE Settings managed Codex MCP connections"
    static let settingsManagedFigmaServerName = "figma"
    static let settingsManagedFigmaURL = "https://mcp.figma.com/mcp"
    private static var serverCommand: String {
        repoPromptMCPConfiguration.command
    }

    private static var serverArgumentsTOML: String {
        let values = repoPromptMCPConfiguration.args.map { "\"\($0)\"" }
        return "[\(values.joined(separator: ", "))]"
    }

    enum MCPServerIdentity: Equatable {
        case canonicalFigma
        case figmaAlias
        case other
    }

    struct ServerEntry {
        let rawName: String
        let normalizedName: String
        let cliPathComponent: String
        /// The server's explicit/default Codex enablement. This is imported as configuration, not
        /// an authorization bypass: Agent Mode's own permission profile may still suppress it.
        let isEnabled: Bool
        /// An explicit (or malformed, therefore fail-closed) disabled value in Codex config.
        /// A RepoPrompt UI preference must not revive a server the user disabled globally.
        let isExplicitlyDisabled: Bool
        let identity: MCPServerIdentity

        init(
            rawName: String,
            normalizedName: String,
            cliPathComponent: String,
            isEnabled: Bool = false,
            isExplicitlyDisabled: Bool = false,
            identity: MCPServerIdentity = .other
        ) {
            self.rawName = rawName
            self.normalizedName = normalizedName
            self.cliPathComponent = cliPathComponent
            self.isEnabled = isEnabled
            self.isExplicitlyDisabled = isExplicitlyDisabled
            self.identity = identity
        }
    }

    enum ExternalMCPSourceOutcome {
        case absent
        case valid(content: String, candidateIndex: Int)
        case invalid(candidateIndex: Int)
        /// A readable candidate changed while it was being inspected. Treat this as a
        /// transient unavailable source rather than importing an unverified snapshot.
        case changed(candidateIndex: Int)
        case unavailable
    }

    enum ManagedExternalMCPMarkerProblem: String, Equatable {
        case duplicateBegin
        case duplicateEnd
        case orphanBegin
        case orphanEnd
        case reversed
        case nested
        case invalidRegion
    }

    enum ManagedExternalMCPMarkerClassification: Equatable {
        case absent
        case valid(Range<Int>)
        case malformed(ManagedExternalMCPMarkerProblem)
    }

    enum ExternalMCPDegradation: Equatable {
        case sourceUnavailable
        case sourceChanged
        case sourceInvalid
        case malformedMarkers(ManagedExternalMCPMarkerProblem)
    }

    struct ExternalMCPMergeResult {
        let content: String
        let changed: Bool
        let importedServerNames: [String]
        let skippedConflictingServerNames: [String]
        let degradations: [ExternalMCPDegradation]
    }

    struct ConfigurationFileFingerprint: Equatable {
        /// Intentionally opaque to diagnostics. Equality detects a concurrent replacement
        /// without exposing paths, file content, metadata, or a reusable content hash.
        let bytes: Data?

        static let absent = Self(bytes: nil)
    }

    struct ExternalConfigSourceReader {
        /// Returns nil only when the candidate is missing. Read/decoding failures throw.
        let readUTF8: (URL) throws -> String?
        /// Optional because focused parser tests need not model the filesystem. Production
        /// injection always supplies it and samples before and after each successful read.
        let fingerprint: ((URL) throws -> ConfigurationFileFingerprint)?

        init(
            readUTF8: @escaping (URL) throws -> String?,
            fingerprint: ((URL) throws -> ConfigurationFileFingerprint)? = nil
        ) {
            self.readUTF8 = readUTF8
            self.fingerprint = fingerprint
        }
    }

    struct ManagedConfigStore {
        /// Returns nil only when the managed file is missing. Read/decoding failures throw.
        let readUTF8: (URL) throws -> String?
        let replaceAtomically: (String, URL) throws -> Void
        let readBack: (URL) throws -> Data
        /// Optional only for legacy/focused test seams. The production store compares this
        /// immediately before replacement to avoid clobbering a cross-process update.
        let fingerprint: ((URL) throws -> ConfigurationFileFingerprint)?

        init(
            readUTF8: @escaping (URL) throws -> String?,
            replaceAtomically: @escaping (String, URL) throws -> Void,
            readBack: @escaping (URL) throws -> Data,
            fingerprint: ((URL) throws -> ConfigurationFileFingerprint)? = nil
        ) {
            self.readUTF8 = readUTF8
            self.replaceAtomically = replaceAtomically
            self.readBack = readBack
            self.fingerprint = fingerprint
        }
    }

    struct ProvisioningDiagnosticSink {
        let record: (String) -> Void
    }

    struct CancellationCheckpoint {
        let isCancelled: () -> Bool
    }

    struct ProvisioningDependencies {
        let sourceReader: ExternalConfigSourceReader
        let managedStore: ManagedConfigStore
        let diagnostics: ProvisioningDiagnosticSink
        let cancellation: CancellationCheckpoint

        static func live(fileManager: FileManager = .default) -> ProvisioningDependencies {
            ProvisioningDependencies(
                sourceReader: ExternalConfigSourceReader(
                    readUTF8: { url in
                        do {
                            return try String(contentsOf: url, encoding: .utf8)
                        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                            return nil
                        }
                    },
                    fingerprint: { url in
                        do {
                            return try .init(bytes: Data(contentsOf: url))
                        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                            return .absent
                        }
                    }
                ),
                managedStore: ManagedConfigStore(
                    readUTF8: { url in
                        do {
                            return try String(contentsOf: url, encoding: .utf8)
                        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                            return nil
                        }
                    },
                    replaceAtomically: { content, url in
                        let existingAttributes: [FileAttributeKey: Any]
                        do {
                            existingAttributes = try fileManager.attributesOfItem(atPath: url.path)
                        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                            existingAttributes = [:]
                        } catch let error as POSIXError where error.code == .ENOENT {
                            // A first-run isolated config legitimately does not exist yet.
                            // Treat only the precise missing-target outcome as creatable; other
                            // attribute failures must continue to fail closed.
                            existingAttributes = [:]
                        }
                        if let owner = existingAttributes[.ownerAccountID] as? NSNumber,
                           owner.intValue != Int32(getuid())
                        {
                            throw POSIXError(.EPERM)
                        }
                        let existingPermissions = (existingAttributes[.posixPermissions] as? NSNumber)?.intValue
                        // Preserve only owner-readable/writable/executable bits. A file with
                        // group/world access must not be carried forward into an isolated home.
                        let permissions = existingPermissions.map { $0 & 0o700 } ?? 0o600
                        let restrictivePermissions = permissions == 0 ? 0o600 : permissions
                        let temporaryURL = url.deletingLastPathComponent()
                            .appendingPathComponent(".\(url.lastPathComponent).repoprompt-\(UUID().uuidString).tmp")
                        defer { try? fileManager.removeItem(at: temporaryURL) }
                        try Data(content.utf8).write(to: temporaryURL, options: .withoutOverwriting)
                        try fileManager.setAttributes([.posixPermissions: restrictivePermissions], ofItemAtPath: temporaryURL.path)
                        guard rename(temporaryURL.path, url.path) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    },
                    readBack: { try Data(contentsOf: $0) },
                    fingerprint: { url in
                        do {
                            return try .init(bytes: Data(contentsOf: url))
                        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                            return .absent
                        }
                    }
                ),
                diagnostics: ProvisioningDiagnosticSink { message in
                    provisioningLogger.notice("\(message, privacy: .public)")
                },
                cancellation: CancellationCheckpoint { false }
            )
        }
    }

    enum PersistentMCPUpdateMode {
        case install
        case discovery
        /// Bootstrap only the app-owned RepoPromptCE server. External MCP source files
        /// are intentionally not inspected or merged on fresh Agent Mode construction.
        case repoPromptOnly
    }

    enum PersistentMCPUpdateStatus: Equatable {
        case updated
        case unchanged
        case cancelled
        case failed(PersistentMCPUpdateFailure)
    }

    enum PersistentMCPUpdateFailure: Equatable {
        case managedRead
        case policyConflict(String)
        case unsafeManagedMarkers
        case managedWrite
        case targetChanged
        case readBack
        case readBackMismatch
    }

    struct PersistentMCPUpdateResult {
        let status: PersistentMCPUpdateStatus
        let wasRepoPromptServerPresent: Bool
        let degradations: [ExternalMCPDegradation]
    }

    /// The result of a Settings-owned external connection registration. This is deliberately
    /// separate from global external-config import: disconnect may only remove an exact region
    /// that RepoPrompt Settings created and subsequently verified.
    enum SettingsManagedMCPUpdateStatus: Equatable {
        case updated
        case unchanged
        case cancelled
        case failed(SettingsManagedMCPUpdateFailure)
    }

    enum SettingsManagedMCPUpdateFailure: Equatable {
        case runtimePreparation
        case managedRead
        case unsafeMarkers
        case unrecognizedOwnedRegion
        case serverNameConflict
        case targetChanged
        case managedWrite
        case readBack
        case readBackMismatch
    }

    /// Structural, nonsecret inspection used by Settings before it offers a user-owned
    /// Figma block for adoption. It deliberately does not expose its TOML content, URL,
    /// headers, or any OAuth data.
    enum ExistingFigmaServerInspection: Equatable {
        case absent
        case imported
        case canonicalImported(isEnabled: Bool)
        case canonicalExplicitlyDisabled
        case conflictingAlias
        case settingsManaged
        case unsafe
    }

    /// Exposes whether the caller must retain a nonsecret cleanup/retry tombstone. A failed
    /// read-back or cancellation after rename may have changed the file even though the
    /// transaction cannot safely publish a completed connection state.
    enum SettingsManagedMCPRecovery: Equatable {
        case none
        case replacementMayHaveCommitted
    }

    struct SettingsManagedMCPUpdateResult: Equatable {
        let status: SettingsManagedMCPUpdateStatus
        let hasSettingsManagedFigma: Bool
        let recovery: SettingsManagedMCPRecovery

        init(
            status: SettingsManagedMCPUpdateStatus,
            hasSettingsManagedFigma: Bool,
            recovery: SettingsManagedMCPRecovery = .none
        ) {
            self.status = status
            self.hasSettingsManagedFigma = hasSettingsManagedFigma
            self.recovery = recovery
        }
    }

    private struct MCPServerBlock {
        let entry: ServerEntry
        let lines: [String]
    }

    struct PersistentMCPConfigMutationResult {
        let content: String
        let changed: Bool
        let wasRepoPromptServerPresent: Bool
        let conflictMessage: String?
    }

    private struct BlockRange {
        var start: Int
        var end: Int
    }

    private struct TOMLKeyComponent {
        let raw: String
        let normalized: String
    }

    private struct TOMLHeader {
        let keyPath: [TOMLKeyComponent]
        let isArrayTable: Bool
    }

    private struct TOMLAssignment {
        let keyPath: [TOMLKeyComponent]
        let valueText: Substring

        func isSingleKey(_ key: String) -> Bool {
            keyPath.count == 1 && keyPath[0].normalized == key
        }
    }

    struct ToolTimeoutMutationResult {
        let content: String
        let changed: Bool
        let foundTarget: Bool
    }

    /// Codex config overrides for headless agent runs.
    /// Returns array of "-c" flag arguments.
    static func configOverrides(for context: AgentCLIToolContext) -> [String] {
        let toolPolicy = switch context {
        case .agentRun, .discoverRun, .promptOnly:
            CodexOverrides.ToolPolicy(
                toolOutputTokenLimit: desiredToolOutputTokenLimit,
                shellToolEnabled: false,
                webSearchRequestEnabled: false
            )
        case .terminal:
            CodexOverrides.ToolPolicy(
                toolOutputTokenLimit: desiredToolOutputTokenLimit,
                shellToolEnabled: nil,
                webSearchRequestEnabled: nil
            )
        }

        return CodexOverrides.cliConfigArgs(toolPolicy: toolPolicy)
    }

    static func configDirectoryURL() -> URL {
        CodexRuntimeAuthority.statePaths().codexHome
    }

    static func configURL() -> URL {
        configDirectoryURL().appendingPathComponent("config.toml")
    }

    /// The normal, user-owned Codex config. RepoPrompt never writes this file; it mirrors only
    /// MCP server definitions into its own state home so the bundled runtime can retain isolation.
    static func externalUserConfigURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    /// GUI-hosted processes can report a container-style Foundation home while the user's normal
    /// Codex configuration follows the login-shell HOME. Probe all non-mutating candidates in a
    /// deterministic order; the first readable config wins.
    static func externalUserConfigURLs(fileManager: FileManager = .default) -> [URL] {
        var homes: [URL] = []
        if let value = ProcessInfo.processInfo.environment["HOME"], !value.isEmpty {
            homes.append(URL(fileURLWithPath: value, isDirectory: true))
        }
        homes.append(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        homes.append(fileManager.homeDirectoryForCurrentUser)

        var seen = Set<URL>()
        return homes.compactMap { home in
            let url = home
                .standardizedFileURL
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("config.toml")
            return seen.insert(url).inserted ? url : nil
        }
    }

    static func cliPathComponent(forNormalizedServerName name: String) -> String {
        guard !name.isEmpty else { return "\"\"" }
        if name.unicodeScalars.allSatisfy({ tomlBareKeyCharacters.contains($0) }) {
            return name
        }

        var escaped = ""
        escaped.reserveCapacity(name.count)
        for scalar in name.unicodeScalars {
            let character = Character(scalar)
            switch character {
            case "\"":
                escaped.append("\\\"")
            case "\\":
                escaped.append("\\\\")
            case "\n":
                escaped.append("\\n")
            case "\r":
                escaped.append("\\r")
            case "\t":
                escaped.append("\\t")
            default:
                escaped.append(character)
            }
        }

        return "\"\(escaped)\""
    }

    enum ManagedMCPConfigReadOutcome: Equatable {
        case missing
        case unreadable
        case malformed
        case valid([ServerEntry])
    }

    /// Explicitly models isolated-config read failures for callers that must decide whether
    /// provisioning can proceed. The legacy array adapter remains only for non-authoritative
    /// UI discovery; it never uses `fileExists`/`try?` to collapse state before this boundary.
    static func managedMCPConfigReadOutcome(at url: URL = configURL()) -> ManagedMCPConfigReadOutcome {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
        guard isolatedMCPConfigIsStructurallyValid(content) else { return .malformed }
        return .valid(mcpServerEntries(fromConfigContent: content))
    }

    static func mcpServerEntries() -> [ServerEntry] {
        switch managedMCPConfigReadOutcome() {
        case let .valid(entries): entries
        case .missing, .unreadable, .malformed: []
        }
    }

    static func mcpServerEntries(from content: String) -> [ServerEntry] {
        mcpServerEntries(fromConfigContent: content)
    }

    static func mcpServerEntries(fromConfigContent content: String) -> [ServerEntry] {
        mcpServerBlocks(fromConfigContent: content).map(\.entry)
    }

    static func mcpServerNames() -> [String] {
        mcpServerEntries().map(\.normalizedName)
    }

    /// Installs the RepoPrompt MCP server into RepoPrompt's isolated Codex config.
    ///
    /// Invoked from the UI when users opt-in to the integration. Ensures our MCP server exists and is
    /// enabled globally so Codex can use it outside of discovery runs.
    @discardableResult
    static func installPersistentMCPConfig(
        launchSnapshot: CodexRuntimeAuthority.LaunchSnapshot? = nil
    ) -> (success: Bool, wasAlreadyPresent: Bool, errorMessage: String?) {
        let runtime: CodexRuntimeAuthority.Runtime
        switch CodexRuntimeAuthority.resolveConfigured(
            launchSnapshot: launchSnapshot ?? CodexRuntimeAuthority.currentLaunchSnapshot()
        ) {
        case let .success(resolved):
            runtime = resolved
        case .failure:
            return (false, false, "RepoPrompt could not resolve its bundled Codex runtime.")
        }

        fileLock.lock()
        defer { fileLock.unlock() }

        let fm = FileManager.default
        // Use the same isolated CODEX_HOME as the runtime that will be launched; this must
        // happen before Codex starts MCP discovery.
        let configURL = runtime.statePaths.codexHome.appendingPathComponent("config.toml")

        do {
            try runtime.prepareState(fileManager: fm)
        } catch {
            return (false, false, "RepoPrompt could not prepare its isolated Codex state.")
        }

        let result = reconcilePersistentMCPConfig(
            at: configURL,
            externalCandidates: externalUserConfigURLs(fileManager: fm),
            mode: .install,
            dependencies: .live(fileManager: fm)
        )
        return legacyProvisioningResult(result)
    }

    /// Ensures only the app-owned RepoPrompt MCP server exists for discovery runs. This
    /// boundary is used by fresh Agent Mode startup; Figma/external reconciliation belongs
    /// to the app-lifetime Figma coordinator.
    @discardableResult
    static func ensureRepoPromptServerForDiscovery() -> (success: Bool, wasAlreadyPresent: Bool, errorMessage: String?) {
        switch CodexRuntimeAuthority.resolve() {
        case let .success(resolved):
            ensureRepoPromptServerForDiscovery(runtime: resolved)
        case .failure:
            (false, false, "RepoPrompt could not resolve its bundled Codex runtime.")
        }
    }

    @discardableResult
    static func ensureRepoPromptServerForDiscovery(
        runtime: CodexRuntimeAuthority.Runtime
    ) -> (success: Bool, wasAlreadyPresent: Bool, errorMessage: String?) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let configURL = runtime.statePaths.codexHome.appendingPathComponent("config.toml")
        do { try runtime.prepareState(fileManager: FileManager.default) }
        catch { return (false, false, "RepoPrompt could not prepare its isolated Codex state.") }
        let result = reconcilePersistentMCPConfig(
            at: configURL,
            externalCandidates: [],
            mode: .repoPromptOnly,
            dependencies: .live(fileManager: FileManager.default)
        )
        return legacyProvisioningResult(result)
    }

    /// Ensures the RepoPrompt MCP server exists for discovery runs. Newly created entries default to
    /// `enabled = false` so normal Codex usage stays opt-in, while the agent enables it at runtime via
    /// `-c` overrides.
    @discardableResult
    static func ensureServerForDiscovery(
        launchSnapshot: CodexRuntimeAuthority.LaunchSnapshot? = nil
    ) -> (success: Bool, wasAlreadyPresent: Bool, errorMessage: String?) {
        switch CodexRuntimeAuthority.resolveConfigured(
            launchSnapshot: launchSnapshot ?? CodexRuntimeAuthority.currentLaunchSnapshot()
        ) {
        case let .success(resolved):
            ensureServerForDiscovery(runtime: resolved)
        case .failure:
            (false, false, "RepoPrompt could not resolve its bundled Codex runtime.")
        }
    }

    @discardableResult
    static func ensureServerForDiscovery(
        runtime: CodexRuntimeAuthority.Runtime
    ) -> (success: Bool, wasAlreadyPresent: Bool, errorMessage: String?) {
        fileLock.lock()
        defer { fileLock.unlock() }

        let fm = FileManager.default
        // Keep the merge bound to the exact runtime state that will become CODEX_HOME
        // for the process launched immediately after this gate.
        let configURL = runtime.statePaths.codexHome.appendingPathComponent("config.toml")

        do {
            try runtime.prepareState(fileManager: fm)
        } catch {
            return (false, false, "RepoPrompt could not prepare its isolated Codex state.")
        }

        let result = reconcilePersistentMCPConfig(
            at: configURL,
            externalCandidates: externalUserConfigURLs(fileManager: fm),
            mode: .discovery,
            dependencies: .live(fileManager: fm)
        )
        return legacyProvisioningResult(result)
    }

    private static func managedExternalRegionIsPreserved(
        from original: String,
        through updated: String,
        degradations: [ExternalMCPDegradation]
    ) -> Bool {
        guard !degradations.isEmpty else { return true }
        let originalLines = splitTOMLLines(original)
        switch classifyManagedExternalMCPRegion(in: originalLines) {
        case .absent:
            return true
        case .malformed:
            return original == updated
        case let .valid(originalRange):
            let updatedLines = splitTOMLLines(updated)
            guard case let .valid(updatedRange) = classifyManagedExternalMCPRegion(in: updatedLines) else {
                return false
            }
            return Array(originalLines[originalRange]) == Array(updatedLines[updatedRange])
        }
    }

    static func reconcilePersistentMCPConfig(
        at managedConfigURL: URL,
        externalCandidates: [URL],
        mode: PersistentMCPUpdateMode,
        dependencies: ProvisioningDependencies
    ) -> PersistentMCPUpdateResult {
        dependencies.diagnostics.record("provisioning attempt started")
        if dependencies.cancellation.isCancelled() {
            return PersistentMCPUpdateResult(status: .cancelled, wasRepoPromptServerPresent: false, degradations: [])
        }

        let original: String
        do {
            original = try dependencies.managedStore.readUTF8(managedConfigURL) ?? ""
        } catch {
            dependencies.diagnostics.record("managed Codex config read failed")
            return PersistentMCPUpdateResult(status: .failed(.managedRead), wasRepoPromptServerPresent: false, degradations: [])
        }
        let originalFingerprint: ConfigurationFileFingerprint?
        do {
            originalFingerprint = try dependencies.managedStore.fingerprint?(managedConfigURL)
        } catch {
            dependencies.diagnostics.record("managed Codex config fingerprint failed")
            return PersistentMCPUpdateResult(status: .failed(.managedRead), wasRepoPromptServerPresent: false, degradations: [])
        }
        let originalMarkers = classifyManagedExternalMCPRegion(in: splitTOMLLines(original))
        dependencies.diagnostics.record(
            "managed config read; byte_count=\(original.utf8.count); marker_state=\(diagnosticMarkerState(originalMarkers))"
        )
        let wasPresent = mcpServerEntries(from: original).contains { $0.normalizedName == repoPromptMCPServerName }
        if dependencies.cancellation.isCancelled() {
            return PersistentMCPUpdateResult(status: .cancelled, wasRepoPromptServerPresent: wasPresent, degradations: [])
        }

        let source: ExternalMCPSourceOutcome = if mode == .repoPromptOnly {
            // Do not touch external source files during fresh Agent Mode bootstrap.
            .absent
        } else {
            resolveExternalMCPSource(
                candidates: externalCandidates,
                excluding: managedConfigURL,
                reader: dependencies.sourceReader,
                diagnostics: dependencies.diagnostics,
                cancellation: dependencies.cancellation
            )
        }
        if dependencies.cancellation.isCancelled() {
            return PersistentMCPUpdateResult(status: .cancelled, wasRepoPromptServerPresent: wasPresent, degradations: [])
        }
        let merged: ExternalMCPMergeResult = if mode == .repoPromptOnly {
            // Preserve the existing managed external region byte-for-byte. Only the
            // RepoPromptCE entry may be added/updated below.
            .init(content: original, changed: false, importedServerNames: [], skippedConflictingServerNames: [], degradations: [])
        } else {
            mergedExternalMCPServerConfigContent(from: original, sourceOutcome: source)
        }
        dependencies.diagnostics.record(
            "external MCP merge completed; changed=\(merged.changed); imported_count=\(merged.importedServerNames.count); figma_present=\(merged.importedServerNames.contains("figma")); degradation_count=\(merged.degradations.count)"
        )
        for degradation in merged.degradations {
            switch degradation {
            case .sourceUnavailable:
                dependencies.diagnostics.record("external MCP import unavailable; preserving prior valid region")
            case .sourceChanged:
                dependencies.diagnostics.record("external MCP source changed during inspection; preserving prior valid region")
            case .sourceInvalid:
                dependencies.diagnostics.record("external MCP import malformed; preserving prior valid region")
            case let .malformedMarkers(problem):
                dependencies.diagnostics.record("managed external MCP markers malformed: \(problem.rawValue)")
            }
        }

        let installMode = switch mode {
        case .install: true
        case .discovery, .repoPromptOnly: false
        }
        let mutation = mutatedPersistentMCPConfigContent(
            from: merged.content,
            defaultEnabledIfMissing: installMode,
            forceEnabled: installMode ? true : nil
        )
        if let conflict = mutation.conflictMessage {
            dependencies.diagnostics.record("managed config policy conflict; reason=\(conflict)")
            return PersistentMCPUpdateResult(
                status: .failed(.policyConflict(conflict)),
                wasRepoPromptServerPresent: mutation.wasRepoPromptServerPresent,
                degradations: merged.degradations
            )
        }
        if !managedExternalRegionIsPreserved(
            from: original,
            through: mutation.content,
            degradations: merged.degradations
        ) {
            dependencies.diagnostics.record("managed external MCP region could not be preserved safely")
            return PersistentMCPUpdateResult(
                status: .failed(.unsafeManagedMarkers),
                wasRepoPromptServerPresent: wasPresent,
                degradations: merged.degradations
            )
        }
        if dependencies.cancellation.isCancelled() {
            return PersistentMCPUpdateResult(status: .cancelled, wasRepoPromptServerPresent: wasPresent, degradations: merged.degradations)
        }
        guard merged.changed || mutation.changed else {
            dependencies.diagnostics.record("managed config unchanged; no replacement required")
            UserDefaults.standard.set(true, forKey: toolTimeoutDefaultsKey)
            return PersistentMCPUpdateResult(status: .unchanged, wasRepoPromptServerPresent: wasPresent, degradations: merged.degradations)
        }

        if let originalFingerprint {
            do {
                guard try dependencies.managedStore.fingerprint?(managedConfigURL) == originalFingerprint else {
                    dependencies.diagnostics.record("managed Codex config changed before replacement")
                    return PersistentMCPUpdateResult(status: .failed(.targetChanged), wasRepoPromptServerPresent: wasPresent, degradations: merged.degradations)
                }
            } catch {
                dependencies.diagnostics.record("managed Codex config fingerprint failed before replacement")
                return PersistentMCPUpdateResult(status: .failed(.targetChanged), wasRepoPromptServerPresent: wasPresent, degradations: merged.degradations)
            }
        }
        if dependencies.cancellation.isCancelled() {
            return PersistentMCPUpdateResult(status: .cancelled, wasRepoPromptServerPresent: wasPresent, degradations: merged.degradations)
        }
        dependencies.diagnostics.record("managed config atomic replacement starting; byte_count=\(mutation.content.utf8.count)")
        do {
            try dependencies.managedStore.replaceAtomically(mutation.content, managedConfigURL)
        } catch {
            dependencies.diagnostics.record("managed Codex config atomic replacement failed")
            return PersistentMCPUpdateResult(status: .failed(.managedWrite), wasRepoPromptServerPresent: wasPresent, degradations: merged.degradations)
        }
        // A cancellation after rename cannot roll back a completed atomic replacement; verify
        // its bytes first, then report cancellation so callers do not publish stale success.
        let cancelledDuringCommit = dependencies.cancellation.isCancelled()
        let readBack: Data
        do {
            readBack = try dependencies.managedStore.readBack(managedConfigURL)
        } catch {
            dependencies.diagnostics.record("managed Codex config read-back failed")
            return PersistentMCPUpdateResult(status: .failed(.readBack), wasRepoPromptServerPresent: wasPresent, degradations: merged.degradations)
        }
        guard readBack == Data(mutation.content.utf8) else {
            dependencies.diagnostics.record("managed Codex config read-back mismatch")
            return PersistentMCPUpdateResult(status: .failed(.readBackMismatch), wasRepoPromptServerPresent: wasPresent, degradations: merged.degradations)
        }
        if cancelledDuringCommit {
            dependencies.diagnostics.record("managed config replacement completed after cancellation")
            return PersistentMCPUpdateResult(status: .cancelled, wasRepoPromptServerPresent: wasPresent, degradations: merged.degradations)
        }
        let committedNames = mcpServerEntries(fromConfigContent: mutation.content).map(\.normalizedName).sorted()
        dependencies.diagnostics.record(
            "managed config committed and verified; server_count=\(committedNames.count); figma_present=\(committedNames.contains("figma"))"
        )
        UserDefaults.standard.set(true, forKey: toolTimeoutDefaultsKey)
        return PersistentMCPUpdateResult(status: .updated, wasRepoPromptServerPresent: wasPresent, degradations: merged.degradations)
    }

    private static func legacyProvisioningResult(
        _ result: PersistentMCPUpdateResult
    ) -> (success: Bool, wasAlreadyPresent: Bool, errorMessage: String?) {
        switch result.status {
        case .updated, .unchanged:
            let warning = result.degradations.isEmpty
                ? nil
                : "RepoPrompt preserved the last safe external MCP configuration because the current import could not be validated."
            return (true, result.wasRepoPromptServerPresent, warning)
        case .cancelled:
            return (false, result.wasRepoPromptServerPresent, "RepoPrompt did not update its isolated Codex config because the operation was cancelled.")
        case let .failed(.policyConflict(message)):
            return (false, result.wasRepoPromptServerPresent, message)
        case .failed(.managedRead):
            return (false, result.wasRepoPromptServerPresent, "RepoPrompt could not read its isolated Codex config.")
        case .failed(.unsafeManagedMarkers):
            return (false, result.wasRepoPromptServerPresent, "RepoPrompt preserved an unsafe external MCP marker layout and did not update the isolated Codex config.")
        case .failed(.managedWrite):
            return (false, result.wasRepoPromptServerPresent, "RepoPrompt could not atomically update its isolated Codex config.")
        case .failed(.targetChanged):
            return (false, result.wasRepoPromptServerPresent, "RepoPrompt did not overwrite an isolated Codex config that changed during provisioning.")
        case .failed(.readBack), .failed(.readBackMismatch):
            return (false, result.wasRepoPromptServerPresent, "RepoPrompt could not verify its isolated Codex config update.")
        }
    }

    static func mutatedPersistentMCPConfigContent(
        from content: String,
        defaultEnabledIfMissing: Bool,
        forceEnabled: Bool?,
        supportsDirectOnlyToolNamespaces: Bool = true
    ) -> PersistentMCPConfigMutationResult {
        var lines = splitTOMLLines(content)
        if let conflictMessage = codeModePolicyConflict(
            in: lines,
            supportsDirectOnlyToolNamespaces: supportsDirectOnlyToolNamespaces
        ) {
            return PersistentMCPConfigMutationResult(
                content: content,
                changed: false,
                wasRepoPromptServerPresent: mcpServerEntries(from: content).contains { $0.normalizedName == repoPromptMCPServerName },
                conflictMessage: conflictMessage
            )
        }
        let ensureResult = ensureRepoPromptServer(
            in: &lines,
            defaultEnabledIfMissing: defaultEnabledIfMissing,
            forceEnabled: forceEnabled
        )

        _ = stripToolOutputLimitFromRepoPromptBlocks(in: &lines)
        _ = ensureGlobalToolOutputLimit(in: &lines)
        _ = ensureCodeModePolicy(in: &lines)

        let final = lines.joined(separator: "\n")
        return PersistentMCPConfigMutationResult(
            content: final,
            changed: final != content,
            wasRepoPromptServerPresent: ensureResult.wasPresent,
            conflictMessage: nil
        )
    }

    static func configContainsRepoPrompt() -> Bool {
        mcpServerEntries().contains {
            $0.normalizedName == repoPromptMCPServerName
        }
    }

    static func removeInstallEntry() {
        fileLock.lock()
        defer { fileLock.unlock() }

        let configURL = configURL()
        let content: String
        do {
            content = try String(contentsOf: configURL, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            provisioningLogger.error("managed Codex config read failed while removing owned entry")
            return
        }

        var lines = splitTOMLLines(content)
        let blocks = blockRanges(in: lines, whereHeaderMatches: isRepoPromptMCPServerHeader)
        guard !blocks.isEmpty else { return }

        removeBlockRanges(blocks, from: &lines)

        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        let final = lines.joined(separator: "\n")
        do {
            try final.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            provisioningLogger.error("managed Codex config write failed while removing owned entry")
        }
    }

    /// Ensures existing Codex CLI configs include the RepoPrompt MCP policy required by V5:
    /// the preserved 10,000-active-second server timeout and enabled parallel tool calls.
    ///
    /// Codex has no per-tool timeout exemption, so lowering this server-wide value would also
    /// truncate synchronous Oracle and Context Builder operations that can legitimately run for hours.
    /// - Parameter force: When true, bypasses the once-per-install guard and rechecks the file.
    /// - Returns: `true` if the RepoPrompt entry was located and now has the desired policy.
    @discardableResult
    static func ensureToolTimeout(force: Bool = false) -> Bool {
        fileLock.lock()
        defer { fileLock.unlock() }

        let defaults = UserDefaults.standard
        if !force, defaults.bool(forKey: toolTimeoutDefaultsKey) {
            return true
        }

        let configURL = configURL()
        let content: String
        do {
            content = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            return false
        }

        let mutation = mutatedToolTimeoutConfigContent(from: content)
        guard mutation.foundTarget else { return false }

        if mutation.changed {
            do {
                try mutation.content.write(to: configURL, atomically: true, encoding: .utf8)
            } catch {
                return false
            }
        }

        defaults.set(true, forKey: toolTimeoutDefaultsKey)
        return true
    }

    static func mutatedToolTimeoutConfigContent(from content: String) -> ToolTimeoutMutationResult {
        var lines = content.components(separatedBy: "\n")
        let desiredCommand = canonicalizedPath(for: serverCommand)

        var sectionStart: Int?
        var isRepoPromptSection = false
        var commandMatches = false
        var foundTarget = false
        var needsWrite = false
        var completed = false

        func resetSectionState(at index: Int, isRepoPrompt: Bool) {
            sectionStart = index
            isRepoPromptSection = isRepoPrompt
            commandMatches = false
        }

        func finalizeSection(before index: Int) {
            guard isRepoPromptSection, commandMatches, !completed else { return }
            foundTarget = true

            if let sectionStart {
                var block = BlockRange(start: sectionStart, end: index)
                if ensureRepoPromptPolicyKeys(in: &lines, blockRange: &block) {
                    needsWrite = true
                }
            }

            completed = true
        }

        var idx = 0
        while idx < lines.count {
            let line = lines[idx]

            if isTOMLHeaderLine(line) {
                finalizeSection(before: idx)
                if completed { break }
                resetSectionState(at: idx, isRepoPrompt: isRepoPromptMCPServerHeader(line))
                idx += 1
                continue
            }

            if isRepoPromptSection,
               let assignment = parseTOMLAssignment(line),
               assignment.isSingleKey("command"),
               let value = parseTOMLStringValue(assignment.valueText)
            {
                if canonicalizedPath(for: value) == desiredCommand {
                    commandMatches = true
                }
            }

            idx += 1
        }

        if !completed {
            finalizeSection(before: lines.count)
        }

        if foundTarget {
            if stripToolOutputLimitFromRepoPromptBlocks(in: &lines) {
                needsWrite = true
            }

            if ensureGlobalToolOutputLimit(in: &lines) {
                needsWrite = true
            }
        }

        let final = lines.joined(separator: "\n")
        return ToolTimeoutMutationResult(content: final, changed: final != content || needsWrite, foundTarget: foundTarget)
    }

    static func ensureToolTimeout(in lines: inout [String]) -> (foundTarget: Bool, changed: Bool) {
        let content = lines.joined(separator: "\n")
        let mutation = mutatedToolTimeoutConfigContent(from: content)
        if mutation.changed {
            lines = mutation.content.components(separatedBy: "\n")
        }
        return (mutation.foundTarget, mutation.changed)
    }

    /// Mirrors externally configured MCP server blocks into the managed Codex home. The source is
    /// intentionally restricted to `[mcp_servers.*]` plus a server's immediately-associated nested
    /// tables (for example `.env`); plugin, profile, auth, shell, and other global configuration is
    /// not copied. OAuth credentials are never read, copied, or logged.
    ///
    /// `RepoPromptCE` is reserved for the app-owned endpoint. If the external config contains that
    /// exact server name, the app-owned entry wins deterministically. A manually authored server in
    /// the managed config likewise wins over an imported server with the same name.
    static func mergedExternalMCPServerConfigContent(
        from managedContent: String,
        externalConfigContent: String
    ) -> ExternalMCPMergeResult {
        mergedExternalMCPServerConfigContent(
            from: managedContent,
            sourceOutcome: externalMCPContentIsStructurallyValid(externalConfigContent)
                ? .valid(content: externalConfigContent, candidateIndex: 0)
                : .invalid(candidateIndex: 0)
        )
    }

    static func mergedExternalMCPServerConfigContent(
        from managedContent: String,
        sourceOutcome: ExternalMCPSourceOutcome
    ) -> ExternalMCPMergeResult {
        var managedLines = splitTOMLLines(managedContent)
        let markerClassification = classifyManagedExternalMCPRegion(in: managedLines)
        if case let .malformed(problem) = markerClassification {
            return ExternalMCPMergeResult(
                content: managedContent,
                changed: false,
                importedServerNames: [],
                skippedConflictingServerNames: [],
                degradations: [.malformedMarkers(problem)]
            )
        }

        switch sourceOutcome {
        case .unavailable:
            return ExternalMCPMergeResult(
                content: managedContent,
                changed: false,
                importedServerNames: [],
                skippedConflictingServerNames: [],
                degradations: [.sourceUnavailable]
            )
        case .changed:
            return ExternalMCPMergeResult(
                content: managedContent,
                changed: false,
                importedServerNames: [],
                skippedConflictingServerNames: [],
                degradations: [.sourceChanged]
            )
        case .invalid:
            return ExternalMCPMergeResult(
                content: managedContent,
                changed: false,
                importedServerNames: [],
                skippedConflictingServerNames: [],
                degradations: [.sourceInvalid]
            )
        case .absent:
            if case let .valid(range) = markerClassification {
                managedLines.removeSubrange(range)
            }
            let content = managedLines.joined(separator: "\n")
            return ExternalMCPMergeResult(
                content: content,
                changed: content != managedContent,
                importedServerNames: [],
                skippedConflictingServerNames: [],
                degradations: []
            )
        case let .valid(externalConfigContent, _):
            let insertionIndex: Int
            if case let .valid(range) = markerClassification {
                insertionIndex = range.lowerBound
                managedLines.removeSubrange(range)
            } else {
                insertionIndex = managedLines.count
            }

            let existingNames = Set(mcpServerBlocks(fromLines: managedLines).map(\.entry.normalizedName))
            let externalBlocks = mcpServerBlocks(fromConfigContent: externalConfigContent)
            var imports: [MCPServerBlock] = []
            var importedNames: [String] = []
            var skippedNames: [String] = []
            var seenExternalNames = Set<String>()

            for block in externalBlocks {
                let name = block.entry.normalizedName
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seenExternalNames.insert(name).inserted
                else { continue }
                if name == repoPromptMCPServerName || existingNames.contains(name) {
                    skippedNames.append(name)
                    continue
                }
                imports.append(block)
                importedNames.append(name)
            }

            if !imports.isEmpty {
                let region = managedExternalMCPRegionLines(for: imports)
                if insertionIndex < managedLines.count {
                    managedLines.insert(contentsOf: region, at: insertionIndex)
                } else {
                    appendBlock(region, to: &managedLines)
                }
            }

            let content = managedLines.joined(separator: "\n")
            return ExternalMCPMergeResult(
                content: content,
                changed: content != managedContent,
                importedServerNames: importedNames,
                skippedConflictingServerNames: skippedNames,
                degradations: []
            )
        }
    }

    /// Serializes a Settings-owned registration against the normal isolated-config merger.
    /// The optional runtime is supplied by a process-bound caller to guarantee the exact
    /// `CODEX_HOME` that will be spawned; Settings actions may resolve it independently.
    static func reconcileSettingsManagedFigmaConnection(
        definition: ExternalMCPIntegrationDefinition?,
        runtime: CodexRuntimeAuthority.Runtime? = nil,
        dependencies: ProvisioningDependencies = .live()
    ) -> SettingsManagedMCPUpdateResult {
        let resolvedRuntime: CodexRuntimeAuthority.Runtime
        if let runtime {
            resolvedRuntime = runtime
        } else {
            switch CodexRuntimeAuthority.resolveConfigured() {
            case let .success(value): resolvedRuntime = value
            case .failure:
                return .init(status: .failed(.runtimePreparation), hasSettingsManagedFigma: false)
            }
        }
        fileLock.lock()
        defer { fileLock.unlock() }
        do {
            try resolvedRuntime.prepareState()
        } catch {
            return .init(status: .failed(.runtimePreparation), hasSettingsManagedFigma: false)
        }
        return reconcileSettingsManagedFigmaConnection(
            at: resolvedRuntime.statePaths.codexHome.appendingPathComponent("config.toml"),
            definition: definition,
            dependencies: dependencies
        )
    }

    /// Resolves and prepares the standard isolated runtime before inspecting it. This mirrors
    /// Settings-managed reconciliation without importing any global configuration or changing
    /// a managed file.
    static func inspectExistingFigmaServer(
        runtime: CodexRuntimeAuthority.Runtime? = nil,
        dependencies: ProvisioningDependencies = .live()
    ) -> ExistingFigmaServerInspection {
        let resolvedRuntime: CodexRuntimeAuthority.Runtime
        if let runtime {
            resolvedRuntime = runtime
        } else {
            switch CodexRuntimeAuthority.resolveConfigured() {
            case let .success(value): resolvedRuntime = value
            case .failure: return .unsafe
            }
        }
        fileLock.lock()
        defer { fileLock.unlock() }
        do {
            try resolvedRuntime.prepareState()
        } catch {
            return .unsafe
        }
        return inspectExistingFigmaServer(
            at: resolvedRuntime.statePaths.codexHome.appendingPathComponent("config.toml"),
            dependencies: dependencies
        )
    }

    /// Inspects only the isolated managed configuration for an existing canonical Figma
    /// server. This is intentionally a read-only adoption gate: Settings must never create a
    /// managed block merely to find out whether a user/imported Figma block exists.
    static func inspectExistingFigmaServer(
        at managedConfigURL: URL,
        dependencies: ProvisioningDependencies
    ) -> ExistingFigmaServerInspection {
        guard !dependencies.cancellation.isCancelled() else { return .unsafe }
        let content: String
        do {
            content = try dependencies.managedStore.readUTF8(managedConfigURL) ?? ""
        } catch {
            dependencies.diagnostics.record("settings-managed MCP adoption inspection failed")
            return .unsafe
        }
        let lines = splitTOMLLines(content)
        switch classifySettingsManagedMCPRegion(in: lines) {
        case .absent:
            break
        case let .valid(range):
            return settingsManagedFigmaRegionIsExact(Array(lines[range])) ? .settingsManaged : .unsafe
        case .malformed:
            return .unsafe
        }
        let entries = mcpServerBlocks(fromLines: lines).map(\.entry)
        if let canonical = entries.first(where: { $0.identity == .canonicalFigma }) {
            return canonical.isExplicitlyDisabled ? .canonicalExplicitlyDisabled : .canonicalImported(isEnabled: canonical.isEnabled)
        }
        if entries.contains(where: { $0.identity == .figmaAlias }) {
            return .conflictingAlias
        }
        return .absent
    }

    /// Reconciles the one Settings-owned Figma registration in RepoPrompt's isolated Codex
    /// configuration. It never reads global configuration and never accepts a caller-provided
    /// URL, headers, command, arguments, or credentials. A manually/imported `figma` block is
    /// a conflict rather than something Settings may overwrite; disconnect only removes the
    /// byte-exact region this routine writes.
    static func reconcileSettingsManagedFigmaConnection(
        at managedConfigURL: URL,
        definition: ExternalMCPIntegrationDefinition?,
        dependencies: ProvisioningDependencies
    ) -> SettingsManagedMCPUpdateResult {
        if dependencies.cancellation.isCancelled() {
            return .init(status: .cancelled, hasSettingsManagedFigma: false)
        }

        let original: String
        do {
            original = try dependencies.managedStore.readUTF8(managedConfigURL) ?? ""
        } catch {
            dependencies.diagnostics.record("settings-managed MCP config read failed")
            return .init(status: .failed(.managedRead), hasSettingsManagedFigma: false)
        }

        let originalFingerprint: ConfigurationFileFingerprint?
        do {
            originalFingerprint = try dependencies.managedStore.fingerprint?(managedConfigURL)
        } catch {
            dependencies.diagnostics.record("settings-managed MCP config fingerprint failed")
            return .init(status: .failed(.managedRead), hasSettingsManagedFigma: false)
        }

        var lines = splitTOMLLines(original)
        let markerClassification = classifySettingsManagedMCPRegion(in: lines)
        let isAdoptingImport = definition?.isSupportedDefinition == true && definition?.origin == .adoptedImport
        let shouldRegister = definition?.isSupportedSettingsManagedDefinition == true
        let existingOwnedRange: Range<Int>?
        switch markerClassification {
        case .absent:
            existingOwnedRange = nil
        case let .valid(range):
            guard settingsManagedFigmaRegionIsExact(Array(lines[range])) else {
                dependencies.diagnostics.record("settings-managed MCP region is not recognized")
                return .init(status: .failed(.unrecognizedOwnedRegion), hasSettingsManagedFigma: false)
            }
            existingOwnedRange = range
        case .malformed:
            dependencies.diagnostics.record("settings-managed MCP markers are unsafe")
            return .init(status: .failed(.unsafeMarkers), hasSettingsManagedFigma: false)
        }

        if dependencies.cancellation.isCancelled() {
            return .init(status: .cancelled, hasSettingsManagedFigma: existingOwnedRange != nil)
        }

        if isAdoptingImport {
            // Adoption records user policy only. It never copies, overwrites, or deletes an
            // imported/user-owned server. A Settings-owned marker is a distinct identity and
            // cannot be silently reclassified as an import.
            guard existingOwnedRange == nil,
                  mcpServerBlocks(fromLines: lines).contains(where: {
                      $0.entry.identity == .canonicalFigma && $0.entry.isEnabled
                  })
            else {
                dependencies.diagnostics.record("adopted MCP import was not an exact existing Figma server")
                return .init(status: .failed(.serverNameConflict), hasSettingsManagedFigma: false)
            }
            return .init(status: .unchanged, hasSettingsManagedFigma: false)
        }

        if let existingOwnedRange {
            lines.removeSubrange(existingOwnedRange)
        }
        if shouldRegister {
            let hasConflictingFigma = mcpServerBlocks(fromLines: lines).contains {
                $0.entry.identity == .canonicalFigma || $0.entry.identity == .figmaAlias
            }
            guard !hasConflictingFigma else {
                dependencies.diagnostics.record("settings-managed MCP server name conflict")
                return .init(status: .failed(.serverNameConflict), hasSettingsManagedFigma: existingOwnedRange != nil)
            }
            appendBlock(settingsManagedFigmaRegionLines(), to: &lines)
        }

        let updated = lines.joined(separator: "\n")
        guard updated != original else {
            return .init(status: .unchanged, hasSettingsManagedFigma: shouldRegister)
        }
        if dependencies.cancellation.isCancelled() {
            return .init(status: .cancelled, hasSettingsManagedFigma: existingOwnedRange != nil)
        }

        if let originalFingerprint {
            do {
                guard try dependencies.managedStore.fingerprint?(managedConfigURL) == originalFingerprint else {
                    dependencies.diagnostics.record("settings-managed MCP config changed before replacement")
                    return .init(status: .failed(.targetChanged), hasSettingsManagedFigma: existingOwnedRange != nil)
                }
            } catch {
                dependencies.diagnostics.record("settings-managed MCP config fingerprint failed before replacement")
                return .init(status: .failed(.targetChanged), hasSettingsManagedFigma: existingOwnedRange != nil)
            }
        }
        if dependencies.cancellation.isCancelled() {
            return .init(status: .cancelled, hasSettingsManagedFigma: existingOwnedRange != nil)
        }

        do {
            try dependencies.managedStore.replaceAtomically(updated, managedConfigURL)
        } catch {
            dependencies.diagnostics.record("settings-managed MCP config replacement failed")
            return .init(status: .failed(.managedWrite), hasSettingsManagedFigma: existingOwnedRange != nil, recovery: .replacementMayHaveCommitted)
        }
        let cancelledDuringCommit = dependencies.cancellation.isCancelled()
        let readBack: Data
        do {
            readBack = try dependencies.managedStore.readBack(managedConfigURL)
        } catch {
            dependencies.diagnostics.record("settings-managed MCP config read-back failed")
            return .init(status: .failed(.readBack), hasSettingsManagedFigma: shouldRegister, recovery: .replacementMayHaveCommitted)
        }
        guard readBack == Data(updated.utf8) else {
            dependencies.diagnostics.record("settings-managed MCP config read-back did not match")
            return .init(status: .failed(.readBackMismatch), hasSettingsManagedFigma: shouldRegister, recovery: .replacementMayHaveCommitted)
        }
        if cancelledDuringCommit {
            dependencies.diagnostics.record("settings-managed MCP replacement completed after cancellation")
            return .init(status: .cancelled, hasSettingsManagedFigma: shouldRegister, recovery: .replacementMayHaveCommitted)
        }
        dependencies.diagnostics.record("settings-managed MCP configuration updated; figma_registered=\(shouldRegister)")
        return .init(status: .updated, hasSettingsManagedFigma: shouldRegister)
    }

    private static func classifySettingsManagedMCPRegion(
        in lines: [String]
    ) -> ManagedExternalMCPMarkerClassification {
        let normalized = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let begins = normalized.indices.filter { normalized[$0] == settingsManagedMCPBeginMarker }
        let ends = normalized.indices.filter { normalized[$0] == settingsManagedMCPEndMarker }
        if begins.count > 1 { return .malformed(.duplicateBegin) }
        if ends.count > 1 { return .malformed(.duplicateEnd) }
        if begins.isEmpty, ends.isEmpty { return .absent }
        if begins.isEmpty { return .malformed(.orphanEnd) }
        if ends.isEmpty { return .malformed(.orphanBegin) }
        guard let begin = begins.first, let end = ends.first, begin < end else {
            return .malformed(.reversed)
        }
        let inner = Array(lines[(begin + 1) ..< end])
        guard managedExternalMCPRegionIsStructurallyValid(inner) else {
            return .malformed(.invalidRegion)
        }
        return .valid(begin ..< (end + 1))
    }

    private static func settingsManagedFigmaRegionLines() -> [String] {
        [
            settingsManagedMCPBeginMarker,
            "",
            "[mcp_servers.figma]",
            "url = \"\(settingsManagedFigmaURL)\"",
            "",
            settingsManagedMCPEndMarker
        ]
    }

    private static func settingsManagedFigmaRegionIsExact(_ lines: [String]) -> Bool {
        let normalized = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        return normalized == settingsManagedFigmaRegionLines()
    }

    static func resolveExternalMCPSource(
        candidates: [URL],
        excluding managedConfigURL: URL,
        reader: ExternalConfigSourceReader,
        diagnostics: ProvisioningDiagnosticSink,
        cancellation: CancellationCheckpoint
    ) -> ExternalMCPSourceOutcome {
        var sawUnreadableCandidate = false
        for (index, sourceURL) in candidates.enumerated() {
            if cancellation.isCancelled() { return .unavailable }
            guard sourceURL.standardizedFileURL != managedConfigURL.standardizedFileURL else { continue }
            do {
                let fingerprintBefore = try reader.fingerprint?(sourceURL)
                guard let content = try reader.readUTF8(sourceURL) else { continue }
                let fingerprintAfter = try reader.fingerprint?(sourceURL)
                if let fingerprintBefore, let fingerprintAfter, fingerprintBefore != fingerprintAfter {
                    diagnostics.record("external MCP source candidate \(index + 1) changed during read")
                    return .changed(candidateIndex: index)
                }
                guard externalMCPContentIsStructurallyValid(content) else {
                    diagnostics.record("external MCP source candidate \(index + 1) is malformed")
                    return .invalid(candidateIndex: index)
                }
                let serverNames = mcpServerEntries(fromConfigContent: content).map(\.normalizedName).sorted()
                diagnostics.record(
                    "selected external MCP source candidate \(index + 1); server_count=\(serverNames.count); figma_present=\(serverNames.contains("figma"))"
                )
                return .valid(content: content, candidateIndex: index)
            } catch {
                sawUnreadableCandidate = true
                diagnostics.record("external MCP source candidate \(index + 1) is unreadable")
            }
        }
        return sawUnreadableCandidate ? .unavailable : .absent
    }

    private static func isolatedMCPConfigIsStructurallyValid(_ content: String) -> Bool {
        for line in splitTOMLLines(content) {
            let trimmed = stripLeadingBOM(from: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[") {
                guard parseTOMLHeader(line) != nil else { return false }
                continue
            }
            // A non-assignment TOML expression cannot be safely associated with a server
            // table. Values themselves remain Codex-owned and are not interpreted here.
            guard parseTOMLAssignment(line) != nil else { return false }
        }
        return true
    }

    /// Validates the only external shape RepoPrompt will mirror: a direct remote MCP
    /// server table containing one HTTPS URL and an optional scalar `enabled` flag.
    /// It deliberately rejects stdio arguments, nested `.env`/headers tables, inline or
    /// dotted assignments, token-like keys, and credential-bearing URLs. The global file is
    /// read-only; rejecting a candidate preserves the last verified imported region instead
    /// of silently importing secrets into RepoPrompt's isolated home.
    private static func externalMCPContentIsStructurallyValid(_ content: String) -> Bool {
        struct ServerValidation {
            let name: String
            var sawURL = false
            var sawEnabled = false
            var urlIsValid = false
        }

        var seenNames = Set<String>()
        var current: ServerValidation?

        func finishCurrent() -> Bool {
            guard let current else { return true }
            return current.sawURL && current.urlIsValid
        }

        for line in splitTOMLLines(content) {
            let trimmed = stripLeadingBOM(from: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") {
                guard let header = parseTOMLHeader(line), !header.isArrayTable else { return false }
                guard finishCurrent() else { return false }
                current = nil
                guard header.keyPath.first?.normalized == "mcp_servers" else { continue }
                // A nested MCP table (including `.env`, `.headers`, or a custom table) is
                // never safe to mirror because it can carry credentials or executable data.
                guard header.keyPath.count == 2 else { return false }
                let name = header.keyPath[1].normalized
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seenNames.insert(name).inserted
                else { return false }
                current = ServerValidation(name: name)
                continue
            }

            guard let assignment = parseTOMLAssignment(line) else { return false }
            guard var server = current else {
                // Dotted `mcp_servers.*` assignments can alter a server without a direct
                // table and are therefore not a supported import form.
                return assignment.keyPath.first?.normalized != "mcp_servers"
            }
            guard assignment.keyPath.count == 1 else { return false }
            switch assignment.keyPath[0].normalized {
            case "url":
                guard !server.sawURL,
                      let endpoint = parseTOMLStringValue(assignment.valueText),
                      isSafeRemoteMCPURL(endpoint)
                else { return false }
                server.sawURL = true
                server.urlIsValid = true
            case "enabled":
                guard !server.sawEnabled,
                      parseTOMLBooleanValue(assignment.valueText) != nil
                else { return false }
                server.sawEnabled = true
            default:
                // This rejects `command`, `args`, `headers`, `token`, `api_key`, and every
                // other unsupported value rather than attempting heuristic redaction.
                return false
            }
            current = server
        }
        return finishCurrent()
    }

    private static func isSafeRemoteMCPURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return false }
        return true
    }

    private static func mcpServerBlocks(fromConfigContent content: String) -> [MCPServerBlock] {
        mcpServerBlocks(fromLines: splitTOMLLines(content))
    }

    private static func mcpServerBlocks(fromLines lines: [String]) -> [MCPServerBlock] {
        var blockIndexByNormalizedName: [String: Int] = [:]
        var blocks: [MCPServerBlock] = []
        var index = 0

        while index < lines.count {
            guard let serverName = mcpServerName(fromHeaderLine: lines[index]) else {
                index += 1
                continue
            }
            guard !serverName.normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                index += 1
                continue
            }

            let directBlockEnd = nextHeaderIndex(after: index + 1, in: lines)
            var groupEnd = directBlockEnd
            while groupEnd < lines.count,
                  let nestedName = nestedMCPServerName(fromHeaderLine: lines[groupEnd]),
                  nestedName.normalized == serverName.normalized
            {
                groupEnd = nextHeaderIndex(after: groupEnd + 1, in: lines)
            }

            defer { index = groupEnd }

            let enablement = enablementState(
                forServerBlockStartingAt: index,
                endingAt: directBlockEnd,
                in: lines
            )
            let entry = ServerEntry(
                rawName: serverName.raw,
                normalizedName: serverName.normalized,
                cliPathComponent: cliPathComponent(forNormalizedServerName: serverName.normalized),
                isEnabled: enablement.isEnabled,
                isExplicitlyDisabled: enablement.isExplicitlyDisabled,
                identity: mcpServerIdentity(
                    for: serverName,
                    directLines: Array(lines[index ..< directBlockEnd])
                )
            )
            let block = MCPServerBlock(entry: entry, lines: Array(lines[index ..< groupEnd]))
            if let existingIndex = blockIndexByNormalizedName[serverName.normalized] {
                if entry.identity == .canonicalFigma,
                   blocks[existingIndex].entry.identity != .canonicalFigma
                {
                    blocks[existingIndex] = block
                }
            } else {
                blockIndexByNormalizedName[serverName.normalized] = blocks.count
                blocks.append(block)
            }
        }

        return blocks
    }

    /// Codex defaults an MCP server to enabled when the scalar is omitted. Malformed or duplicate
    /// values are resolved fail-closed: any invalid/false assignment keeps the server disabled.
    private static func mcpServerIdentity(
        for serverName: TOMLKeyComponent,
        directLines: [String]
    ) -> MCPServerIdentity {
        guard serverName.normalized.lowercased() == settingsManagedFigmaServerName else {
            return .other
        }
        guard serverName.normalized == settingsManagedFigmaServerName else {
            return .figmaAlias
        }
        let urls = directLines.compactMap { line -> String? in
            guard let assignment = parseTOMLAssignment(line), assignment.isSingleKey("url") else { return nil }
            return parseTOMLStringValue(assignment.valueText)
        }
        return urls.contains(where: isCanonicalFigmaMCPURL) ? .canonicalFigma : .figmaAlias
    }

    private static func isCanonicalFigmaMCPURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "mcp.figma.com",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.path == "/mcp",
              components.query == nil,
              components.fragment == nil
        else { return false }
        return true
    }

    private static func enablementState(
        forServerBlockStartingAt start: Int,
        endingAt end: Int,
        in lines: [String]
    ) -> (isEnabled: Bool, isExplicitlyDisabled: Bool) {
        var sawEnabledAssignment = false
        var enabled = true
        guard start + 1 < end else { return (true, false) }
        for index in (start + 1) ..< end {
            guard let assignment = parseTOMLAssignment(lines[index]), assignment.isSingleKey("enabled") else {
                continue
            }
            guard !sawEnabledAssignment else {
                return (false, true)
            }
            sawEnabledAssignment = true
            guard let value = parseTOMLBooleanValue(assignment.valueText) else {
                return (false, true)
            }
            enabled = value
        }
        return sawEnabledAssignment ? (enabled, !enabled) : (true, false)
    }

    private static func diagnosticMarkerState(
        _ classification: ManagedExternalMCPMarkerClassification
    ) -> String {
        switch classification {
        case .absent: "absent"
        case .valid: "valid"
        case let .malformed(problem): "malformed_\(problem.rawValue)"
        }
    }

    static func classifyManagedExternalMCPRegion(
        in lines: [String]
    ) -> ManagedExternalMCPMarkerClassification {
        let normalized = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let begins = normalized.indices.filter { normalized[$0] == managedExternalMCPBeginMarker }
        let ends = normalized.indices.filter { normalized[$0] == managedExternalMCPEndMarker }
        if begins.count > 1 { return .malformed(.duplicateBegin) }
        if ends.count > 1 { return .malformed(.duplicateEnd) }
        if begins.isEmpty, ends.isEmpty { return .absent }
        if begins.isEmpty { return .malformed(.orphanEnd) }
        if ends.isEmpty { return .malformed(.orphanBegin) }
        guard let begin = begins.first, let end = ends.first, begin < end else {
            return .malformed(.reversed)
        }
        let inner = Array(lines[(begin + 1) ..< end])
        guard managedExternalMCPRegionIsStructurallyValid(inner) else {
            return .malformed(.invalidRegion)
        }
        return .valid(begin ..< (end + 1))
    }

    private static func managedExternalMCPRegionIsStructurallyValid(_ lines: [String]) -> Bool {
        let content = lines.joined(separator: "\n")
        return externalMCPContentIsStructurallyValid(content) && !mcpServerBlocks(fromLines: lines).isEmpty
    }

    private static func managedExternalMCPRegionLines(for blocks: [MCPServerBlock]) -> [String] {
        var region = [managedExternalMCPBeginMarker]
        for block in blocks {
            if region.last?.isEmpty == false { region.append("") }
            region.append(contentsOf: block.lines)
        }
        if region.last?.isEmpty == false { region.append("") }
        region.append(managedExternalMCPEndMarker)
        return region
    }

    private static func splitTOMLLines(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        return content.components(separatedBy: "\n")
    }

    private static func parseTOMLHeader(_ line: String) -> TOMLHeader? {
        let text = stripLeadingBOM(from: line)
        var index = text.startIndex
        skipWhitespace(in: text, from: &index)
        guard index < text.endIndex, text[index] == "[" else { return nil }

        let afterOpen = text.index(after: index)
        let isArrayTable = afterOpen < text.endIndex && text[afterOpen] == "["
        let contentStart = isArrayTable ? text.index(after: afterOpen) : afterOpen
        var cursor = contentStart
        var closingStart: String.Index?
        var closingEnd: String.Index?
        var quote: Character?
        var escaped = false

        while cursor < text.endIndex {
            let ch = text[cursor]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                }
                cursor = text.index(after: cursor)
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                cursor = text.index(after: cursor)
                continue
            }

            if ch == "]" {
                let next = text.index(after: cursor)
                if isArrayTable {
                    if next < text.endIndex, text[next] == "]" {
                        closingStart = cursor
                        closingEnd = text.index(after: next)
                        break
                    }
                } else {
                    closingStart = cursor
                    closingEnd = next
                    break
                }
            }

            cursor = text.index(after: cursor)
        }

        guard let closingStart, let closingEnd else { return nil }
        let trailing = text[closingEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }

        let keyText = String(text[contentStart ..< closingStart])
        guard let keyPath = parseTOMLKeyPath(keyText), !keyPath.isEmpty else { return nil }
        return TOMLHeader(keyPath: keyPath, isArrayTable: isArrayTable)
    }

    private static func isTOMLHeaderLine(_ line: String) -> Bool {
        parseTOMLHeader(line) != nil
    }

    private static func mcpServerName(fromHeaderLine line: String) -> TOMLKeyComponent? {
        guard let header = parseTOMLHeader(line), !header.isArrayTable else { return nil }
        guard header.keyPath.count == 2, header.keyPath[0].normalized == "mcp_servers" else { return nil }
        return header.keyPath[1]
    }

    private static func nestedMCPServerName(fromHeaderLine line: String) -> TOMLKeyComponent? {
        guard let header = parseTOMLHeader(line), !header.isArrayTable else { return nil }
        guard header.keyPath.count > 2, header.keyPath[0].normalized == "mcp_servers" else { return nil }
        return header.keyPath[1]
    }

    private static func isRepoPromptMCPServerHeader(_ line: String) -> Bool {
        mcpServerName(fromHeaderLine: line)?.normalized == repoPromptMCPServerName
    }

    private static func parseTOMLAssignment(_ line: String) -> TOMLAssignment? {
        let text = stripLeadingBOM(from: line)
        var index = text.startIndex
        skipWhitespace(in: text, from: &index)
        guard index < text.endIndex, text[index] != "#" else { return nil }

        var cursor = index
        var quote: Character?
        var escaped = false
        while cursor < text.endIndex {
            let ch = text[cursor]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                return nil
            } else if ch == "=" {
                let keyText = String(text[..<cursor])
                guard let keyPath = parseTOMLKeyPath(keyText), !keyPath.isEmpty else { return nil }
                return TOMLAssignment(keyPath: keyPath, valueText: text[text.index(after: cursor)...])
            }
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func parseTOMLKeyPath(_ text: String) -> [TOMLKeyComponent]? {
        let text = stripLeadingBOM(from: text)
        var index = text.startIndex
        var components: [TOMLKeyComponent] = []
        var expectingComponent = true

        while true {
            skipWhitespace(in: text, from: &index)
            guard index < text.endIndex else {
                return (!components.isEmpty && !expectingComponent) ? components : nil
            }

            let component: TOMLKeyComponent
            if text[index] == "\"" {
                guard let parsed = parseQuotedTOMLKeyComponent(in: text, from: index, quote: "\"") else { return nil }
                component = parsed.component
                index = parsed.endIndex
            } else if text[index] == "'" {
                guard let parsed = parseQuotedTOMLKeyComponent(in: text, from: index, quote: "'") else { return nil }
                component = parsed.component
                index = parsed.endIndex
            } else {
                let start = index
                while index < text.endIndex,
                      let scalar = text[index].unicodeScalars.first,
                      tomlBareKeyCharacters.contains(scalar)
                {
                    index = text.index(after: index)
                }
                guard start < index else { return nil }
                let raw = String(text[start ..< index])
                component = TOMLKeyComponent(raw: raw, normalized: raw)
            }

            components.append(component)
            expectingComponent = false
            skipWhitespace(in: text, from: &index)
            if index == text.endIndex { return components }
            guard text[index] == "." else { return nil }
            index = text.index(after: index)
            expectingComponent = true
        }
    }

    private static func parseQuotedTOMLKeyComponent(
        in text: String,
        from start: String.Index,
        quote: Character
    ) -> (component: TOMLKeyComponent, endIndex: String.Index)? {
        var cursor = text.index(after: start)
        var escaped = false
        var inner = ""

        while cursor < text.endIndex {
            let ch = text[cursor]
            if quote == "\"", escaped {
                inner.append("\\")
                inner.append(ch)
                escaped = false
                cursor = text.index(after: cursor)
                continue
            }
            if quote == "\"", ch == "\\" {
                escaped = true
                cursor = text.index(after: cursor)
                continue
            }
            if ch == quote {
                let end = text.index(after: cursor)
                let raw = String(text[start ..< end])
                let normalized = quote == "\""
                    ? decodeDoubleQuotedTomlKey(inner)
                    : inner.replacingOccurrences(of: "''", with: "'")
                return (TOMLKeyComponent(raw: raw, normalized: normalized), end)
            }
            inner.append(ch)
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func isKeyLine(_ line: String, singleKey key: String) -> Bool {
        parseTOMLAssignment(line)?.isSingleKey(key) == true
    }

    private static func isToolOutputTokenLimitAssignment(_ line: String) -> Bool {
        guard let assignment = parseTOMLAssignment(line), assignment.isSingleKey("tool_output_token_limit") else { return false }
        return parseTOMLIntegerValue(assignment.valueText) != nil
    }

    private static func parseTOMLStringValue(_ valueText: Substring) -> String? {
        let text = String(valueText)
        var index = text.startIndex
        skipWhitespace(in: text, from: &index)
        guard index < text.endIndex else { return nil }
        let quote = text[index]
        guard quote == "\"" || quote == "'" else { return nil }

        var cursor = text.index(after: index)
        var escaped = false
        var inner = ""
        while cursor < text.endIndex {
            let ch = text[cursor]
            if quote == "\"", escaped {
                inner.append("\\")
                inner.append(ch)
                escaped = false
                cursor = text.index(after: cursor)
                continue
            }
            if quote == "\"", ch == "\\" {
                escaped = true
                cursor = text.index(after: cursor)
                continue
            }
            if ch == quote {
                let trailing = text[text.index(after: cursor)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
                return quote == "\"" ? decodeDoubleQuotedTomlKey(inner) : inner
            }
            inner.append(ch)
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func parseTOMLBooleanValue(_ valueText: Substring) -> Bool? {
        let stripped = stripComment(fromValueText: String(valueText))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch stripped {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    private static func parseTOMLIntegerValue(_ valueText: Substring) -> Int? {
        let stripped = stripComment(fromValueText: String(valueText)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty, !stripped.hasPrefix("\""), !stripped.hasPrefix("'") else { return nil }

        let sign: Int
        let digitsStart: String.Index
        if stripped.hasPrefix("+") {
            sign = 1
            digitsStart = stripped.index(after: stripped.startIndex)
        } else if stripped.hasPrefix("-") {
            sign = -1
            digitsStart = stripped.index(after: stripped.startIndex)
        } else {
            sign = 1
            digitsStart = stripped.startIndex
        }

        guard digitsStart < stripped.endIndex else { return nil }
        let unsignedText = String(stripped[digitsStart...])
        let radix: Int
        let digitText: String
        if unsignedText.hasPrefix("0x") || unsignedText.hasPrefix("0X") {
            radix = 16
            digitText = String(unsignedText.dropFirst(2))
        } else if unsignedText.hasPrefix("0o") || unsignedText.hasPrefix("0O") {
            radix = 8
            digitText = String(unsignedText.dropFirst(2))
        } else if unsignedText.hasPrefix("0b") || unsignedText.hasPrefix("0B") {
            radix = 2
            digitText = String(unsignedText.dropFirst(2))
        } else {
            radix = 10
            digitText = unsignedText
            let digitsOnly = digitText.replacingOccurrences(of: "_", with: "")
            if digitsOnly.count > 1, digitsOnly.first == "0" { return nil }
        }

        guard isValidTOMLIntegerDigits(digitText, radix: radix) else { return nil }
        guard let value = Int(digitText.replacingOccurrences(of: "_", with: ""), radix: radix) else { return nil }
        return sign * value
    }

    private static func isValidTOMLIntegerDigits(_ text: String, radix: Int) -> Bool {
        guard !text.isEmpty else { return false }
        var previousWasUnderscore = false
        var sawDigit = false

        for ch in text {
            if ch == "_" {
                guard sawDigit, !previousWasUnderscore else { return false }
                previousWasUnderscore = true
                continue
            }

            guard ch.wholeNumberValue != nil || (radix == 16 && ("a" ... "f").contains(ch.lowercased())) else { return false }
            if let value = ch.wholeNumberValue {
                guard value < radix else { return false }
            }
            sawDigit = true
            previousWasUnderscore = false
        }

        return sawDigit && !previousWasUnderscore
    }

    private static func stripComment(fromValueText text: String) -> String {
        var cursor = text.startIndex
        var quote: Character?
        var escaped = false
        while cursor < text.endIndex {
            let ch = text[cursor]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                return String(text[..<cursor])
            }
            cursor = text.index(after: cursor)
        }
        return text
    }

    private static func stripLeadingBOM(from text: String) -> String {
        var text = text
        var index = text.startIndex
        skipWhitespace(in: text, from: &index)
        if index < text.endIndex, text[index] == "\u{FEFF}" {
            text.remove(at: index)
        }
        return text
    }

    private static func skipWhitespace(in text: String, from index: inout String.Index) {
        while index < text.endIndex, text[index].unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
            index = text.index(after: index)
        }
    }

    private static func decodeDoubleQuotedTomlKey(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)

        var iterator = value.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\" {
                guard let next = iterator.next() else {
                    result.append("\\")
                    break
                }
                switch next {
                case "\"":
                    result.append("\"")
                case "\\":
                    result.append("\\")
                case "b":
                    result.append("\u{08}")
                case "t":
                    result.append("\t")
                case "n":
                    result.append("\n")
                case "f":
                    result.append("\u{0C}")
                case "r":
                    result.append("\r")
                case "u":
                    var hex = ""
                    for _ in 0 ..< 4 {
                        if let digit = iterator.next() {
                            hex.append(digit)
                        } else {
                            break
                        }
                    }
                    if hex.count == 4,
                       let scalar = UInt32(hex, radix: 16),
                       let unicode = UnicodeScalar(scalar)
                    {
                        result.append(Character(unicode))
                    } else {
                        result.append("\\u")
                        result.append(hex)
                    }
                default:
                    result.append(next)
                }
            } else {
                result.append(ch)
            }
        }

        return result
    }

    private static func isCodeModeHeader(_ line: String) -> Bool {
        guard let header = parseTOMLHeader(line), !header.isArrayTable else { return false }
        return header.keyPath.map(\.normalized) == ["features", "code_mode"]
    }

    private static func codeModePolicyConflict(
        in lines: [String],
        supportsDirectOnlyToolNamespaces: Bool
    ) -> String? {
        guard supportsDirectOnlyToolNamespaces else {
            return "RepoPrompt did not update Codex config because this external Codex version predates RepoPrompt's external-runtime compatibility floor (minimum \(CodexRuntimeAuthority.minimumExternalVersion)). Update the explicit override or use the bundled runtime."
        }

        let codeModePath = ["features", "code_mode"]
        let ownedKeys = Set(["enabled", "direct_only_tool_namespaces", "non_prefixed_mcp_tool_names"])
        let blocks = blockRanges(in: lines, whereHeaderMatches: isCodeModeHeader)
        if blocks.count > 1 {
            return "RepoPrompt did not update Codex config because multiple [features.code_mode] blocks exist. Merge them, then retry."
        }

        var currentTablePath: [String] = []
        for line in lines {
            if let header = parseTOMLHeader(line) {
                currentTablePath = header.keyPath.map(\.normalized)
                if header.isArrayTable,
                   currentTablePath == ["features"] || currentTablePath.starts(with: codeModePath)
                {
                    return "RepoPrompt did not update Codex config because an array-table definition conflicts with RepoPrompt's owned [features.code_mode] policy. Preserve the setting in a regular table layout, then retry."
                }
                if currentTablePath.count > codeModePath.count,
                   currentTablePath.starts(with: codeModePath),
                   ownedKeys.contains(currentTablePath[codeModePath.count])
                {
                    return "RepoPrompt did not update Codex config because a table definition redefines an owned [features.code_mode] key. Remove the conflicting table, then retry."
                }
                continue
            }

            guard let assignment = parseTOMLAssignment(line) else { continue }
            let localPath = assignment.keyPath.map(\.normalized)
            let fullPath = currentTablePath + localPath
            let inlineTableValue = stripComment(fromValueText: String(assignment.valueText))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("{")

            if currentTablePath == codeModePath {
                if let key = localPath.first, ownedKeys.contains(key) {
                    guard localPath.count == 1 else {
                        return "RepoPrompt did not update Codex config because a dotted definition redefines the owned [features.code_mode].\(key) key. Preserve that key as a scalar or array, then retry."
                    }
                    if key == "non_prefixed_mcp_tool_names" {
                        return "RepoPrompt did not update Codex config because [features.code_mode].non_prefixed_mcp_tool_names conflicts with the owned direct-only RepoPrompt namespace policy. Remove that key, then retry."
                    }
                    if inlineTableValue {
                        return "RepoPrompt did not update Codex config because an inline table redefines the owned [features.code_mode].\(key) key. Preserve that key as a scalar or array, then retry."
                    }
                }
                continue
            }

            if fullPath == ["features"] || fullPath == codeModePath ||
                (fullPath.count > codeModePath.count && fullPath.starts(with: codeModePath))
            {
                return "RepoPrompt did not update Codex config because a dotted or inline definition conflicts with RepoPrompt's owned [features.code_mode] table. Convert it to a regular [features.code_mode] block, then retry."
            }
        }
        return nil
    }

    @discardableResult
    private static func ensureCodeModePolicy(in lines: inout [String]) -> Bool {
        var changed = false
        var blocks = blockRanges(in: lines, whereHeaderMatches: isCodeModeHeader)
        if blocks.isEmpty {
            appendBlock(
                [
                    "[features.code_mode]",
                    "enabled = true",
                    "direct_only_tool_namespaces = [\"\(directOnlyToolNamespace)\"]"
                ],
                to: &lines
            )
            return true
        }

        var block = blocks.removeFirst()
        if ensureKey(
            "enabled",
            value: "true",
            in: &lines,
            blockRange: &block,
            force: true,
            isSemanticallyEquivalent: { parseTOMLBooleanValue($0) == true }
        ) {
            changed = true
        }
        if ensureKey(
            "direct_only_tool_namespaces",
            value: "[\"\(directOnlyToolNamespace)\"]",
            in: &lines,
            blockRange: &block,
            afterKey: "enabled",
            force: true,
            isSemanticallyEquivalent: isRepoPromptDirectOnlyNamespaceArray
        ) {
            changed = true
        }
        return changed
    }

    private static func isRepoPromptDirectOnlyNamespaceArray(_ valueText: Substring) -> Bool {
        let compact = stripComment(fromValueText: String(valueText))
            .filter { !$0.isWhitespace }
        return compact == "[\"\(directOnlyToolNamespace)\"]" ||
            compact == "['\(directOnlyToolNamespace)']"
    }

    static func ensureRepoPromptServer(
        in lines: inout [String],
        defaultEnabledIfMissing: Bool,
        forceEnabled: Bool?
    ) -> (changed: Bool, wasPresent: Bool) {
        var changed = false
        var blocks = blockRanges(in: lines, whereHeaderMatches: isRepoPromptMCPServerHeader)
        let wasPresent = !blocks.isEmpty
        var addedBlock = false

        if blocks.count > 1 {
            removeBlockRanges(Array(blocks.dropFirst()), from: &lines)
            changed = true
            blocks = blockRanges(in: lines, whereHeaderMatches: isRepoPromptMCPServerHeader)
        }

        if blocks.isEmpty {
            addedBlock = true
            appendBlock(
                repoPromptSnippetLines(
                    enabled: defaultEnabledIfMissing,
                    includeEnabled: true // newly created entries always specify enabled state
                ),
                to: &lines
            )
            changed = true
            blocks = blockRanges(in: lines, whereHeaderMatches: isRepoPromptMCPServerHeader)
        }

        guard var block = blocks.first else {
            return (changed, wasPresent)
        }

        let shouldIncludeEnabledKey = (forceEnabled != nil) || defaultEnabledIfMissing || addedBlock

        if ensureKey("command", value: "\"\(serverCommand)\"", in: &lines, blockRange: &block, force: true) {
            changed = true
        }
        if ensureKey("args", value: serverArgumentsTOML, in: &lines, blockRange: &block, afterKey: "command", force: true) {
            changed = true
        }
        if ensureRepoPromptPolicyKeys(in: &lines, blockRange: &block) {
            changed = true
        }

        if shouldIncludeEnabledKey {
            let desiredEnabled = (forceEnabled ?? defaultEnabledIfMissing) ? "true" : "false"
            let forceFlag = forceEnabled != nil
            if ensureKey("enabled", value: desiredEnabled, in: &lines, blockRange: &block, afterKey: "supports_parallel_tool_calls", force: forceFlag) {
                changed = true
            }
        }

        return (changed, wasPresent)
    }

    private static func blockRanges(
        in lines: [String],
        whereHeaderMatches predicate: (String) -> Bool
    ) -> [BlockRange] {
        var ranges: [BlockRange] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if isTOMLHeaderLine(line) {
                let blockEnd = nextHeaderIndex(after: index + 1, in: lines)
                if predicate(line) {
                    ranges.append(BlockRange(start: index, end: blockEnd))
                }
                index = blockEnd
            } else {
                index += 1
            }
        }

        return ranges
    }

    private static func nextHeaderIndex(after start: Int, in lines: [String]) -> Int {
        var idx = start
        while idx < lines.count {
            if isTOMLHeaderLine(lines[idx]) {
                return idx
            }
            idx += 1
        }
        return lines.count
    }

    private static func removeBlockRanges(_ ranges: [BlockRange], from lines: inout [String]) {
        for range in ranges.sorted(by: { $0.start > $1.start }) {
            lines.removeSubrange(range.start ..< range.end)
        }
    }

    private static func appendBlock(_ blockLines: [String], to lines: inout [String]) {
        if lines.isEmpty {
            lines.append(contentsOf: blockLines)
            return
        }

        if let last = lines.last, !last.isEmpty {
            lines.append("")
        }

        lines.append(contentsOf: blockLines)
    }

    private static func ensureGlobalToolOutputLimit(in lines: inout [String]) -> Bool {
        let firstHeaderIndex = lines.firstIndex(where: isTOMLHeaderLine) ?? lines.count

        var limitLineIndices: [Int] = []
        for idx in 0 ..< firstHeaderIndex where isToolOutputTokenLimitAssignment(lines[idx]) {
            limitLineIndices.append(idx)
        }

        if !limitLineIndices.isEmpty {
            // Respect the first user-defined global value exactly as written, but repair duplicates.
            for duplicateIndex in limitLineIndices.dropFirst().reversed() {
                lines.remove(at: duplicateIndex)
            }
            return limitLineIndices.count > 1
        }

        // No valid global limit found; insert the desired default.
        lines.insert("tool_output_token_limit = \(desiredToolOutputTokenLimit)", at: firstHeaderIndex)
        return true
    }

    @discardableResult
    private static func stripToolOutputLimitFromRepoPromptBlocks(in lines: inout [String]) -> Bool {
        var changed = false

        for block in blockRanges(in: lines, whereHeaderMatches: isRepoPromptMCPServerHeader).sorted(by: { $0.start > $1.start }) {
            let indices = keyLineIndices(for: "tool_output_token_limit", in: lines, within: block)
            guard !indices.isEmpty else { continue }
            for idx in indices.reversed() {
                lines.remove(at: idx)
            }
            changed = true
        }

        return changed
    }

    private static func ensureRepoPromptPolicyKeys(
        in lines: inout [String],
        blockRange: inout BlockRange
    ) -> Bool {
        var changed = false
        let timeoutInsertionKey = firstIndex(ofKey: "args", in: lines, within: blockRange) == nil
            ? "command"
            : "args"

        if ensureKey(
            "tool_timeout_sec",
            value: "\(desiredToolTimeoutSeconds)",
            in: &lines,
            blockRange: &blockRange,
            afterKey: timeoutInsertionKey,
            force: true,
            isSemanticallyEquivalent: { parseTOMLIntegerValue($0) == desiredToolTimeoutSeconds }
        ) {
            changed = true
        }
        if ensureKey(
            "supports_parallel_tool_calls",
            value: "\(desiredSupportsParallelToolCalls)",
            in: &lines,
            blockRange: &blockRange,
            afterKey: "tool_timeout_sec",
            force: true,
            isSemanticallyEquivalent: { parseTOMLBooleanValue($0) == desiredSupportsParallelToolCalls }
        ) {
            changed = true
        }

        return changed
    }

    private static func ensureKey(
        _ key: String,
        value: String,
        in lines: inout [String],
        blockRange: inout BlockRange,
        afterKey: String? = nil,
        force: Bool = false,
        isSemanticallyEquivalent: ((Substring) -> Bool)? = nil
    ) -> Bool {
        var changed = false
        let desiredLine = "\(key) = \(value)"
        let indices = keyLineIndices(for: key, in: lines, within: blockRange)

        if let first = indices.first {
            let preferred = if let isSemanticallyEquivalent {
                indices.first { index in
                    parseTOMLAssignment(lines[index]).map { assignment in
                        isSemanticallyEquivalent(assignment.valueText)
                    } ?? false
                } ?? first
            } else {
                first
            }
            let trimmed = lines[preferred].trimmingCharacters(in: .whitespacesAndNewlines)
            let equivalent = parseTOMLAssignment(lines[preferred]).map { assignment in
                isSemanticallyEquivalent?(assignment.valueText) ?? false
            } ?? false
            if force, !equivalent, trimmed != desiredLine {
                lines[preferred] = desiredLine
                changed = true
            }

            for extra in indices.filter({ $0 != preferred }).reversed() {
                lines.remove(at: extra)
                blockRange.end -= 1
                changed = true
            }
        } else {
            let insertionIndex: Int = if let afterKey,
                                         let afterIndex = firstIndex(ofKey: afterKey, in: lines, within: blockRange)
            {
                afterIndex + 1
            } else {
                blockRange.start + 1
            }

            lines.insert(desiredLine, at: insertionIndex)
            blockRange.end += 1
            changed = true
        }

        return changed
    }

    private static func keyLineIndices(
        for key: String,
        in lines: [String],
        within blockRange: BlockRange
    ) -> [Int] {
        var indices: [Int] = []
        if blockRange.start + 1 >= blockRange.end { return indices }
        for idx in (blockRange.start + 1) ..< blockRange.end {
            if isKeyLine(lines[idx], singleKey: key) {
                indices.append(idx)
            }
        }
        return indices
    }

    private static func firstIndex(
        ofKey key: String,
        in lines: [String],
        within blockRange: BlockRange
    ) -> Int? {
        keyLineIndices(for: key, in: lines, within: blockRange).first
    }

    private static func repoPromptSnippetLines(enabled: Bool, includeEnabled: Bool) -> [String] {
        var lines = [
            "[mcp_servers.\(cliPathComponent(forNormalizedServerName: repoPromptMCPServerName))]",
            "command = \"\(serverCommand)\"",
            "args = \(serverArgumentsTOML)",
            "tool_timeout_sec = \(desiredToolTimeoutSeconds)",
            "supports_parallel_tool_calls = \(desiredSupportsParallelToolCalls)"
        ]
        if includeEnabled {
            lines.append("enabled = \(enabled ? "true" : "false")")
        }
        return lines
    }

    private static func canonicalizedPath(for path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
