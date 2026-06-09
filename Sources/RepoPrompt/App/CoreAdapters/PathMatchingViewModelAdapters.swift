import RepoPromptCore

extension FrozenFileRecord {
    init(from viewModel: FileViewModel) {
        self.init(
            name: viewModel.name,
            relativePath: viewModel.relativePath,
            fullPath: viewModel.standardizedFullPath,
            rootFolderPath: viewModel.standardizedRootFolderPath
        )
    }
}

extension FrozenFolderRecord {
    init(from viewModel: FolderViewModel) {
        self.init(
            name: viewModel.name,
            relativePath: viewModel.relativePath,
            fullPath: viewModel.standardizedFullPath,
            rootPath: viewModel.rootPath,
            displayName: viewModel.name
        )
    }
}
