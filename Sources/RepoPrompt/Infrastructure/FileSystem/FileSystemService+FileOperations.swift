import Foundation
import RepoPromptDomainRuntime
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

private struct FileSystemMutationIOExecutor {
    let operation: FileSystemUncancellableMutation
    let physicalMutationGuard: DomainMutationPhysicalCommitGuard?
    let willExecute: (@Sendable (FileSystemUncancellableMutation) -> Void)?

    func callAsFunction(_ io: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            fileSystemMutationIOQueue.async {
                willExecute?(operation)
                do {
                    try physicalMutationGuard?.revalidate()
                    try io()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

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
    /// Blocking calls run on a dispatch queue so slow mutations do not occupy Swift's cooperative executor.
    ///
    /// Reconciliation contract: request cancellation only removes and resumes the actor-owned
    /// waiter. The detached monitor remains the sole completion owner and always reconciles the
    /// service caches plus synthetic delta publication against the eventual on-disk result.
    private func startUncancellableMutation(
        _ operation: FileSystemUncancellableMutation,
        relativePaths: Set<String>,
        io: @escaping @Sendable (FileSystemMutationIOExecutor) async throws -> Void
    ) async throws -> (id: UUID, task: Task<Void, any Error>) {
        let authorityPaths = mutationAuthorityPaths(relativePaths)
        guard !hasInFlightMutation(conflictingWith: authorityPaths) else {
            throw FileSystemError.mutationInProgress
        }
        let id = UUID()
        inFlightMutations[id] = FileSystemInFlightMutation(relativePaths: authorityPaths)
        do {
            #if DEBUG
                let willBegin = mutationIOWillBeginHandler
                let willExecute = mutationIOWillExecuteHandler
            #else
                let willBegin: (@Sendable (FileSystemUncancellableMutation) async -> Void)? = nil
                let willExecute: (@Sendable (FileSystemUncancellableMutation) -> Void)? = nil
            #endif
            try await MCPDomainMutationCommitContext.willCommit()
            let physicalMutationGuard = try await MCPDomainMutationCommitContext.physicalMutationGuard()
            let executor = FileSystemMutationIOExecutor(
                operation: operation,
                physicalMutationGuard: physicalMutationGuard,
                willExecute: willExecute
            )
            let task = Task.detached(priority: .utility) {
                if let willBegin {
                    await willBegin(operation)
                }
                try await io(executor)
            }
            return (id, task)
        } catch {
            inFlightMutations.removeValue(forKey: id)
            throw error
        }
    }

    private func awaitUncancellableMutation(
        _ id: UUID,
        operation: FileSystemUncancellableMutation
    ) async throws {
        #if DEBUG
            if let willRegister = mutationWaiterWillRegisterHandler {
                await willRegister(operation)
            }
        #endif
        if Task.isCancelled {
            if mutationCompletionMailbox.removeValue(forKey: id) == nil {
                cancelledMutationWaiterIDs.insert(id)
            } else if let publication = deferredEditPublicationsByMutationID.removeValue(forKey: id) {
                publishDeferredEditPublication(publication)
            }
            throw CancellationError()
        }
        if let completion = mutationCompletionMailbox.removeValue(forKey: id) {
            try completion.get()
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    cancelledMutationWaiterIDs.insert(id)
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
        cancelledMutationWaiterIDs.insert(id)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func completeMutationWaiter(_ id: UUID, error: (any Error)? = nil) {
        guard inFlightMutations[id] != nil else { return }
        defer { finishMutationAuthority(id) }

        let completion: FileSystemMutationCompletion = if let error {
            .failure(error)
        } else {
            .success
        }
        if cancelledMutationWaiterIDs.remove(id) != nil {
            return
        }
        guard let waiter = mutationWaiters.removeValue(forKey: id) else {
            mutationCompletionMailbox[id] = completion
            return
        }
        if let error {
            waiter.continuation.resume(throwing: error)
        } else {
            waiter.continuation.resume()
        }
    }

    private func finishMutationAuthority(_ id: UUID) {
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
            mutationDrainWaiters[UUID()] = FileSystemMutationDrainWaiter(
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

        let destDir = (newFull as NSString).deletingLastPathComponent
        let physicalMutationGuard = try await MCPDomainMutationCommitContext.physicalMutationGuard()
        try physicalMutationGuard?.revalidate()
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true, attributes: nil)
        _ = try mutationTarget(forRelativePath: newTarget.relativePath)

        let mutation = try await startUncancellableMutation(
            .move,
            relativePaths: [oldTarget.relativePath, newTarget.relativePath]
        ) { executor in
            try await executor {
                try FileManager.default.moveItem(atPath: oldFull, toPath: newFull)
            }
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
        try await awaitUncancellableMutation(mutation.id, operation: .move)
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
                try await Self.performBlockingMutationIO {
                    try FileManager.default.moveItem(atPath: newFullPath, toPath: oldFullPath)
                }
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
        let physicalMutationGuard = try await MCPDomainMutationCommitContext.physicalMutationGuard()
        try physicalMutationGuard?.revalidate()
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        _ = try mutationTarget(forRelativePath: target.relativePath)
        guard !fm.fileExists(atPath: fullPath, isDirectory: nil) else {
            throw FileSystemError.fileAlreadyExists
        }

        // Materializing a large Swift String as UTF-8 is synchronous and potentially expensive.
        // Keep it inside the detached mutation worker so request cancellation can always reach
        // the actor-owned waiter while preparation and the uncancellable disk write continue.
        #if DEBUG
            let dataPreparation = createFileDataPreparationForTesting
        #else
            let dataPreparation: (@Sendable (String) async throws -> Data)? = nil
        #endif
        let mutation = try await startUncancellableMutation(
            .create,
            relativePaths: [target.relativePath]
        ) { executor in
            let data: Data
            if let dataPreparation {
                data = try await dataPreparation(content)
            } else if let encoded = content.data(using: .utf8) {
                data = encoded
            } else {
                throw NSError(
                    domain: "encoding",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to encode text as UTF-8"]
                )
            }
            try await executor {
                try FileSystemService.writeFileRobust(to: fullURL, data: data)
            }
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
        try await awaitUncancellableMutation(mutation.id, operation: .create)
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
            _ = try? await Self.performBlockingMutationIO {
                try FileManager.default.removeItem(at: url)
            }
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
        let mutation = try await startUncancellableMutation(
            .delete,
            relativePaths: [target.relativePath]
        ) { executor in
            try await executor {
                try FileManager.default.removeItem(at: url)
            }
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
        try await awaitUncancellableMutation(mutation.id, operation: .delete)
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
        let mutation = try await startUncancellableMutation(
            .trash,
            relativePaths: [normalizedRelativePath]
        ) { executor in
            try await executor {
                try moveItemToTrashIO(url)
            }
        }
        trashMutationsAwaitingReconciliation.insert(mutation.id)
        // On macOS, FileManager.trashItem can move the item immediately and then remain
        // synchronously blocked for tens of seconds in post-move system work. Absence of the
        // exact source path is the durable postcondition this operation promises, so observe it
        // independently and settle/reconcile without waiting for that unrelated tail latency.
        Task.detached { [weak self] in
            for _ in 0 ..< 2400 {
                if !FileManager.default.fileExists(atPath: url.path) {
                    await self?.reconcileTrashedItemIfPending(
                        mutationID: mutation.id,
                        relativePath: normalizedRelativePath,
                        url: url,
                        wasDirectory: wasDirectory
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        Task.detached { [weak self] in
            do {
                try await mutation.task.value
                await self?.reconcileTrashedItemIfPending(
                    mutationID: mutation.id,
                    relativePath: normalizedRelativePath,
                    url: url,
                    wasDirectory: wasDirectory
                )
            } catch {
                await self?.failTrashedItemIfPending(
                    mutationID: mutation.id,
                    relativePath: normalizedRelativePath,
                    url: url,
                    wasDirectory: wasDirectory,
                    error: error
                )
            }
        }
        try await awaitUncancellableMutation(mutation.id, operation: .trash)
    }

    private func reconcileTrashedItemIfPending(
        mutationID: UUID,
        relativePath: String,
        url: URL,
        wasDirectory: Bool
    ) {
        guard trashMutationsAwaitingReconciliation.remove(mutationID) != nil else { return }
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

    private func failTrashedItemIfPending(
        mutationID: UUID,
        relativePath: String,
        url: URL,
        wasDirectory: Bool,
        error: any Error
    ) {
        guard trashMutationsAwaitingReconciliation.contains(mutationID) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            reconcileTrashedItemIfPending(
                mutationID: mutationID,
                relativePath: relativePath,
                url: url,
                wasDirectory: wasDirectory
            )
            return
        }
        trashMutationsAwaitingReconciliation.remove(mutationID)
        completeMutationWaiter(
            mutationID,
            error: FileSystemError.failedToDeleteFile(error)
        )
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
        try await editFile(
            atRelativePath: relativePath,
            newContent: newContent,
            expectedOriginalContent: nil,
            modificationPublicationPolicy: modificationPublicationPolicy
        )
    }

    func editFileIfUnchanged(
        atRelativePath relativePath: String,
        newContent: String,
        expectedOriginalContent: String,
        modificationPublicationPolicy: FileSystemEditModificationPublicationPolicy
    ) async throws -> FileSystemDeferredEditPublicationToken? {
        try await editFile(
            atRelativePath: relativePath,
            newContent: newContent,
            expectedOriginalContent: expectedOriginalContent,
            modificationPublicationPolicy: modificationPublicationPolicy
        )
    }

    private func editFile(
        atRelativePath relativePath: String,
        newContent: String,
        expectedOriginalContent: String?,
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
        let mutation = try await startUncancellableMutation(
            .edit,
            relativePaths: [target.relativePath]
        ) { executor in
            try await executor {
                if let expectedOriginalContent {
                    let currentData = try Data(contentsOf: fullURL)
                    guard String(data: currentData, encoding: encoding) == expectedOriginalContent else {
                        throw FileSystemError.fileContentChanged
                    }
                }
                try FileSystemService.writeFileRobust(to: fullURL, data: data)
            }
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
            } catch FileSystemError.fileContentChanged {
                await self?.completeMutationWaiter(
                    mutation.id,
                    error: FileSystemError.fileContentChanged
                )
            } catch {
                await self?.completeMutationWaiter(
                    mutation.id,
                    error: FileSystemError.failedToEditFile(error)
                )
            }
        }
        try await awaitUncancellableMutation(mutation.id, operation: .edit)
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
            if cancelledMutationWaiterIDs.contains(mutationID) {
                publishDeferredEditPublication(deferredPublication)
            } else {
                deferredEditPublicationsByMutationID[mutationID] = deferredPublication
            }
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
                if n == 0 {
                    // A zero-byte write makes no progress. Treat it as I/O failure instead of
                    // spinning forever inside an uncancellable mutation worker.
                    writeError = EIO
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
