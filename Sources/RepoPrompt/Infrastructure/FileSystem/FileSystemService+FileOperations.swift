import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#else
    import Glibc
#endif

private let fileSystemMutationIOQueue = DispatchQueue(
    label: "com.repoprompt.filesystem-mutation-io",
    qos: .utility,
    attributes: .concurrent
)

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
    /// Blocking calls run on a dispatch queue so slow writes do not occupy Swift's cooperative executor.
    ///
    /// Reconciliation contract: request cancellation only removes and resumes the actor-owned
    /// waiter. The detached monitor remains the sole completion owner and always reconciles the
    /// service caches plus synthetic delta publication against the eventual on-disk result.
    private func startUncancellableMutation(
        _ operation: FileSystemUncancellableMutation,
        relativePaths: Set<String>,
        io: @escaping @Sendable () throws -> Void
    ) throws -> (id: UUID, task: Task<Void, any Error>) {
        let authorityPaths = mutationAuthorityPaths(relativePaths)
        guard !hasInFlightMutation(conflictingWith: authorityPaths) else {
            throw FileSystemError.mutationInProgress
        }
        let id = UUID()
        inFlightMutations[id] = FileSystemInFlightMutation(relativePaths: authorityPaths)
        #if DEBUG
            let willBegin = mutationIOWillBeginHandler
            let willExecute = mutationIOWillExecuteHandler
        #else
            let willBegin: (@Sendable (FileSystemUncancellableMutation) async -> Void)? = nil
            let willExecute: (@Sendable (FileSystemUncancellableMutation) -> Void)? = nil
        #endif
        let task = Task.detached(priority: .utility) {
            if let willBegin {
                await willBegin(operation)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                fileSystemMutationIOQueue.async {
                    willExecute?(operation)
                    do {
                        try io()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
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

    private func completeMutation(_ id: UUID, error: (any Error)? = nil) {
        if let waiter = mutationWaiters.removeValue(forKey: id) {
            if let error {
                waiter.continuation.resume(throwing: error)
            } else {
                waiter.continuation.resume()
            }
        }
        guard inFlightMutations.removeValue(forKey: id) != nil else { return }
        #if DEBUG
            completedMutationMonitorCountForTesting += 1
        #endif
        resumeDrainedMutationWaiters()
    }

    private func mutationAuthorityPaths(_ relativePaths: Set<String>) -> Set<String> {
        Set(relativePaths.map { relativePath in
            let normalized = relativePath.precomposedStringWithCanonicalMapping
            guard !mutationAuthorityUsesCaseSensitiveNames else { return normalized }
            return normalized.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        })
    }

    private func hasInFlightMutation(conflictingWith authorityPaths: Set<String>) -> Bool {
        inFlightMutations.values.contains { mutation in
            Self.pathsOverlap(mutation.relativePaths, authorityPaths)
        }
    }

    private nonisolated static func pathsOverlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        lhs.contains { left in
            rhs.contains { right in
                left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
            }
        }
    }

    func awaitMutationDrain(conflictingWith relativePaths: Set<String>) async {
        let authorityPaths = mutationAuthorityPaths(relativePaths)
        guard hasInFlightMutation(conflictingWith: authorityPaths) else { return }
        await withCheckedContinuation { continuation in
            let id = UUID()
            mutationDrainWaiters[id] = FileSystemMutationDrainWaiter(
                relativePaths: authorityPaths,
                continuation: continuation
            )
        }
    }

    private func resumeDrainedMutationWaiters() {
        let drained = mutationDrainWaiters.filter { _, waiter in
            !hasInFlightMutation(conflictingWith: waiter.relativePaths)
        }
        for (id, waiter) in drained {
            mutationDrainWaiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    private nonisolated static func performBlockingMutationIO(
        _ io: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            fileSystemMutationIOQueue.async {
                do {
                    try io()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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

        let rootPath = canonicalRootPath
        let mutation = try startUncancellableMutation(
            .move,
            relativePaths: [oldTarget.relativePath, newTarget.relativePath]
        ) {
            try FileSystemService.moveFileSecurely(
                rootPath: rootPath,
                fromRelativePath: oldTarget.relativePath,
                toRelativePath: newTarget.relativePath,
                createDestinationParents: true
            )
        }
        Task.detached { [weak self] in
            do {
                try await mutation.task.value
                await self?.reconcileMovedFile(
                    mutationID: mutation.id,
                    oldRelativePath: oldTarget.relativePath,
                    newRelativePath: newTarget.relativePath
                )
            } catch {
                await self?.completeMutation(
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
        newRelativePath: String
    ) async {
        switch await catalogRegularFileEligibility(relativePath: newRelativePath) {
        case .eligible, .ineligible(.ignored):
            break
        case .ineligible:
            let rootPath = canonicalRootPath
            do {
                try await Self.performBlockingMutationIO {
                    try FileSystemService.moveFileSecurely(
                        rootPath: rootPath,
                        fromRelativePath: newRelativePath,
                        toRelativePath: oldRelativePath,
                        createDestinationParents: false
                    )
                }
            } catch {
                forgetTrackedPath(oldRelativePath)
                publishFileSystemDeltas(
                    [.fileRemoved(oldRelativePath), .fileAdded(newRelativePath)],
                    source: .syntheticMutation
                )
            }
            completeMutation(mutationID, error: FileSystemError.invalidRelativePath)
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
        completeMutation(mutationID)
    }

    func createFile(atRelativePath relativePath: String, content: String) async throws {
        try Task.checkCancellation()
        let fm = fm
        let target = try mutationTarget(forRelativePath: relativePath)
        let fullPath = target.url.path
        let fullURL = target.url

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

        let rootPath = canonicalRootPath
        let mutation = try startUncancellableMutation(
            .create,
            relativePaths: [target.relativePath]
        ) {
            try FileSystemService.writeFileNoReplace(
                rootPath: rootPath,
                relativePath: target.relativePath,
                data: data
            )
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
                await self?.completeMutation(
                    mutation.id,
                    error: FileSystemService.normalizedCreateError(error)
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
            let rootPath = canonicalRootPath
            _ = try? await Self.performBlockingMutationIO {
                try FileSystemService.removeSecureMutationItem(
                    rootPath: rootPath,
                    relativePath: relativePath
                )
            }
            forgetTrackedPath(relativePath)
            completeMutation(mutationID, error: FileSystemError.invalidRelativePath)
            return
        }

        encodingMap[relativePath] = .utf8
        visitedPaths.insert(relativePath)
        visitedItems[relativePath] = false
        publishFileSystemDeltas([.fileAdded(relativePath)], source: .syntheticMutation)
        completeMutation(mutationID)
    }

    func deleteFile(atRelativePath relativePath: String) async throws {
        try Task.checkCancellation()
        let target = try mutationTarget(forRelativePath: relativePath)
        try await requireRegularMutationSource(relativePath: target.relativePath)
        try Task.checkCancellation()
        let url = target.url
        let mutation = try startUncancellableMutation(.delete, relativePaths: [target.relativePath]) {
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
                await self?.completeMutation(
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
        completeMutation(mutationID)
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
        let mutation = try startUncancellableMutation(.trash, relativePaths: [normalizedRelativePath]) {
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
                await self?.completeMutation(
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
        completeMutation(mutationID)
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

        let mutation = try startUncancellableMutation(.edit, relativePaths: [target.relativePath]) {
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
                await self?.completeMutation(
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
            completeMutation(mutationID, error: FileSystemError.invalidRelativePath)
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
            if mutationWaiters[mutationID] != nil {
                deferredEditPublicationsByMutationID[mutationID] = deferredPublication
            } else {
                publishDeferredEditPublication(deferredPublication)
            }
        }
        completeMutation(mutationID)
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

    private nonisolated static func normalizedCreateError(_ error: any Error) -> any Error {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EEXIST) {
            return FileSystemError.fileAlreadyExists
        }
        return FileSystemError.failedToCreateFile(error)
    }

    /// Writes under a descriptor-walked parent and publishes with no-replace semantics.
    /// Parent traversal never follows symbolic links, and the temporary prefix is watcher-excluded.
    private static func writeFileNoReplace(
        rootPath: String,
        relativePath: String,
        data: Data
    ) throws {
        try withSecureMutationParent(
            rootPath: rootPath,
            relativePath: relativePath,
            createIntermediates: true
        ) { parentDescriptor, leafName in
            let temporaryName = ".repoprompt.tmp.create.\(UUID().uuidString)"
            let temporaryDescriptor = openat(
                parentDescriptor,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o644
            )
            guard temporaryDescriptor >= 0 else {
                throw posixMutationError(
                    operation: "exclusive temporary create",
                    path: relativePath,
                    code: errno
                )
            }
            defer {
                _ = close(temporaryDescriptor)
                _ = unlinkat(parentDescriptor, temporaryName, 0)
            }

            try writeAll(data, to: temporaryDescriptor, path: relativePath)
            guard fsync(temporaryDescriptor) == 0 else {
                throw posixMutationError(operation: "temporary fsync", path: relativePath, code: errno)
            }

            #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                if renameatx_np(
                    parentDescriptor,
                    temporaryName,
                    parentDescriptor,
                    leafName,
                    UInt32(RENAME_EXCL)
                ) == 0 {
                    return
                }
                let renameError = errno
                if renameError == EEXIST {
                    throw posixMutationError(
                        operation: "exclusive rename",
                        path: relativePath,
                        code: renameError
                    )
                }
            #endif

            if linkat(parentDescriptor, temporaryName, parentDescriptor, leafName, 0) == 0 {
                return
            }
            throw posixMutationError(
                operation: "exclusive link",
                path: relativePath,
                code: errno
            )
        }
    }

    private static func moveFileSecurely(
        rootPath: String,
        fromRelativePath: String,
        toRelativePath: String,
        createDestinationParents: Bool
    ) throws {
        try withSecureMutationParent(
            rootPath: rootPath,
            relativePath: fromRelativePath,
            createIntermediates: false
        ) { sourceParent, sourceName in
            try withSecureMutationParent(
                rootPath: rootPath,
                relativePath: toRelativePath,
                createIntermediates: createDestinationParents
            ) { destinationParent, destinationName in
                #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                    guard renameatx_np(
                        sourceParent,
                        sourceName,
                        destinationParent,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    ) == 0 else {
                        throw posixMutationError(
                            operation: "exclusive move",
                            path: "\(fromRelativePath) -> \(toRelativePath)",
                            code: errno
                        )
                    }
                #else
                    guard linkat(sourceParent, sourceName, destinationParent, destinationName, 0) == 0 else {
                        throw posixMutationError(
                            operation: "exclusive move link",
                            path: "\(fromRelativePath) -> \(toRelativePath)",
                            code: errno
                        )
                    }
                    guard unlinkat(sourceParent, sourceName, 0) == 0 else {
                        let unlinkError = errno
                        _ = unlinkat(destinationParent, destinationName, 0)
                        throw posixMutationError(
                            operation: "exclusive move unlink",
                            path: fromRelativePath,
                            code: unlinkError
                        )
                    }
                #endif
            }
        }
    }

    private static func removeSecureMutationItem(rootPath: String, relativePath: String) throws {
        try withSecureMutationParent(
            rootPath: rootPath,
            relativePath: relativePath,
            createIntermediates: false
        ) { parentDescriptor, leafName in
            guard unlinkat(parentDescriptor, leafName, 0) == 0 else {
                throw posixMutationError(operation: "secure remove", path: relativePath, code: errno)
            }
        }
    }

    private static func withSecureMutationParent<T>(
        rootPath: String,
        relativePath: String,
        createIntermediates: Bool,
        _ body: (Int32, String) throws -> T
    ) throws -> T {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let leafName = components.last,
              !leafName.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." })
        else {
            throw FileSystemError.invalidRelativePath
        }

        var currentDescriptor = open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard currentDescriptor >= 0 else {
            throw posixMutationError(operation: "secure root open", path: rootPath, code: errno)
        }
        defer { _ = close(currentDescriptor) }

        for component in components.dropLast() {
            var nextDescriptor = openat(
                currentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if nextDescriptor < 0, errno == ENOENT, createIntermediates {
                if mkdirat(currentDescriptor, component, 0o755) != 0, errno != EEXIST {
                    throw posixMutationError(
                        operation: "secure parent create",
                        path: relativePath,
                        code: errno
                    )
                }
                nextDescriptor = openat(
                    currentDescriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw posixMutationError(
                    operation: "secure parent open",
                    path: relativePath,
                    code: errno
                )
            }
            _ = close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return try body(currentDescriptor, leafName)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        var writeError: Int32 = 0
        data.withUnsafeBytes { bytes in
            guard var base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = data.count
            while remaining > 0 {
                #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                    let count = Darwin.write(descriptor, base, remaining)
                #else
                    let count = Glibc.write(descriptor, base, remaining)
                #endif
                if count < 0 {
                    if errno == EINTR { continue }
                    writeError = errno
                    break
                }
                if count == 0 {
                    writeError = EIO
                    break
                }
                remaining -= count
                base = base.advanced(by: count)
            }
        }
        guard writeError == 0 else {
            throw posixMutationError(operation: "temporary write", path: path, code: writeError)
        }
    }

    private static func posixMutationError(operation: String, path: String, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed for \(path) (\(code))"]
        )
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
