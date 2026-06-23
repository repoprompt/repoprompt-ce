import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#else
    import Glibc
#endif

extension FileSystemService {
    // MARK: - File and folder manipulation utilities

    private func mutationTarget(
        forRelativePath rawRelativePath: String,
        rejectExistingLeafSymlink: Bool = true
    ) throws -> (relativePath: String, url: URL) {
        guard !rawRelativePath.hasPrefix("/"), !StandardizedPath.containsNUL(rawRelativePath) else {
            throw FileSystemError.invalidRelativePath
        }
        let relativePath = StandardizedPath.relative(rawRelativePath)
        guard !relativePath.isEmpty,
              relativePath != "..",
              !relativePath.hasPrefix("../")
        else {
            throw FileSystemError.invalidRelativePath
        }

        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path != standardizedRootPath,
              StandardizedPath.isDescendant(url.path, of: standardizedRootPath)
        else {
            throw FileSystemError.invalidRelativePath
        }

        var current = rootURL
        for component in relativePath.split(separator: "/").dropLast() {
            current.appendPathComponent(String(component))
            guard !pathIsSymbolicLink(current.path) else { throw FileSystemError.invalidRelativePath }
            var isDirectory = ObjCBool(false)
            guard fm.fileExists(atPath: current.path, isDirectory: &isDirectory) else { break }
            guard isDirectory.boolValue else { throw FileSystemError.invalidRelativePath }
        }

        let canonicalParentPath = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalParentPath == canonicalRootPath || StandardizedPath.isDescendant(canonicalParentPath, of: canonicalRootPath) else {
            throw FileSystemError.invalidRelativePath
        }
        if rejectExistingLeafSymlink, pathIsSymbolicLink(url.path) {
            throw FileSystemError.invalidRelativePath
        }
        return (relativePath, url)
    }

    private func pathIsSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFLNK
    }

    private func requireRegularMutationSource(relativePath: String) async throws {
        switch await catalogRegularFileEligibility(relativePath: relativePath) {
        case .eligible, .ineligible(.ignored):
            return
        case .ineligible(.missingOrDirectory):
            throw FileSystemError.fileNotFound
        case .ineligible:
            throw FileSystemError.invalidRelativePath
        }
    }

    /// Starts filesystem I/O that cannot be cancelled safely once handed to Foundation.
    ///
    /// Reconciliation contract: request cancellation only removes and resumes the actor-owned
    /// waiter. The detached monitor remains the sole completion owner and always reconciles the
    /// service caches plus synthetic delta publication against the eventual on-disk result.
    private func startUncancellableMutation(
        _ operation: FileSystemUncancellableMutation,
        io: @escaping @Sendable () throws -> Void
    ) -> (id: UUID, task: Task<Void, any Error>) {
        let id = UUID()
        #if DEBUG
            let willBegin = mutationIOWillBeginHandler
        #else
            let willBegin: (@Sendable (FileSystemUncancellableMutation) async -> Void)? = nil
        #endif
        let task = Task.detached(priority: .utility) {
            if let willBegin {
                await willBegin(operation)
            }
            try io()
        }
        return (id, task)
    }

    private func awaitUncancellableMutation(_ id: UUID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    mutationWaiters[id] = FileSystemMutationWaiter(continuation: continuation)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelMutationWaiter(id)
            }
        }
    }

    private func cancelMutationWaiter(_ id: UUID) {
        guard let waiter = mutationWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func completeMutationWaiter(_ id: UUID, error: (any Error)? = nil) {
        guard let waiter = mutationWaiters.removeValue(forKey: id) else { return }
        if let error {
            waiter.continuation.resume(throwing: error)
        } else {
            waiter.continuation.resume()
        }
    }

    /// Atomically move/rename a **file** inside the same root.
    func moveFile(
        atRelativePath oldRelPath: String,
        toRelativePath newRelPath: String
    ) async throws {
        try Task.checkCancellation()
        let fm = fm
        let oldTarget = try mutationTarget(forRelativePath: oldRelPath)
        let newTarget = try mutationTarget(forRelativePath: newRelPath)
        let oldFull = oldTarget.url.path
        let newFull = newTarget.url.path
        try await requireRegularMutationSource(relativePath: oldTarget.relativePath)
        try Task.checkCancellation()

        guard fm.fileExists(atPath: oldFull, isDirectory: nil) else {
            throw FileSystemError.fileNotFound
        }
        guard !fm.fileExists(atPath: newFull, isDirectory: nil) else {
            throw FileSystemError.fileAlreadyExists
        }

        let destDir = (newFull as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true, attributes: nil)
        _ = try mutationTarget(forRelativePath: newTarget.relativePath)

        let mutation = startUncancellableMutation(.move) {
            try FileManager.default.moveItem(atPath: oldFull, toPath: newFull)
        }
        Task.detached { [weak self] in
            do {
                try await mutation.task.value
                await self?.reconcileMovedFile(
                    mutationID: mutation.id,
                    oldRelativePath: oldTarget.relativePath,
                    newRelativePath: newTarget.relativePath,
                    oldFullPath: oldFull,
                    newFullPath: newFull
                )
            } catch {
                await self?.completeMutationWaiter(
                    mutation.id,
                    error: FileSystemError.failedToCreateFile(error)
                )
            }
        }
        try await awaitUncancellableMutation(mutation.id)
    }

    private func reconcileMovedFile(
        mutationID: UUID,
        oldRelativePath: String,
        newRelativePath: String,
        oldFullPath: String,
        newFullPath: String
    ) async {
        switch await catalogRegularFileEligibility(relativePath: newRelativePath) {
        case .eligible, .ineligible(.ignored):
            break
        case .ineligible:
            do {
                try await Task.detached(priority: .utility) {
                    try FileManager.default.moveItem(atPath: newFullPath, toPath: oldFullPath)
                }.value
            } catch {
                forgetTrackedPath(oldRelativePath)
                publishFileSystemDeltas(
                    [.fileRemoved(oldRelativePath), .fileAdded(newRelativePath)],
                    source: .syntheticMutation
                )
            }
            completeMutationWaiter(mutationID, error: FileSystemError.invalidRelativePath)
            return
        }

        if let wasDirectory = visitedItems.removeValue(forKey: oldRelativePath) {
            visitedItems[newRelativePath] = wasDirectory
        }
        visitedPaths.remove(oldRelativePath)
        visitedPaths.insert(newRelativePath)
        if let encoding = encodingMap.removeValue(forKey: oldRelativePath) {
            encodingMap[newRelativePath] = encoding
        }
        publishFileSystemDeltas(
            [.fileRemoved(oldRelativePath), .fileAdded(newRelativePath)],
            source: .syntheticMutation
        )
        completeMutationWaiter(mutationID)
    }

    func createFile(atRelativePath relativePath: String, content: String) async throws {
        try Task.checkCancellation()
        let fm = fm
        let target = try mutationTarget(forRelativePath: relativePath)
        let fullPath = target.url.path
        let fullURL = target.url

        let directoryURL = fullURL.deletingLastPathComponent()
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        _ = try mutationTarget(forRelativePath: target.relativePath)
        guard !fm.fileExists(atPath: fullPath, isDirectory: nil) else {
            throw FileSystemError.fileAlreadyExists
        }
        guard let data = content.data(using: .utf8) else {
            throw FileSystemError.failedToCreateFile(
                NSError(
                    domain: "encoding",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to encode text as UTF-8"]
                )
            )
        }

        let mutation = startUncancellableMutation(.create) {
            try FileSystemService.writeFileRobust(to: fullURL, data: data)
        }
        Task.detached { [weak self] in
            do {
                try await mutation.task.value
                await self?.reconcileCreatedFile(
                    mutationID: mutation.id,
                    relativePath: target.relativePath,
                    url: fullURL
                )
            } catch {
                await self?.completeMutationWaiter(
                    mutation.id,
                    error: FileSystemError.failedToCreateFile(error)
                )
            }
        }
        try await awaitUncancellableMutation(mutation.id)
    }

    private func reconcileCreatedFile(
        mutationID: UUID,
        relativePath: String,
        url: URL
    ) async {
        fileSystemDebugLog("File created at \(url.path)")
        switch await catalogRegularFileEligibility(relativePath: relativePath) {
        case .eligible, .ineligible(.ignored):
            break
        case .ineligible:
            _ = try? await Task.detached(priority: .utility) {
                try FileManager.default.removeItem(at: url)
            }.value
            forgetTrackedPath(relativePath)
            completeMutationWaiter(mutationID, error: FileSystemError.invalidRelativePath)
            return
        }

        encodingMap[relativePath] = .utf8
        visitedPaths.insert(relativePath)
        visitedItems[relativePath] = false
        publishFileSystemDeltas([.fileAdded(relativePath)], source: .syntheticMutation)
        completeMutationWaiter(mutationID)
    }

    func deleteFile(atRelativePath relativePath: String) async throws {
        try Task.checkCancellation()
        let target = try mutationTarget(forRelativePath: relativePath)
        try await requireRegularMutationSource(relativePath: target.relativePath)
        try Task.checkCancellation()
        let url = target.url
        let mutation = startUncancellableMutation(.delete) {
            try FileManager.default.removeItem(at: url)
        }
        Task.detached { [weak self] in
            do {
                try await mutation.task.value
                await self?.reconcileDeletedFile(
                    mutationID: mutation.id,
                    relativePath: target.relativePath,
                    url: url
                )
            } catch {
                await self?.completeMutationWaiter(
                    mutation.id,
                    error: FileSystemError.failedToDeleteFile(error)
                )
            }
        }
        try await awaitUncancellableMutation(mutation.id)
    }

    private func reconcileDeletedFile(mutationID: UUID, relativePath: String, url: URL) {
        fileSystemDebugLog("File deleted at \(url.path)")
        forgetTrackedPath(relativePath)
        publishFileSystemDeltas([.fileRemoved(relativePath)], source: .syntheticMutation)
        completeMutationWaiter(mutationID)
    }

    func moveItemToTrash(atRelativePath relativePath: String) async throws {
        try Task.checkCancellation()
        let target = try mutationTarget(forRelativePath: relativePath)
        let normalizedRelativePath = target.relativePath
        let url = target.url
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw FileSystemError.fileNotFound
        }
        let wasDirectory = isDirectory.boolValue

        #if DEBUG
            let moveItemToTrashIO = moveItemToTrashIOForTesting ?? { url in
                _ = try Self.moveURLToTrashOffActor(url)
            }
        #else
            let moveItemToTrashIO: @Sendable (URL) throws -> Void = { url in
                _ = try Self.moveURLToTrashOffActor(url)
            }
        #endif
        let mutation = startUncancellableMutation(.trash) {
            try moveItemToTrashIO(url)
        }
        Task.detached { [weak self] in
            do {
                try await mutation.task.value
                await self?.reconcileTrashedItem(
                    mutationID: mutation.id,
                    relativePath: normalizedRelativePath,
                    url: url,
                    wasDirectory: wasDirectory
                )
            } catch {
                await self?.completeMutationWaiter(
                    mutation.id,
                    error: FileSystemError.failedToDeleteFile(error)
                )
            }
        }
        try await awaitUncancellableMutation(mutation.id)
    }

    private func reconcileTrashedItem(
        mutationID: UUID,
        relativePath: String,
        url: URL,
        wasDirectory: Bool
    ) {
        fileSystemDebugLog("File moved to Trash at \(url.path)")
        let keysToForget = encodingMap.keys.filter {
            $0 == relativePath || $0.hasPrefix(relativePath + "/")
        }
        for key in keysToForget {
            encodingMap.removeValue(forKey: key)
        }

        var deltas = removeSubtree(for: relativePath)
        if deltas.isEmpty {
            deltas = [wasDirectory ? .folderRemoved(relativePath) : .fileRemoved(relativePath)]
        }
        publishFileSystemDeltas(deltas, source: .syntheticMutation)
        completeMutationWaiter(mutationID)
    }

    private func forgetTrackedPath(_ relativePath: String) {
        encodingMap.removeValue(forKey: relativePath)
        visitedPaths.remove(relativePath)
        visitedItems.removeValue(forKey: relativePath)
    }

    private nonisolated static func moveURLToTrashOffActor(_ url: URL) throws -> URL? {
        var resultingItemURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingItemURL)
        return resultingItemURL as URL?
    }

    func editFile(atRelativePath relativePath: String, newContent: String) async throws {
        _ = try await editFile(
            atRelativePath: relativePath,
            newContent: newContent,
            modificationPublicationPolicy: .publishSyntheticModification
        )
    }

    func editFile(
        atRelativePath relativePath: String,
        newContent: String,
        modificationPublicationPolicy: FileSystemEditModificationPublicationPolicy
    ) async throws -> FileSystemDeferredEditPublicationToken? {
        try Task.checkCancellation()
        let target = try mutationTarget(forRelativePath: relativePath)
        let fullPath = target.url.path
        let fullURL = target.url
        guard fm.fileExists(atPath: fullPath, isDirectory: nil) else {
            throw FileSystemError.fileNotFound
        }
        switch await catalogRegularFileEligibility(relativePath: target.relativePath) {
        case .eligible, .ineligible(.ignored):
            break
        case .ineligible(.missingOrDirectory):
            throw FileSystemError.fileNotFound
        case .ineligible:
            throw FileSystemError.invalidRelativePath
        }
        try Task.checkCancellation()

        let encoding = encodingMap[target.relativePath] ?? .utf8
        guard let data = newContent.data(using: encoding) else {
            throw FileSystemError.failedToEditFile(
                NSError(
                    domain: "encoding",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to encode text as \(encoding)"]
                )
            )
        }

        let mutation = startUncancellableMutation(.edit) {
            try FileSystemService.writeFileRobust(to: fullURL, data: data)
        }
        Task.detached { [weak self] in
            do {
                try await mutation.task.value
                await self?.reconcileEditedFile(
                    mutationID: mutation.id,
                    relativePath: target.relativePath,
                    encoding: encoding,
                    modificationPublicationPolicy: modificationPublicationPolicy
                )
            } catch {
                await self?.completeMutationWaiter(
                    mutation.id,
                    error: FileSystemError.failedToEditFile(error)
                )
            }
        }
        try await awaitUncancellableMutation(mutation.id)
        guard modificationPublicationPolicy == .deferSyntheticModificationToSuccessfulCaller,
              deferredEditPublicationsByMutationID[mutation.id] != nil
        else { return nil }
        return FileSystemDeferredEditPublicationToken(
            serviceToken: diagnosticRootToken,
            mutationID: mutation.id
        )
    }

    private func reconcileEditedFile(
        mutationID: UUID,
        relativePath: String,
        encoding: String.Encoding,
        modificationPublicationPolicy: FileSystemEditModificationPublicationPolicy
    ) async {
        switch await catalogRegularFileEligibility(relativePath: relativePath) {
        case .eligible, .ineligible(.ignored):
            break
        case .ineligible:
            forgetTrackedPath(relativePath)
            publishFileSystemDeltas([.fileRemoved(relativePath)], source: .syntheticMutation)
            completeMutationWaiter(mutationID, error: FileSystemError.invalidRelativePath)
            return
        }

        encodingMap[relativePath] = encoding
        visitedPaths.insert(relativePath)
        visitedItems[relativePath] = false
        let modificationDate = try? await getFileModificationDate(atRelativePath: relativePath)
        let deferredPublication = FileSystemDeferredEditPublication(
            relativePath: relativePath,
            modificationDate: modificationDate
        )
        switch modificationPublicationPolicy {
        case .publishSyntheticModification:
            publishDeferredEditPublication(deferredPublication)
        case .deferSyntheticModificationToSuccessfulCaller:
            guard mutationWaiters[mutationID] != nil else {
                publishDeferredEditPublication(deferredPublication)
                return
            }
            deferredEditPublicationsByMutationID[mutationID] = deferredPublication
        }
        completeMutationWaiter(mutationID)
    }

    func resolveDeferredEditPublication(
        _ token: FileSystemDeferredEditPublicationToken,
        resolution: FileSystemDeferredEditPublicationResolution
    ) {
        guard token.serviceToken == diagnosticRootToken,
              let publication = deferredEditPublicationsByMutationID.removeValue(forKey: token.mutationID)
        else { return }
        if resolution == .publishSyntheticFallback {
            publishDeferredEditPublication(publication)
        }
    }

    private func publishDeferredEditPublication(_ publication: FileSystemDeferredEditPublication) {
        publishFileSystemDeltas(
            [.fileModified(publication.relativePath, publication.modificationDate)],
            source: .syntheticMutation
        )
    }

    func checkFilePermissions(atRelativePath relativePath: String) -> Bool {
        let fullPath = fullPath(forRelativePath: relativePath)
        return fm.isWritableFile(atPath: fullPath)
    }

    func getFileModificationDate(atRelativePath relativePath: String) async throws -> Date {
        let lookupState = EditFlowPerf.begin(
            EditFlowPerf.Stage.FileSystem.contentModificationDateLookup,
            EditFlowPerf.Dimensions(rootToken: diagnosticRootToken.uuidString)
        )
        defer { EditFlowPerf.end(EditFlowPerf.Stage.FileSystem.contentModificationDateLookup, lookupState) }
        let fullPath = fullPath(forRelativePath: relativePath)
        let attributes = try fm.attributesOfItem(atPath: fullPath)
        return attributes[.modificationDate] as? Date ?? Date()
    }

    func getItemModificationDateIfAvailable(atRelativePath relativePath: String) async -> Date? {
        let fullPath = fullPath(forRelativePath: relativePath)
        guard let attributes = try? fm.attributesOfItem(atPath: fullPath) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    private static func writeFile(
        to url: URL,
        data: Data
    ) throws {
        try data.write(to: url, options: .atomic) // blocking write
    }

    /// Robust write that works across external/network volumes:
    /// 1) try atomic write
    /// 2) write to temp in the same directory then move into place (delete destination if needed)
    /// 3) POSIX open(O_CREAT|O_TRUNC)+write+fsync fallback
    private static func writeFileRobust(
        to url: URL,
        data: Data
    ) throws {
        // Fast path: try Foundation's atomic write first.
        do {
            try data.write(to: url, options: [.atomic])
            return
        } catch {
            // fall through to robust fallbacks
        }

        let fm = FileManager.default
        let dirURL = url.deletingLastPathComponent()
        let tmpURL = dirURL.appendingPathComponent(".repoprompt.tmp.\(UUID().uuidString)")

        // Fallback #1: write to temp in the same directory then move/replace.
        do {
            try data.write(to: tmpURL, options: [])
            if fm.fileExists(atPath: url.path) {
                // Removing the destination first avoids exchange/rename restrictions on some filesystems
                // (exFAT/SMB may reject replace semantics).
                try? fm.removeItem(at: url)
            }
            try fm.moveItem(at: tmpURL, to: url)
            return
        } catch {
            // Clean up temp if it remains
            try? fm.removeItem(at: tmpURL)
        }

        // Fallback #2: POSIX open/write/fsync.
        try writeFilePOSIX(to: url, data: data)
    }

    /// Low-level write that avoids Foundation's atomic/replace semantics entirely.
    private static func writeFilePOSIX(
        to url: URL,
        data: Data
    ) throws {
        let path = url.path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd == -1 {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "open() failed for \(path) (\(code))"]
            )
        }

        var writeError: Int32 = 0
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard var base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = data.count
            while remaining > 0 {
                let n = Darwin.write(fd, base, remaining)
                if n < 0 {
                    writeError = errno
                    break
                }
                remaining -= n
                base = base.advanced(by: n)
            }
        }

        if writeError == 0 {
            if fsync(fd) != 0 {
                writeError = errno
            }
        }

        // Always attempt to close; prefer first error if any.
        let closeResult = close(fd)
        if writeError != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(writeError),
                userInfo: [NSLocalizedDescriptionKey: "write/fsync failed for \(path) (\(writeError))"]
            )
        }
        if closeResult != 0 {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "close() failed for \(path) (\(code))"]
            )
        }
    }
}
