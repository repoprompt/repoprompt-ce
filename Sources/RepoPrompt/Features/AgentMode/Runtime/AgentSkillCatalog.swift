import Foundation

struct AgentSkillDefinition: Equatable, Hashable, Identifiable {
    /// Describes where a skill was discovered for prompt labels and stable source buckets.
    ///
    /// Discovery precedence is controlled by `AgentSkillCatalog.SkillRoot.precedenceRank`
    /// so agents can combine namespaces (for example Claude-specific roots plus the
    /// generic `.agents` namespace) without changing source identity raw values.
    enum Source: Int {
        // Claude Code roots
        case workspaceClaudeSkills = 0
        case workspaceClaudeCommands = 1
        case globalClaudeSkills = 2
        case globalClaudeCommands = 3

        // Generic .agents namespace roots
        case workspaceAgentsSkills = 10
        case workspaceAgentsSlash = 11
        case globalAgentsSkills = 12
        case globalAgentsSlash = 13
    }

    let id: String
    let name: String
    let description: String?
    let variant: String?
    let fileURL: URL
    let template: String
    let source: Source
}

extension AgentSkillDefinition {
    /// Creates a display-only `AgentWorkflowDefinition` for showing a skill pill in the chat bubble.
    /// The returned definition has `template: nil` so `wrapUserText` is a no-op — skill expansion
    /// is handled separately by `expandSlashSkillInvocationIfNeeded`.
    func asBubbleWorkflowDefinition() -> AgentWorkflowDefinition {
        AgentWorkflowDefinition(
            customID: UUID(),
            displayName: "/\(name)",
            iconName: "terminal.fill",
            accentColorHex: "#8B5CF6",
            tooltipText: description,
            descriptionText: description,
            template: nil
        )
    }
}

extension AgentSkillDefinition.Source {
    var isGlobal: Bool {
        switch self {
        case .globalClaudeSkills, .globalClaudeCommands, .globalAgentsSkills, .globalAgentsSlash:
            true
        case .workspaceClaudeSkills, .workspaceClaudeCommands, .workspaceAgentsSkills, .workspaceAgentsSlash:
            false
        }
    }

    var promptScopeLabel: String {
        isGlobal ? "global" : "workspace"
    }

    var promptSourceLabel: String {
        switch self {
        case .workspaceClaudeSkills, .globalClaudeSkills:
            ".claude/skills"
        case .workspaceClaudeCommands, .globalClaudeCommands:
            ".claude/commands"
        case .workspaceAgentsSkills, .globalAgentsSkills:
            ".agents/skills"
        case .workspaceAgentsSlash, .globalAgentsSlash:
            ".agents/slash"
        }
    }
}

@MainActor
final class AgentSkillCatalog {
    // MARK: - Internal types

    /// How files are laid out inside a skill root directory.
    private enum SkillRootFormat {
        /// Subdirectory per skill, each containing a `SKILL.md` definition.
        /// e.g. `.claude/skills/my-skill/SKILL.md`
        case skillFolderSKILLMd
        /// Flat `.md` files in the directory, one per command.
        /// e.g. `.claude/commands/review.md`
        case legacyFlatMd
    }

    /// A single search root together with its source tier, layout format, and discovery precedence.
    private struct SkillRoot {
        let url: URL
        let source: AgentSkillDefinition.Source
        let format: SkillRootFormat
        let precedenceRank: Int
        let rootOrdinal: Int
    }

    private struct ScannedSkillDefinition {
        let definition: AgentSkillDefinition
        let definitionFileKey: String
    }

    private struct DiscoveredSkill {
        let definition: AgentSkillDefinition
        let precedenceRank: Int
        let rootOrdinal: Int
    }

    struct PromptContext {
        let scopeLabel: String
        let sourceLabel: String
        let directoryTree: String?
    }

    private struct DirectoryTreeEntry {
        let url: URL
        let isDirectory: Bool
        let displayName: String
    }

    // MARK: - State

    private static let promptTreeMaxDepth = 4
    private static let promptTreeMaxChildrenPerDirectory = 12

    private let fileManager: FileManager
    private let homeDirectoryURL: URL
    private var orderedSkills: [AgentSkillDefinition] = []
    private var skillsByName: [String: AgentSkillDefinition] = [:]
    private var loadedWorkspacePaths: [String] = []
    private var loadedAgentKind: AgentProviderKind?
    private var hasLoaded = false
    private var isDirty = false
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    init(fileManager: FileManager = .default, homeDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.homeDirectoryURL = (homeDirectoryURL ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
    }

    // MARK: - Public API

    func scheduleRefresh(workspacePaths: [String], agentKind: AgentProviderKind) {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await refresh(workspacePaths: workspacePaths, agentKind: agentKind, generation: generation)
            if refreshGeneration == generation {
                refreshTask = nil
            }
        }
    }

    /// Perform a full skill rescan.
    ///
    /// When `generation` is supplied (scheduled/async refreshes), results are only
    /// applied if no newer refresh has been requested in the meantime. When `nil`
    /// (synchronous / `refreshIfNeeded` callers), results are always applied.
    func refresh(workspacePaths: [String], agentKind: AgentProviderKind, generation: UInt64? = nil) async {
        let canonicalPaths = workspacePaths.compactMap { Self.canonicalWorkspacePath($0) }
        let discovered = await discoverSkills(workspacePaths: canonicalPaths, agentKind: agentKind)

        // Guard against out-of-order application: if a newer generation was
        // requested while we were scanning, discard these (now-stale) results.
        if let generation, generation != refreshGeneration {
            return
        }

        orderedSkills = discovered
        skillsByName = Dictionary(uniqueKeysWithValues: discovered.map { ($0.name.lowercased(), $0) })
        loadedWorkspacePaths = canonicalPaths
        loadedAgentKind = agentKind
        hasLoaded = true
        isDirty = false
    }

    /// Mark the catalog dirty so the next `refreshIfNeeded` call triggers a re-scan.
    /// Use when external changes (e.g. file-system deltas) may have affected skill files.
    func markDirty(reason: String? = nil) {
        isDirty = true
        #if DEBUG
            if let reason {
                print("[AgentSkillCatalog] marked dirty: \(reason)")
            }
        #endif
    }

    func refreshIfNeeded(workspacePaths: [String], agentKind: AgentProviderKind) async {
        let canonicalPaths = workspacePaths.compactMap { Self.canonicalWorkspacePath($0) }
        if hasLoaded,
           loadedWorkspacePaths == canonicalPaths,
           loadedAgentKind == agentKind,
           !isDirty
        {
            return
        }
        await refresh(workspacePaths: canonicalPaths, agentKind: agentKind)
    }

    func resolve(name: String) -> AgentSkillDefinition? {
        skillsByName[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    func contains(name: String) -> Bool {
        resolve(name: name) != nil
    }

    func suggestions(prefix: String, limit: Int) -> [AgentSkillDefinition] {
        guard limit > 0 else { return [] }
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrefix = trimmedPrefix.lowercased()

        if normalizedPrefix.isEmpty {
            return Array(orderedSkills.prefix(limit))
        }

        let ranked = orderedSkills.compactMap { skill -> (score: Int, skill: AgentSkillDefinition)? in
            let name = skill.name.lowercased()
            if name == normalizedPrefix {
                return (0, skill)
            }
            if name.hasPrefix(normalizedPrefix) {
                return (1, skill)
            }
            if name.contains(normalizedPrefix) {
                return (2, skill)
            }
            if let description = skill.description?.lowercased(), description.contains(normalizedPrefix) {
                return (3, skill)
            }
            return nil
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                return lhs.skill.name.localizedCaseInsensitiveCompare(rhs.skill.name) == .orderedAscending
            }
            .map(\.skill)
            .prefix(limit)
            .map(\.self)
    }

    func promptContext(for definition: AgentSkillDefinition) -> PromptContext {
        PromptContext(
            scopeLabel: definition.source.promptScopeLabel,
            sourceLabel: definition.source.promptSourceLabel,
            directoryTree: Self.renderPromptDirectoryTree(
                for: definition,
                fileManager: fileManager,
                homeDirectoryURL: homeDirectoryURL
            )
        )
    }

    // MARK: - Discovery internals

    private nonisolated static func canonicalWorkspacePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func discoverSkills(workspacePaths: [String], agentKind: AgentProviderKind) async -> [AgentSkillDefinition] {
        let roots = skillSearchRoots(workspacePaths: workspacePaths, agentKind: agentKind)
        let fileManager = fileManager
        return await Task.detached(priority: .utility) {
            var winnersByName: [String: DiscoveredSkill] = [:]
            var seenRootKeys = Set<String>()
            var seenDefinitionFileKeys = Set<String>()

            let orderedRoots = roots.sorted { lhs, rhs in
                if lhs.precedenceRank != rhs.precedenceRank {
                    return lhs.precedenceRank < rhs.precedenceRank
                }
                return lhs.rootOrdinal < rhs.rootOrdinal
            }

            for root in orderedRoots {
                if Task.isCancelled { break }
                guard let rootDirectoryKey = Self.canonicalExistingDirectoryKey(for: root.url, fileManager: fileManager) else {
                    continue
                }
                let rootDedupKey = "\(rootDirectoryKey)|\(root.format)"
                guard seenRootKeys.insert(rootDedupKey).inserted else {
                    continue
                }

                for scanned in Self.scanSkillDefinitions(
                    in: root.url,
                    source: root.source,
                    format: root.format,
                    rootDirectoryKey: rootDirectoryKey,
                    fileManager: fileManager
                ) {
                    if Task.isCancelled { break }
                    guard seenDefinitionFileKeys.insert(scanned.definitionFileKey).inserted else {
                        continue
                    }
                    let key = scanned.definition.name.lowercased()
                    if winnersByName[key] == nil {
                        winnersByName[key] = DiscoveredSkill(
                            definition: scanned.definition,
                            precedenceRank: root.precedenceRank,
                            rootOrdinal: root.rootOrdinal
                        )
                    }
                }
            }

            return winnersByName.values
                .sorted { lhs, rhs in
                    if lhs.precedenceRank != rhs.precedenceRank {
                        return lhs.precedenceRank < rhs.precedenceRank
                    }
                    let nameComparison = lhs.definition.name.localizedCaseInsensitiveCompare(rhs.definition.name)
                    if nameComparison != .orderedSame {
                        return nameComparison == .orderedAscending
                    }
                    return lhs.rootOrdinal < rhs.rootOrdinal
                }
                .map(\.definition)
        }.value
    }

    /// Returns agent-specific search roots in precedence order.
    ///
    /// Scans **all** workspace paths (loaded roots) for workspace-scoped skills,
    /// then appends global roots. First definition per name wins — earlier roots
    /// take precedence over later ones, and workspace scope generally beats global.
    private func skillSearchRoots(workspacePaths: [String], agentKind: AgentProviderKind) -> [SkillRoot] {
        var roots: [SkillRoot] = []
        let globalRoots = AgentSupportDirectoryCatalog.globalRootURLs(homeDirectoryURL: homeDirectoryURL)

        func appendWorkspaceRoots(
            relativeRoot: String,
            source: AgentSkillDefinition.Source,
            format: SkillRootFormat,
            precedenceRank: Int
        ) {
            for (ordinal, workspacePath) in workspacePaths.enumerated() {
                let workspaceURL = URL(fileURLWithPath: workspacePath)
                roots.append(SkillRoot(
                    url: workspaceURL.appendingPathComponent(relativeRoot, isDirectory: true),
                    source: source,
                    format: format,
                    precedenceRank: precedenceRank,
                    rootOrdinal: ordinal
                ))
            }
        }

        func appendGlobalRoot(
            url: URL,
            source: AgentSkillDefinition.Source,
            format: SkillRootFormat,
            precedenceRank: Int
        ) {
            roots.append(SkillRoot(
                url: url,
                source: source,
                format: format,
                precedenceRank: precedenceRank,
                rootOrdinal: 0
            ))
        }

        switch agentKind {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            appendWorkspaceRoots(
                relativeRoot: ".claude/skills",
                source: .workspaceClaudeSkills,
                format: .skillFolderSKILLMd,
                precedenceRank: 0
            )
            appendWorkspaceRoots(
                relativeRoot: ".claude/commands",
                source: .workspaceClaudeCommands,
                format: .legacyFlatMd,
                precedenceRank: 1
            )
            appendWorkspaceRoots(
                relativeRoot: ".agents/skills",
                source: .workspaceAgentsSkills,
                format: .skillFolderSKILLMd,
                precedenceRank: 2
            )
            appendWorkspaceRoots(
                relativeRoot: ".agents/slash",
                source: .workspaceAgentsSlash,
                format: .legacyFlatMd,
                precedenceRank: 3
            )
            appendGlobalRoot(
                url: globalRoots.claudeSkills,
                source: .globalClaudeSkills,
                format: .skillFolderSKILLMd,
                precedenceRank: 4
            )
            appendGlobalRoot(
                url: globalRoots.claudeCommands,
                source: .globalClaudeCommands,
                format: .legacyFlatMd,
                precedenceRank: 5
            )
            appendGlobalRoot(
                url: globalRoots.agentsSkills,
                source: .globalAgentsSkills,
                format: .skillFolderSKILLMd,
                precedenceRank: 6
            )
            appendGlobalRoot(
                url: globalRoots.agentsSlash,
                source: .globalAgentsSlash,
                format: .legacyFlatMd,
                precedenceRank: 7
            )

        case .codexExec, .openCode, .cursor, .grokBuild:
            // Codex, OpenCode, and Cursor continue to share only the generic `.agents` namespace.
            appendWorkspaceRoots(
                relativeRoot: ".agents/skills",
                source: .workspaceAgentsSkills,
                format: .skillFolderSKILLMd,
                precedenceRank: 0
            )
            appendWorkspaceRoots(
                relativeRoot: ".agents/slash",
                source: .workspaceAgentsSlash,
                format: .legacyFlatMd,
                precedenceRank: 1
            )
            appendGlobalRoot(
                url: globalRoots.agentsSkills,
                source: .globalAgentsSkills,
                format: .skillFolderSKILLMd,
                precedenceRank: 2
            )
            appendGlobalRoot(
                url: globalRoots.agentsSlash,
                source: .globalAgentsSlash,
                format: .legacyFlatMd,
                precedenceRank: 3
            )
        }

        return roots
    }

    // MARK: - Scanning

    /// Scan a single root for skill definitions, dispatching on the root's format.
    private nonisolated static func scanSkillDefinitions(
        in directory: URL,
        source: AgentSkillDefinition.Source,
        format: SkillRootFormat,
        rootDirectoryKey: String,
        fileManager: FileManager
    ) -> [ScannedSkillDefinition] {
        switch format {
        case .skillFolderSKILLMd:
            scanSkillFolderDefinitions(
                in: directory,
                source: source,
                rootDirectoryKey: rootDirectoryKey,
                fileManager: fileManager
            )
        case .legacyFlatMd:
            scanLegacyFlatDefinitions(in: directory, source: source, fileManager: fileManager)
        }
    }

    /// Scan for `SKILL.md` files inside per-skill subdirectories (e.g. `.claude/skills/deploy/SKILL.md`).
    private nonisolated static func scanSkillFolderDefinitions(
        in directory: URL,
        source: AgentSkillDefinition.Source,
        rootDirectoryKey: String,
        fileManager: FileManager
    ) -> [ScannedSkillDefinition] {
        var visitedDirectoryKeys: Set<String> = [rootDirectoryKey]
        var definitions: [ScannedSkillDefinition] = []

        func walk(_ directoryURL: URL) {
            if Task.isCancelled { return }
            let contents = (try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            )) ?? canonicalExistingDirectoryKey(for: directoryURL, fileManager: fileManager).flatMap { resolvedDirectoryKey in
                try? fileManager.contentsOfDirectory(
                    at: URL(fileURLWithPath: resolvedDirectoryKey, isDirectory: true),
                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                    options: [.skipsPackageDescendants]
                )
            }
            guard let contents else { return }

            let sortedContents = contents.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
            for rawEntryURL in sortedContents {
                if Task.isCancelled { return }
                // Preserve the user-visible traversal path even when `directoryURL` is a symlink
                // and Foundation reports children using the resolved target path.
                let entryURL = directoryURL.appendingPathComponent(rawEntryURL.lastPathComponent)
                if entryURL.lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame {
                    guard let fileKey = canonicalExistingFileKey(for: entryURL, fileManager: fileManager),
                          let definition = parseSkillDefinition(from: entryURL, source: source)
                    else { continue }
                    definitions.append(ScannedSkillDefinition(definition: definition, definitionFileKey: fileKey))
                    continue
                }

                let values = try? entryURL.resourceValues(forKeys: [.isPackageKey])
                if values?.isPackage == true {
                    continue
                }
                guard let directoryKey = canonicalExistingDirectoryKey(for: entryURL, fileManager: fileManager),
                      visitedDirectoryKeys.insert(directoryKey).inserted
                else {
                    continue
                }
                walk(entryURL)
            }
        }

        walk(directory)
        return definitions
    }

    /// Scan for flat `.md` files directly inside a legacy command/slash directory.
    /// Non-recursive — only immediate children are considered to avoid picking up
    /// unrelated documentation nested deeper in the tree.
    private nonisolated static func scanLegacyFlatDefinitions(
        in directory: URL,
        source: AgentSkillDefinition.Source,
        fileManager: FileManager
    ) -> [ScannedSkillDefinition] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? canonicalExistingDirectoryKey(for: directory, fileManager: fileManager).flatMap { resolvedDirectoryKey in
            try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: resolvedDirectoryKey, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        }
        guard let contents else { return [] }

        var definitions: [ScannedSkillDefinition] = []
        let sortedContents = contents.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
        for rawFileURL in sortedContents {
            if Task.isCancelled { break }
            let fileURL = directory.appendingPathComponent(rawFileURL.lastPathComponent)
            // Only accept .md files
            guard fileURL.pathExtension.caseInsensitiveCompare("md") == .orderedSame else { continue }
            // Skip SKILL.md files (those belong to the folder-based format)
            guard fileURL.lastPathComponent.caseInsensitiveCompare("SKILL.md") != .orderedSame else { continue }
            guard let fileKey = canonicalExistingFileKey(for: fileURL, fileManager: fileManager),
                  let definition = parseLegacyFlatDefinition(from: fileURL, source: source)
            else { continue }
            definitions.append(ScannedSkillDefinition(definition: definition, definitionFileKey: fileKey))
        }
        return definitions
    }

    private nonisolated static func canonicalExistingDirectoryKey(
        for url: URL,
        fileManager: FileManager
    ) -> String? {
        existingPathKey(for: url, expectedDirectory: true, fileManager: fileManager)
    }

    private nonisolated static func canonicalExistingFileKey(
        for url: URL,
        fileManager: FileManager
    ) -> String? {
        existingPathKey(for: url, expectedDirectory: false, fileManager: fileManager)
    }

    private nonisolated static func existingPathKey(
        for url: URL,
        expectedDirectory: Bool,
        fileManager: FileManager
    ) -> String? {
        let normalizedPath = AgentSupportDirectoryCatalog.normalizedPath(for: url.path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory) else {
            return nil
        }

        let resolvedPath = AgentSupportDirectoryCatalog.normalizedPath(
            for: URL(fileURLWithPath: normalizedPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        )
        if isDirectory.boolValue == expectedDirectory {
            return resolvedPath
        }

        var resolvedIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &resolvedIsDirectory),
              resolvedIsDirectory.boolValue == expectedDirectory
        else {
            return nil
        }
        return resolvedPath
    }

    // MARK: - Parsing

    /// Parse a `SKILL.md` file (folder-based skill). Fallback name is the parent directory name.
    private nonisolated static func parseSkillDefinition(from fileURL: URL, source: AgentSkillDefinition.Source) -> AgentSkillDefinition? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let frontmatter = parseFrontmatter(from: content)

        let fallbackName = fileURL.deletingLastPathComponent().lastPathComponent
        return buildDefinition(content: content, frontmatter: frontmatter, fallbackName: fallbackName, fileURL: fileURL, source: source)
    }

    /// Parse a flat `.md` command file. Fallback name is the filename stem (without extension).
    private nonisolated static func parseLegacyFlatDefinition(from fileURL: URL, source: AgentSkillDefinition.Source) -> AgentSkillDefinition? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let frontmatter = parseFrontmatter(from: content)

        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        return buildDefinition(content: content, frontmatter: frontmatter, fallbackName: fallbackName, fileURL: fileURL, source: source)
    }

    /// Shared builder that constructs an `AgentSkillDefinition` from parsed content and metadata.
    private nonisolated static func buildDefinition(
        content: String,
        frontmatter: [String: String],
        fallbackName: String,
        fileURL: URL,
        source: AgentSkillDefinition.Source
    ) -> AgentSkillDefinition? {
        let rawName = (frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else {
            return nil
        }
        let commandName = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        guard !commandName.isEmpty else {
            return nil
        }

        let description = frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let variant = frontmatter["repoprompt_variant"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableID = "\(source.rawValue):\(commandName.lowercased()):\(fileURL.path)"
        return AgentSkillDefinition(
            id: stableID,
            name: commandName,
            description: description?.isEmpty == true ? nil : description,
            variant: variant?.isEmpty == true ? nil : variant,
            fileURL: fileURL,
            template: content,
            source: source
        )
    }

    private nonisolated static func parseFrontmatter(from content: String) -> [String: String] {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return [:]
        }

        var values: [String: String] = [:]
        var foundClosingMarker = false
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                foundClosingMarker = true
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  let colonIndex = trimmed.firstIndex(of: ":")
            else {
                continue
            }

            let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        guard foundClosingMarker else {
            return [:]
        }
        return values
    }

    private nonisolated static func renderPromptDirectoryTree(
        for definition: AgentSkillDefinition,
        fileManager: FileManager,
        homeDirectoryURL: URL
    ) -> String? {
        if definition.fileURL.lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame {
            let rootURL = definition.fileURL.deletingLastPathComponent()
            return renderFolderTree(
                rootURL: rootURL,
                fileManager: fileManager,
                homeDirectoryURL: homeDirectoryURL,
                fallbackLeafName: definition.fileURL.lastPathComponent
            )
        }

        let parentURL = definition.fileURL.deletingLastPathComponent()
        let rootLabel = displayPath(parentURL, homeDirectoryURL: homeDirectoryURL)
        return "\(rootLabel)\n└── \(definition.fileURL.lastPathComponent)"
    }

    private nonisolated static func renderFolderTree(
        rootURL: URL,
        fileManager: FileManager,
        homeDirectoryURL: URL,
        fallbackLeafName: String
    ) -> String {
        var lines = [displayPath(rootURL, homeDirectoryURL: homeDirectoryURL)]
        let appendedChildren = appendDirectoryTree(
            at: rootURL,
            prefix: "",
            depth: 0,
            lines: &lines,
            fileManager: fileManager
        )
        if !appendedChildren {
            lines.append("└── \(fallbackLeafName)")
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    private nonisolated static func appendDirectoryTree(
        at directoryURL: URL,
        prefix: String,
        depth: Int,
        lines: inout [String],
        fileManager: FileManager
    ) -> Bool {
        guard let entries = directoryEntries(at: directoryURL, fileManager: fileManager), !entries.isEmpty else {
            return false
        }

        if depth >= promptTreeMaxDepth {
            lines.append(prefix + "└── ...")
            return true
        }

        let visibleEntries = Array(entries.prefix(promptTreeMaxChildrenPerDirectory))
        let hasOverflow = entries.count > visibleEntries.count

        for (index, entry) in visibleEntries.enumerated() {
            let isLastVisibleEntry = index == visibleEntries.count - 1 && !hasOverflow
            let branch = isLastVisibleEntry ? "└── " : "├── "
            lines.append(prefix + branch + entry.displayName)
            if entry.isDirectory {
                let childPrefix = prefix + (isLastVisibleEntry ? "    " : "│   ")
                _ = appendDirectoryTree(
                    at: entry.url,
                    prefix: childPrefix,
                    depth: depth + 1,
                    lines: &lines,
                    fileManager: fileManager
                )
            }
        }

        if hasOverflow {
            lines.append(prefix + "└── ...")
        }

        return true
    }

    private nonisolated static func directoryEntries(
        at directoryURL: URL,
        fileManager: FileManager
    ) -> [DirectoryTreeEntry]? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        return contents
            .map { entryURL in
                let values = try? entryURL.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = values?.isDirectory == true
                return DirectoryTreeEntry(
                    url: entryURL,
                    isDirectory: isDirectory,
                    displayName: entryURL.lastPathComponent + (isDirectory ? "/" : "")
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private nonisolated static func displayPath(_ url: URL, homeDirectoryURL: URL) -> String {
        let standardizedPath = url.standardizedFileURL.path
        let homePath = homeDirectoryURL.standardizedFileURL.path
        if standardizedPath == homePath {
            return "~"
        }
        let homePrefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        if standardizedPath.hasPrefix(homePrefix) {
            return "~/" + String(standardizedPath.dropFirst(homePrefix.count))
        }
        return standardizedPath
    }
}
