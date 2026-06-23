import Foundation

enum WorkspaceFileCreatePathResolutionPolicy {
    case literalPreferredIfStronger
    case canonicalAliasFirst
}

struct WorkspaceFileMutationWriteResult: Equatable {
    let diskSucceeded: Bool
    let materializedFile: WorkspaceFileRecord?
    let catalogIneligibility: CatalogRegularFileIneligibilityReason?

    var catalogMaterialized: Bool {
        materializedFile != nil
    }

    static func fromCatalogMaterialization(_ result: WorkspaceFileCatalogMaterializationResult) -> WorkspaceFileMutationWriteResult {
        switch result {
        case let .materialized(file):
            WorkspaceFileMutationWriteResult(diskSucceeded: true, materializedFile: file, catalogIneligibility: nil)
        case let .ineligible(reason):
            WorkspaceFileMutationWriteResult(diskSucceeded: true, materializedFile: nil, catalogIneligibility: reason)
        }
    }
}

struct WorkspaceFileMutationService {
    let store: WorkspaceFileContextStore

    func exactExistingFile(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceFileRecord? {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if await store.exactPathResolutionIssue(for: trimmed, kind: .file, rootScope: rootScope) != nil {
            guard await store.pruneMissingCatalogFilesForExactMutationLookup(trimmed, rootScope: rootScope) else { return nil }
            guard await store.exactPathResolutionIssue(for: trimmed, kind: .file, rootScope: rootScope) == nil else { return nil }
        }
        switch await store.lookupCatalogFileForExplicitRequest(trimmed, rootScope: rootScope) {
        case let .matched(file):
            return await store.validateCatalogFileStillPresent(file)
        case .ambiguous, .blocked:
            return nil
        case .noCandidate:
            break
        }
        switch try? await store.materializeExplicitlyRequestedFile(trimmed, rootScope: rootScope) {
        case let .some(.materialized(file)):
            return await store.validateCatalogFileStillPresent(file)
        case .some(.ambiguous), .some(.blocked):
            return nil
        case .some(.noCandidate), .none:
            break
        }
        guard let file = await store.lookupPath(
            WorkspacePathLookupRequest(userPath: trimmed, profile: .moveSourceExact, rootScope: rootScope)
        )?.file else { return nil }
        return await store.validateCatalogFileStillPresent(file)
    }

    func resolveExactExistingFileForMutation(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws -> WorkspaceFileRecord {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let file = await exactExistingFile(trimmed, rootScope: rootScope) {
            return file
        }
        switch try? await store.materializeExplicitlyRequestedFile(trimmed, rootScope: rootScope) {
        case let .some(.materialized(file)):
            if let current = await store.validateCatalogFileStillPresent(file) { return current }
        case .some(.ambiguous):
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                "Path '\(userPath)' matches multiple workspace roots. Use a root-qualified or absolute path."
            )
        case .some(.blocked):
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Unsafe workspace file path: \(userPath).")
        case .some(.noCandidate), .none:
            break
        }
        if let issue = await store.exactPathResolutionIssue(for: trimmed, kind: .file, rootScope: rootScope) {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(PathResolutionIssueRenderer.message(for: issue))
        }
        throw FileManagerError.fileSystemServiceNotFoundWithContext("Unknown or unloaded path: \(userPath).")
    }

    func readText(file: WorkspaceFileRecord) async throws -> String? {
        try await store.readContent(rootID: file.rootID, relativePath: file.standardizedRelativePath)
    }

    @discardableResult
    func overwrite(file: WorkspaceFileRecord, content: String) async throws -> WorkspaceFileMutationWriteResult {
        let result = try await store.editFile(rootID: file.rootID, relativePath: file.standardizedRelativePath, newContent: content)
        if let result {
            return .fromCatalogMaterialization(result)
        }
        return WorkspaceFileMutationWriteResult(diskSucceeded: true, materializedFile: nil, catalogIneligibility: nil)
    }

    func createFile(
        userPath: String,
        content: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        selectedFileFullPaths: Set<String> = [],
        pathResolutionPolicy: WorkspaceFileCreatePathResolutionPolicy = .literalPreferredIfStronger
    ) async throws -> WorkspaceFileRecord {
        let result = try await createFileWithPostcondition(
            userPath: userPath,
            content: content,
            rootScope: rootScope,
            selectedFileFullPaths: selectedFileFullPaths,
            pathResolutionPolicy: pathResolutionPolicy
        )
        if let file = result.materializedFile {
            return file
        }
        let reason = result.catalogIneligibility?.description ?? "no catalog record was returned"
        throw FileManagerError.fileSystemServiceNotFoundWithContext(
            "File creation succeeded on disk, but RepoPrompt did not add it to the workspace catalog: \(reason)."
        )
    }

    func createFileWithPostcondition(
        userPath: String,
        content: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        selectedFileFullPaths: Set<String> = [],
        pathResolutionPolicy: WorkspaceFileCreatePathResolutionPolicy = .literalPreferredIfStronger
    ) async throws -> WorkspaceFileMutationWriteResult {
        guard await store.rootScopeAvailability(rootScope) == .available else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                "The session-bound workspace scope is unavailable. File creation stopped rather than using a replacement root."
            )
        }
        let roots = await store.rootRefs(scope: rootScope)
        let preflight: CreatePathPreflight.Result
        do {
            preflight = try CreatePathPreflight.validate(
                userPath: userPath,
                visibleRoots: roots,
                mode: .allowImplicitRootIfUnambiguous
            )
        } catch let error as CreatePathPreflight.Error {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(Self.message(for: error))
        }

        let standardizedInput = preflight.normalizedPath
        if pathResolutionPolicy == .literalPreferredIfStronger,
           let literal = await resolvedLiteralCreateResult(for: standardizedInput, preflight: preflight, rootScope: rootScope)
        {
            return try await createWithPostcondition(
                using: literal,
                userPath: userPath,
                content: content,
                rootScope: rootScope
            )
        }

        if let folder = await exactExistingFolder(standardizedInput, rootScope: rootScope) {
            let displayPath = await displayPath(for: folder, rootScope: rootScope)
            throw FileManagerError.fileSystemServiceNotFoundWithContext("'\(displayPath)' resolves to a folder. Provide a file path.")
        }
        if let existing = await exactExistingFile(standardizedInput, rootScope: rootScope) {
            throw await FileManagerError.fileSystemServiceNotFoundWithContext("path already exists: \(displayPath(for: existing, rootScope: rootScope))")
        }

        let needsUnambiguousResolution =
            !preflight.isAbsolute &&
            preflight.aliasCheck == .notPrefixed &&
            roots.count > 1
        let resolutionMode: CreationResolutionMode = needsUnambiguousResolution ? .requireUnambiguous : .bestEffort
        guard let resolution = await store.resolveCreationPath(
            userPath: standardizedInput,
            rootScope: rootScope,
            selectedFileFullPaths: selectedFileFullPaths,
            mode: resolutionMode
        ) else {
            let rootsList = roots.map(\.name).joined(separator: ", ")
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                "Could not resolve a destination within the current workspace for '\(userPath)'. Loaded roots: \(rootsList)."
            )
        }

        switch resolution {
        case let .ambiguous(candidateRootPaths):
            let rootNames = candidateRootPaths.compactMap { path in
                roots.first { $0.standardizedFullPath == StandardizedPath.absolute(path) }?.name
            }
            let candidates = rootNames.isEmpty
                ? candidateRootPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                : rootNames.joined(separator: ", ")
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                "Path '\(userPath)' could match multiple workspace roots: \(candidates). Please disambiguate using 'RootName/\(userPath)' or provide an absolute path."
            )
        case let .unique(result):
            return try await createWithPostcondition(
                using: result,
                userPath: userPath,
                content: content,
                rootScope: rootScope
            )
        }
    }

    private func createWithPostcondition(
        using result: FileCreationResult,
        userPath: String,
        content: String,
        rootScope: WorkspaceLookupRootScope
    ) async throws -> WorkspaceFileMutationWriteResult {
        guard await store.rootScopeAvailability(rootScope) == .available else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                "The session-bound workspace scope changed during path resolution. File creation stopped rather than using a replacement root."
            )
        }
        let rootPath = StandardizedPath.absolute(result.rootFolder.rootPath)
        guard let root = await store.rootRefs(scope: rootScope).first(where: { $0.standardizedFullPath == rootPath }) else {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("Internal error: computed creation root is not currently loaded.")
        }
        let relativePath = StandardizedPath.relative(result.componentsToCreate.joined(separator: "/"))
        let absolutePath = StandardizedPath.join(standardizedRoot: root.standardizedFullPath, standardizedRelativePath: relativePath)
        if let folder = await exactExistingFolder(absolutePath, rootScope: rootScope) {
            throw await FileManagerError.fileSystemServiceNotFoundWithContext("'\(displayPath(for: folder, rootScope: rootScope))' resolves to a folder. Provide a file path.")
        }
        if await exactExistingFile(absolutePath, rootScope: rootScope) != nil {
            throw FileManagerError.fileSystemServiceNotFoundWithContext("path already exists: \(userPath)")
        }
        let result = try await store.createFile(
            rootID: root.id,
            relativePath: relativePath,
            content: content,
            validating: rootScope
        )
        return .fromCatalogMaterialization(result)
    }

    private func exactExistingFolder(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspaceFolderRecord? {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard await store.exactPathResolutionIssue(for: trimmed, kind: .folder, rootScope: rootScope) == nil else { return nil }
        return await store.lookupPath(
            WorkspacePathLookupRequest(userPath: trimmed, profile: .moveSourceExact, rootScope: rootScope)
        )?.folder
    }

    private func resolvedLiteralCreateResult(
        for normalizedUserPath: String,
        preflight: CreatePathPreflight.Result,
        rootScope: WorkspaceLookupRootScope
    ) async -> FileCreationResult? {
        guard !preflight.isAbsolute else { return nil }
        guard case let .uniqueRoot(root, alias) = preflight.aliasCheck else { return nil }
        let aliasRelativePath = StandardizedPath.relative(alias)
        guard await store.folder(rootID: root.id, relativePath: aliasRelativePath) != nil else { return nil }

        let components = StandardizedPath.relative(normalizedUserPath).split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let remainderDirComponents = Array(components.dropFirst().dropLast())
        let aliasDepth = await deepestExistingFolderPrefixDepth(for: remainderDirComponents, rootID: root.id)
        let literalDepth = await 1 + deepestExistingFolderPrefixDepth(
            for: remainderDirComponents,
            rootID: root.id,
            baseRelativePath: aliasRelativePath
        )
        guard literalDepth > aliasDepth else { return nil }

        let literalComponents = [aliasRelativePath] + Array(components.dropFirst())
        return FileCreationResult(
            rootFolder: FrozenFolderRecord(name: root.name, relativePath: "", fullPath: root.standardizedFullPath, rootPath: root.standardizedFullPath),
            componentsToCreate: literalComponents
        )
    }

    private func deepestExistingFolderPrefixDepth(
        for components: [String],
        rootID: UUID,
        baseRelativePath: String = ""
    ) async -> Int {
        guard !components.isEmpty else { return 0 }
        var matchedDepth = 0
        var currentRelativePath = StandardizedPath.relative(baseRelativePath)
        for component in components {
            let nextRelativePath = currentRelativePath.isEmpty ? component : currentRelativePath + "/" + component
            guard await store.folder(rootID: rootID, relativePath: nextRelativePath) != nil else { break }
            matchedDepth += 1
            currentRelativePath = nextRelativePath
        }
        return matchedDepth
    }

    private func displayPath(for file: WorkspaceFileRecord, rootScope: WorkspaceLookupRootScope) async -> String {
        await ClientPathFormatter.displayAbsolutePath(fullPath: file.standardizedFullPath, visibleRoots: store.rootRefs(scope: rootScope))
    }

    private func displayPath(for folder: WorkspaceFolderRecord, rootScope: WorkspaceLookupRootScope) async -> String {
        await ClientPathFormatter.displayAbsolutePath(fullPath: folder.standardizedFullPath, visibleRoots: store.rootRefs(scope: rootScope))
    }

    private static func message(for error: CreatePathPreflight.Error) -> String {
        switch error {
        case .emptyPath:
            return "path is required for file creation."
        case let .ambiguousAlias(alias, matchingRoots):
            let rendered = matchingRoots.map(\.renderedLabel).joined(separator: "; ")
            return "Ambiguous root alias '\(alias)'. It matches multiple loaded roots: \(rendered). Use an absolute path or rename roots so aliases are unique."
        case let .missingAliasWithMultipleRoots(loadedRoots):
            let rootsList = loadedRoots.map(\.renderedLabel).joined(separator: "; ")
            return "Multiple workspace roots are loaded; new files must use either an absolute path inside a loaded root (e.g., '/path/to/root/new_file.swift') or a root-alias prefixed path 'RootName/...'. Loaded roots: \(rootsList)"
        }
    }
}
