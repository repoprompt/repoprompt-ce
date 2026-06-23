import Foundation

extension FrozenFileRecord {
    init(from vm: FileViewModel) {
        self.init(
            name: vm.name,
            relativePath: vm.relativePath,
            fullPath: vm.standardizedFullPath,
            rootFolderPath: vm.standardizedRootFolderPath
        )
    }
}

extension FrozenFolderRecord {
    init(from vm: FolderViewModel) {
        self.init(
            name: vm.name,
            relativePath: vm.relativePath,
            fullPath: vm.standardizedFullPath,
            rootPath: vm.rootPath,
            displayName: vm.name
        )
    }
}
