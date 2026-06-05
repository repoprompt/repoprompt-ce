import Foundation

actor HeadlessHost {
    let configurationStore: HeadlessConfigurationStore
    let workspaceStore: HeadlessWorkspaceStore
    let fileManager: FileManager

    init(configurationStore: HeadlessConfigurationStore, fileManager: FileManager = .default) {
        self.configurationStore = configurationStore
        workspaceStore = HeadlessWorkspaceStore(paths: configurationStore.paths, fileManager: fileManager)
        self.fileManager = fileManager
    }

    func snapshot(requireWorkspace: Bool = false) throws -> HeadlessWorkspaceSnapshot {
        var config = try configurationStore.loadOrCreate()
        try validateConfiguredRoots(config.allowedRoots)

        if config.allowedRoots.isEmpty {
            if requireWorkspace {
                throw HeadlessCommandError("No headless allowed roots are configured. Add one with `\(HeadlessVersion.executableName) --state-dir \(configurationStore.paths.rootDirectory.path) config roots add /absolute/path --name NAME`.", exitCode: 2)
            }
            return HeadlessWorkspaceSnapshot(config: config, workspace: nil, roots: [])
        }

        let workspaces = try workspaceStore.loadWorkspaces()
        let active = try ensureActiveWorkspace(config: &config, workspaces: workspaces)
        let activeRootIDs = Set(active.rootIDs)
        let roots = config.allowedRoots.filter { activeRootIDs.contains($0.id) }
        if roots.isEmpty, requireWorkspace {
            throw HeadlessCommandError("Active workspace '\(active.name)' has no configured roots. Create or select a workspace with configured root IDs/names.", exitCode: 2)
        }
        return HeadlessWorkspaceSnapshot(config: config, workspace: active, roots: roots)
    }

    func listWorkspaces() throws -> (config: HeadlessConfigurationDocument, workspaces: [HeadlessWorkspaceDocument]) {
        var config = try configurationStore.loadOrCreate()
        try validateConfiguredRoots(config.allowedRoots)
        var workspaces = try workspaceStore.loadWorkspaces()
        if !config.allowedRoots.isEmpty, workspaces.isEmpty {
            let created = try createDefaultWorkspace(for: config.allowedRoots)
            workspaces = [created]
            config.activeWorkspaceID = created.id
            config.touch()
            try configurationStore.save(config)
        }
        return (config, workspaces)
    }

    func createWorkspace(name: String, rootTokens: [String]) throws -> HeadlessWorkspaceDocument {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw HeadlessCommandError("Workspace name must not be empty.", exitCode: 2)
        }
        var config = try configurationStore.loadOrCreate()
        try validateConfiguredRoots(config.allowedRoots)
        guard !config.allowedRoots.isEmpty else {
            throw HeadlessCommandError("Cannot create a workspace without configured allowed roots.", exitCode: 2)
        }
        let existing = try workspaceStore.loadWorkspaces()
        guard !existing.contains(where: { $0.name == trimmedName }) else {
            throw HeadlessCommandError("Workspace name already exists: \(trimmedName)", exitCode: 2)
        }

        let roots = try resolveConfiguredRoots(tokens: rootTokens, allowedRoots: config.allowedRoots)
        let workspace = HeadlessWorkspaceDocument(name: trimmedName, rootIDs: roots.map(\.id))
        try workspaceStore.save(workspace)
        config.activeWorkspaceID = workspace.id
        config.touch()
        try configurationStore.save(config)
        return workspace
    }

    func selectWorkspace(token: String) throws -> HeadlessWorkspaceDocument {
        var config = try configurationStore.loadOrCreate()
        let workspaces = try workspaceStore.loadWorkspaces()
        let workspace = try resolveWorkspace(token: token, workspaces: workspaces)
        config.activeWorkspaceID = workspace.id
        config.touch()
        try configurationStore.save(config)
        return workspace
    }

    func renameWorkspace(token: String?, newName: String) throws -> HeadlessWorkspaceDocument {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw HeadlessCommandError("Workspace name must not be empty.", exitCode: 2)
        }
        let snapshot = try snapshot(requireWorkspace: true)
        guard let activeWorkspace = snapshot.workspace else {
            throw HeadlessCommandError("No active workspace is available.", exitCode: 2)
        }
        let workspaces = try workspaceStore.loadWorkspaces()
        let workspace = try token.map { try resolveWorkspace(token: $0, workspaces: workspaces) } ?? activeWorkspace
        guard !workspaces.contains(where: { $0.id != workspace.id && $0.name == trimmedName }) else {
            throw HeadlessCommandError("Workspace name already exists: \(trimmedName)", exitCode: 2)
        }
        return try workspaceStore.update(id: workspace.id) { document in
            document.name = trimmedName
        }
    }

    func updateActiveWorkspace(_ body: (inout HeadlessWorkspaceDocument) throws -> Void) throws -> HeadlessWorkspaceDocument {
        let snapshot = try snapshot(requireWorkspace: true)
        guard let workspace = snapshot.workspace else {
            throw HeadlessCommandError("No active workspace is available.", exitCode: 2)
        }
        return try workspaceStore.update(id: workspace.id, body)
    }

    func replaceSelection(_ selection: [HeadlessSelectionEntry]) throws -> HeadlessWorkspaceDocument {
        try updateActiveWorkspace { workspace in
            workspace.selection = Self.normalizedSelection(selection)
        }
    }

    func setPrompt(_ text: String) throws -> HeadlessWorkspaceDocument {
        try updateActiveWorkspace { workspace in
            workspace.promptText = text
        }
    }

    func appendPrompt(_ text: String) throws -> HeadlessWorkspaceDocument {
        try updateActiveWorkspace { workspace in
            workspace.promptText += text
        }
    }

    func clearPrompt() throws -> HeadlessWorkspaceDocument {
        try updateActiveWorkspace { workspace in
            workspace.promptText = ""
        }
    }

    func exportURL(for requestedPath: String?, defaultFileName: String, permissions: HeadlessPermissions) throws -> URL {
        let stateRoot = configurationStore.paths.rootDirectory.standardizedFileURL
        let exportsRoot = configurationStore.paths.exportsDirectory.standardizedFileURL
        try fileManager.createDirectory(at: exportsRoot, withIntermediateDirectories: true)

        let target: URL = if let requestedPath, !requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if requestedPath.hasPrefix("/") {
                URL(fileURLWithPath: requestedPath).standardizedFileURL
            } else {
                exportsRoot.appendingPathComponent(requestedPath, isDirectory: false).standardizedFileURL
            }
        } else {
            exportsRoot.appendingPathComponent(defaultFileName, isDirectory: false).standardizedFileURL
        }

        let parent = target.deletingLastPathComponent().standardizedFileURL
        let resolvedStatePath = stateRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedExportsPath = exportsRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedParentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedTargetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        let inState = HeadlessRootAccessPolicy.path(resolvedTargetPath, isContainedInOrEqualTo: resolvedStatePath)
        let inExports = HeadlessRootAccessPolicy.path(resolvedTargetPath, isContainedInOrEqualTo: resolvedExportsPath)
        let parentInState = HeadlessRootAccessPolicy.path(resolvedParentPath, isContainedInOrEqualTo: resolvedStatePath)
        let parentInExports = HeadlessRootAccessPolicy.path(resolvedParentPath, isContainedInOrEqualTo: resolvedExportsPath)
        guard (inState && parentInState) || permissions.exportOutsideStateDirectory else {
            throw HeadlessCommandError("Export path is outside the headless state directory and export_outside_state_directory is false: \(target.path)", exitCode: 2)
        }
        if !(requestedPath?.hasPrefix("/") ?? false), !(inExports && parentInExports) {
            throw HeadlessCommandError("Relative export path escapes the headless Exports directory: \(requestedPath ?? defaultFileName)", exitCode: 2)
        }
        if let values = try? target.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw HeadlessCommandError("Export target must not be an existing symbolic link: \(target.path)", exitCode: 2)
        }
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        return target
    }

    private func ensureActiveWorkspace(config: inout HeadlessConfigurationDocument, workspaces: [HeadlessWorkspaceDocument]) throws -> HeadlessWorkspaceDocument {
        if let activeID = config.activeWorkspaceID,
           let active = workspaces.first(where: { $0.id == activeID })
        {
            return active
        }
        if let first = workspaces.first {
            config.activeWorkspaceID = first.id
            config.touch()
            try configurationStore.save(config)
            return first
        }
        let created = try createDefaultWorkspace(for: config.allowedRoots)
        config.activeWorkspaceID = created.id
        config.touch()
        try configurationStore.save(config)
        return created
    }

    private func createDefaultWorkspace(for roots: [HeadlessAllowedRoot]) throws -> HeadlessWorkspaceDocument {
        let workspace = HeadlessWorkspaceDocument(name: "Default", rootIDs: roots.map(\.id))
        try workspaceStore.save(workspace)
        return workspace
    }

    private func validateConfiguredRoots(_ roots: [HeadlessAllowedRoot]) throws {
        let failures = HeadlessRootAccessPolicy.validationFailures(for: roots, fileManager: fileManager)
        guard failures.isEmpty else {
            throw HeadlessCommandError("Headless root policy validation failed:\n- \(failures.joined(separator: "\n- "))", exitCode: 2)
        }
    }

    private func resolveConfiguredRoots(tokens: [String], allowedRoots: [HeadlessAllowedRoot]) throws -> [HeadlessAllowedRoot] {
        guard !tokens.isEmpty else {
            return allowedRoots
        }
        var resolved: [HeadlessAllowedRoot] = []
        for token in tokens {
            guard let root = allowedRoots.first(where: { HeadlessRootAccessPolicy.rootMatches($0, token: token, fileManager: fileManager) }) else {
                throw HeadlessCommandError("No configured allowed root matches '\(token)'.", exitCode: 2)
            }
            if !resolved.contains(where: { $0.id == root.id }) {
                resolved.append(root)
            }
        }
        return resolved
    }

    private func resolveWorkspace(token: String, workspaces: [HeadlessWorkspaceDocument]) throws -> HeadlessWorkspaceDocument {
        if let id = UUID(uuidString: token), let workspace = workspaces.first(where: { $0.id == id }) {
            return workspace
        }
        if let workspace = workspaces.first(where: { $0.name == token }) {
            return workspace
        }
        throw HeadlessCommandError("No headless workspace matches '\(token)'.", exitCode: 2)
    }

    private static func normalizedSelection(_ selection: [HeadlessSelectionEntry]) -> [HeadlessSelectionEntry] {
        var result: [HeadlessSelectionEntry] = []
        for entry in selection {
            if let index = result.firstIndex(where: { $0.rootID == entry.rootID && $0.relativePath == entry.relativePath }) {
                result[index] = entry
            } else {
                result.append(entry)
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.rootID == rhs.rootID {
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
            return lhs.rootID.uuidString < rhs.rootID.uuidString
        }
    }
}
