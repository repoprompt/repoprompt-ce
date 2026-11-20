import RepoPromptDomainRuntime

extension DiffParser {
    convenience init(fileManager: WorkspaceFilesViewModel) {
        self.init(fileSource: WorkspaceDiffParserFileSource(fileManager: fileManager))
    }
}

/// Keeps UI-assisted lookup policy and the live FileViewModel read in the app.
private struct WorkspaceDiffParserFileSource: DiffParserFileSource {
    let fileManager: WorkspaceFilesViewModel

    func pathLocation(_ path: String, exactMatchOnly: Bool) async -> DiffParserFileLocation? {
        guard let location = await fileManager.pathLocation(path, exactMatchOnly: exactMatchOnly) else {
            return nil
        }
        return DiffParserFileLocation(
            rootPath: location.rootPath,
            correctedPath: location.correctedPath,
            rootIdentifier: location.rootIdentifier
        )
    }

    func readFile(at location: DiffParserFileLocation) async -> DiffParserFileContent? {
        guard let file = await fileManager.findFile(
            atPath: location.correctedPath,
            rootIdentifier: location.rootIdentifier
        ) else {
            return nil
        }
        return await DiffParserFileContent(content: file.latestContent)
    }
}
