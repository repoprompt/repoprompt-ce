import Foundation

actor HeadlessHost {
    typealias CatalogMutationLoadedHook = @Sendable () throws -> Void

    let configurationStore: HeadlessConfigurationStore
    let workspaceStore: HeadlessWorkspaceStore
    let fileManager: FileManager
    private let exportWriter: HeadlessExportWriter
    private let catalogMutationLoadedHook: CatalogMutationLoadedHook?

    init(
        configurationStore: HeadlessConfigurationStore,
        fileManager: FileManager = .default,
        exportWriter: HeadlessExportWriter? = nil,
        catalogMutationLoadedHook: CatalogMutationLoadedHook? = nil
    ) {
        self.configurationStore = configurationStore
        workspaceStore = HeadlessWorkspaceStore(paths: configurationStore.paths, fileManager: fileManager)
        self.fileManager = fileManager
        self.exportWriter = exportWriter ?? HeadlessExportWriter(paths: configurationStore.paths, fileManager: fileManager)
        self.catalogMutationLoadedHook = catalogMutationLoadedHook
    }

    func snapshot(requireWorkspace: Bool = false) throws -> HeadlessWorkspaceSnapshot {
        let transaction = try configurationStore.withStateTransaction { config in
            try workspaceState(config: &config, requireWorkspace: requireWorkspace)
        }
        return HeadlessWorkspaceSnapshot(
            config: transaction.configuration,
            workspace: transaction.value.workspace,
            roots: transaction.value.roots
        )
    }

    func listWorkspaces() throws -> (config: HeadlessConfigurationDocument, workspaces: [HeadlessWorkspaceDocument]) {
        let transaction = try configurationStore.withStateTransaction { config in
            try validateConfiguredRoots(config.allowedRoots)
            var workspaces = try workspaceStore.loadWorkspaces()
            if !config.allowedRoots.isEmpty {
                let active = try ensureActiveWorkspace(config: &config, workspaces: workspaces)
                if workspaces.isEmpty {
                    workspaces = [active]
                }
            }
            return workspaces
        }
        return (transaction.configuration, transaction.value)
    }

    func createWorkspace(name: String, rootTokens: [String]) throws -> HeadlessWorkspaceDocument {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw HeadlessCommandError("Workspace name must not be empty.", exitCode: 2)
        }

        return try configurationStore.withStateTransaction { config in
            try catalogMutationLoadedHook?()
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
            return workspace
        }.value
    }

    func selectWorkspace(token: String) throws -> HeadlessWorkspaceDocument {
        try configurationStore.withStateTransaction { config in
            try validateConfiguredRoots(config.allowedRoots)
            let workspaces = try workspaceStore.loadWorkspaces()
            let workspace = try resolveWorkspace(token: token, workspaces: workspaces)
            config.activeWorkspaceID = workspace.id
            return workspace
        }.value
    }

    func renameWorkspace(token: String?, newName: String) throws -> HeadlessWorkspaceDocument {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw HeadlessCommandError("Workspace name must not be empty.", exitCode: 2)
        }

        return try configurationStore.withStateTransaction { config in
            let state = try workspaceState(config: &config, requireWorkspace: true)
            guard let activeWorkspace = state.workspace else {
                throw HeadlessCommandError("No active workspace is available.", exitCode: 2)
            }
            let workspace = try token.map { try resolveWorkspace(token: $0, workspaces: state.workspaces) } ?? activeWorkspace
            guard !state.workspaces.contains(where: { $0.id != workspace.id && $0.name == trimmedName }) else {
                throw HeadlessCommandError("Workspace name already exists: \(trimmedName)", exitCode: 2)
            }
            return try workspaceStore.update(id: workspace.id) { document in
                document.name = trimmedName
            }
        }.value
    }

    func updateActiveWorkspace(_ body: (inout HeadlessWorkspaceDocument) throws -> Void) throws -> HeadlessWorkspaceDocument {
        try configurationStore.withStateTransaction { config in
            let state = try workspaceState(config: &config, requireWorkspace: true)
            guard let workspace = state.workspace else {
                throw HeadlessCommandError("No active workspace is available.", exitCode: 2)
            }
            return try workspaceStore.update(id: workspace.id, body)
        }.value
    }

    func replaceSelection(_ selection: [HeadlessSelectionEntry]) throws -> HeadlessWorkspaceDocument {
        try updateActiveWorkspace { workspace in
            workspace.selection = HeadlessSelectionNormalizer.normalized(selection)
        }
    }

    func updateSelection(
        workspaceID: UUID,
        _ body: (inout [HeadlessSelectionEntry]) throws -> Void
    ) throws -> HeadlessWorkspaceDocument {
        try configurationStore.withStateTransaction { config in
            let state = try workspaceState(config: &config, requireWorkspace: true)
            guard let activeWorkspace = state.workspace, activeWorkspace.id == workspaceID else {
                throw HeadlessCommandError("The active workspace changed before the selection mutation could commit.", exitCode: 2)
            }
            let activeRootIDs = Set(state.roots.map(\.id))
            return try workspaceStore.update(id: workspaceID) { workspace in
                try body(&workspace.selection)
                workspace.selection = HeadlessSelectionNormalizer.normalized(workspace.selection)
                guard workspace.selection.allSatisfy({ activeRootIDs.contains($0.rootID) }) else {
                    throw HeadlessCommandError("Selection references a root that is no longer active in the workspace.", exitCode: 2)
                }
            }
        }.value
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

    func export(
        _ data: Data,
        to requestedPath: String?,
        defaultFileName: String,
        permissions: HeadlessPermissions
    ) throws -> URL {
        try exportWriter.write(
            data,
            to: requestedPath,
            defaultFileName: defaultFileName,
            permissions: permissions
        )
    }

    private func workspaceState(
        config: inout HeadlessConfigurationDocument,
        requireWorkspace: Bool
    ) throws -> (workspace: HeadlessWorkspaceDocument?, roots: [HeadlessAllowedRoot], workspaces: [HeadlessWorkspaceDocument]) {
        try validateConfiguredRoots(config.allowedRoots)

        if config.allowedRoots.isEmpty {
            if requireWorkspace {
                throw HeadlessCommandError("No headless allowed roots are configured. Add one with `\(HeadlessVersion.executableName) --state-dir \(configurationStore.paths.rootDirectory.path) config roots add /absolute/path --name NAME`.", exitCode: 2)
            }
            return (nil, [], [])
        }

        let workspaces = try workspaceStore.loadWorkspaces()
        let active = try ensureActiveWorkspace(config: &config, workspaces: workspaces)
        let configuredRootIDs = Set(config.allowedRoots.map(\.id))
        let unknownRootIDs = Set(active.rootIDs)
            .subtracting(configuredRootIDs)
            .sorted { $0.uuidString < $1.uuidString }
        guard unknownRootIDs.isEmpty else {
            throw HeadlessCommandError(
                "Active workspace '\(active.name)' references unknown configured root IDs: \(unknownRootIDs.map(\.uuidString).joined(separator: ", ")).",
                exitCode: 2
            )
        }
        let activeRootIDs = Set(active.rootIDs)
        let roots = config.allowedRoots.filter { activeRootIDs.contains($0.id) }
        if roots.isEmpty, requireWorkspace {
            throw HeadlessCommandError("Active workspace '\(active.name)' has no configured roots. Create or select a workspace with configured root IDs/names.", exitCode: 2)
        }
        let catalog = workspaces.isEmpty ? [active] : workspaces
        return (active, roots, catalog)
    }

    private func ensureActiveWorkspace(
        config: inout HeadlessConfigurationDocument,
        workspaces: [HeadlessWorkspaceDocument]
    ) throws -> HeadlessWorkspaceDocument {
        if let activeID = config.activeWorkspaceID,
           let active = workspaces.first(where: { $0.id == activeID })
        {
            return active
        }
        if let first = workspaces.first {
            config.activeWorkspaceID = first.id
            return first
        }
        let created = try createDefaultWorkspace(for: config.allowedRoots)
        config.activeWorkspaceID = created.id
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
}
