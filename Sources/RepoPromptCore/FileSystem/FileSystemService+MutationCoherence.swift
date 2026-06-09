import Foundation

extension FileSystemService {
    private func mutationBackendOrThrow() throws -> any WorkspaceFileMutationBackend {
        guard let mutationBackend else { throw FileSystemError.mutationBackendUnavailable }
        return mutationBackend
    }

    private func mutationTarget(
        forRelativePath rawRelativePath: String,
        rejectExistingLeafSymlink: Bool = true
    ) throws -> (relativePath: String, url: URL) {
        guard !rawRelativePath.hasPrefix("/"), !StandardizedPath.containsNUL(rawRelativePath) else {
            throw FileSystemError.invalidRelativePath
        }
        let relativePath = StandardizedPath.relative(rawRelativePath)
        guard !relativePath.isEmpty, relativePath != "..", !relativePath.hasPrefix("../") else {
            throw FileSystemError.invalidRelativePath
        }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path != standardizedRootPath,
              StandardizedPath.isDescendant(url.path, of: standardizedRootPath)
        else { throw FileSystemError.invalidRelativePath }

        var current = rootURL
        for component in relativePath.split(separator: "/").dropLast() {
            current.appendPathComponent(String(component))
            guard !pathIsSymbolicLink(current) else { throw FileSystemError.invalidRelativePath }
            var isDirectory = ObjCBool(false)
            guard fm.fileExists(atPath: current.path, isDirectory: &isDirectory) else { break }
            guard isDirectory.boolValue else { throw FileSystemError.invalidRelativePath }
        }
        let canonicalParent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalParent == canonicalRootPath || StandardizedPath.isDescendant(canonicalParent, of: canonicalRootPath) else {
            throw FileSystemError.invalidRelativePath
        }
        if rejectExistingLeafSymlink, pathIsSymbolicLink(url) {
            throw FileSystemError.invalidRelativePath
        }
        return (relativePath, url)
    }

    private func pathIsSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func requireRegularMutationSource(relativePath: String) async throws {
        switch await catalogRegularFileEligibility(relativePath: relativePath) {
        case .eligible, .ineligible(.ignored): return
        case .ineligible(.missingOrDirectory): throw FileSystemError.fileNotFound
        case .ineligible: throw FileSystemError.invalidRelativePath
        }
    }

    package func createFile(atRelativePath relativePath: String, content: String) async throws {
        let backend = try mutationBackendOrThrow()
        let target = try mutationTarget(forRelativePath: relativePath)
        guard let data = content.data(using: .utf8) else {
            throw FileSystemError.failedToCreateFile(CocoaError(.fileWriteInapplicableStringEncoding))
        }
        do {
            try backend.createDirectory(at: target.url.deletingLastPathComponent())
            _ = try mutationTarget(forRelativePath: target.relativePath)
            var isDirectory = false
            guard !backend.fileExists(atPath: target.url.path, isDirectory: &isDirectory) else {
                throw FileSystemError.fileAlreadyExists
            }
            try backend.createFile(at: target.url, contents: data)
        } catch let error as FileSystemError {
            throw error
        } catch {
            throw FileSystemError.failedToCreateFile(error)
        }
        switch await catalogRegularFileEligibility(relativePath: target.relativePath) {
        case .eligible, .ineligible(.ignored): break
        case .ineligible:
            try? backend.removeItem(at: target.url)
            forgetTrackedPath(target.relativePath)
            throw FileSystemError.invalidRelativePath
        }
        encodingMap[target.relativePath] = .utf8
        visitedPaths.insert(target.relativePath)
        visitedItems[target.relativePath] = false
        publishFileSystemDeltas([.fileAdded(target.relativePath)], source: .syntheticMutation)
    }

    package func editFile(atRelativePath relativePath: String, newContent: String) async throws {
        let backend = try mutationBackendOrThrow()
        let target = try mutationTarget(forRelativePath: relativePath)
        try await requireRegularMutationSource(relativePath: target.relativePath)
        var isDirectory = false
        guard backend.fileExists(atPath: target.url.path, isDirectory: &isDirectory), !isDirectory else {
            throw FileSystemError.fileNotFound
        }
        let encoding = encodingMap[target.relativePath] ?? .utf8
        guard let data = newContent.data(using: encoding) else {
            throw FileSystemError.failedToEditFile(CocoaError(.fileWriteInapplicableStringEncoding))
        }
        do {
            try backend.write(data, to: target.url, atomically: true)
        } catch {
            throw FileSystemError.failedToEditFile(error)
        }
        switch await catalogRegularFileEligibility(relativePath: target.relativePath) {
        case .eligible, .ineligible(.ignored): break
        case .ineligible: throw FileSystemError.invalidRelativePath
        }
        encodingMap[target.relativePath] = encoding
        visitedPaths.insert(target.relativePath)
        visitedItems[target.relativePath] = false
        let modificationDate = try? backend.modificationDate(at: target.url)
        publishFileSystemDeltas([.fileModified(target.relativePath, modificationDate)], source: .syntheticMutation)
    }

    package func moveFile(atRelativePath oldPath: String, toRelativePath newPath: String) async throws {
        let backend = try mutationBackendOrThrow()
        let source = try mutationTarget(forRelativePath: oldPath)
        let destination = try mutationTarget(forRelativePath: newPath)
        try await requireRegularMutationSource(relativePath: source.relativePath)
        var isDirectory = false
        guard backend.fileExists(atPath: source.url.path, isDirectory: &isDirectory), !isDirectory else {
            throw FileSystemError.fileNotFound
        }
        guard !backend.fileExists(atPath: destination.url.path, isDirectory: &isDirectory) else {
            throw FileSystemError.fileAlreadyExists
        }
        do {
            try backend.createDirectory(at: destination.url.deletingLastPathComponent())
            _ = try mutationTarget(forRelativePath: destination.relativePath)
            try backend.moveItem(at: source.url, to: destination.url)
        } catch {
            throw FileSystemError.failedToCreateFile(error)
        }
        switch await catalogRegularFileEligibility(relativePath: destination.relativePath) {
        case .eligible, .ineligible(.ignored): break
        case .ineligible:
            try? backend.moveItem(at: destination.url, to: source.url)
            throw FileSystemError.invalidRelativePath
        }
        if let wasDirectory = visitedItems.removeValue(forKey: source.relativePath) {
            visitedItems[destination.relativePath] = wasDirectory
        }
        visitedPaths.remove(source.relativePath)
        visitedPaths.insert(destination.relativePath)
        if let encoding = encodingMap.removeValue(forKey: source.relativePath) {
            encodingMap[destination.relativePath] = encoding
        }
        publishFileSystemDeltas(
            [.fileRemoved(source.relativePath), .fileAdded(destination.relativePath)],
            source: .syntheticMutation
        )
    }

    package func deleteFile(atRelativePath relativePath: String) async throws {
        let backend = try mutationBackendOrThrow()
        let target = try mutationTarget(forRelativePath: relativePath)
        try await requireRegularMutationSource(relativePath: target.relativePath)
        do {
            try backend.removeItem(at: target.url)
        } catch {
            throw FileSystemError.failedToDeleteFile(error)
        }
        forgetTrackedPath(target.relativePath)
        publishFileSystemDeltas([.fileRemoved(target.relativePath)], source: .syntheticMutation)
    }

    package func moveItemToTrash(atRelativePath relativePath: String) async throws {
        let backend = try mutationBackendOrThrow()
        let target = try mutationTarget(forRelativePath: relativePath)
        var isDirectory = false
        guard backend.fileExists(atPath: target.url.path, isDirectory: &isDirectory) else {
            throw FileSystemError.fileNotFound
        }
        do {
            try backend.trashItem(at: target.url)
        } catch {
            throw FileSystemError.failedToDeleteFile(error)
        }
        encodingMap.keys
            .filter { $0 == target.relativePath || $0.hasPrefix(target.relativePath + "/") }
            .forEach { encodingMap.removeValue(forKey: $0) }
        var deltas = removeSubtree(for: target.relativePath)
        if deltas.isEmpty {
            deltas = [isDirectory ? .folderRemoved(target.relativePath) : .fileRemoved(target.relativePath)]
        }
        publishFileSystemDeltas(deltas, source: .syntheticMutation)
    }

    private func forgetTrackedPath(_ relativePath: String) {
        encodingMap.removeValue(forKey: relativePath)
        visitedPaths.remove(relativePath)
        visitedItems.removeValue(forKey: relativePath)
    }
}
