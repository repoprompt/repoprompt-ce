import Foundation
import RepoPromptVCS
import RepoPromptWorkspaceCore

// MARK: - Shared Worktree Listing

/// Configuration for the process-wide worktree listing shared by periodic Git context refreshes.
struct SharedWorktreeListingConfiguration {
    /// Retains a completed listing for one `GitViewModel` context-refresh interval (2.5 s).
    /// Enumeration duration does not consume this freshness interval.
    static let defaultTimeToLive: TimeInterval = 2.5

    var timeToLive: TimeInterval = Self.defaultTimeToLive
    /// Separate from completed-result freshness: cancel a slow shared enumeration, then retain
    /// its flight until the worker drains so a stalled worker cannot create overlapping retries.
    var maximumFlightDuration: Duration = .seconds(120)
    /// Test seam for the cancellation deadline; production uses the monotonic task clock.
    var waitForFlightDeadline: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Monotonic clock in seconds.
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Test seam replacing `git worktree list` plus per-worktree layout resolution.
    var lister: (@Sendable (URL) async throws -> [GitWorktreeDescriptor])?
    /// Test seam for the Git subprocess environment. By default the sharing decision reads the
    /// exact environment prepared by the same `GitService` that runs the enumeration.
    var gitProcessEnvironment: (@Sendable () async -> [String: String])?
}

/// Cache entries, in-flight enumerations, and the invalidation generation.
struct SharedWorktreeListingState {
    struct Entry {
        let descriptors: [GitWorktreeDescriptor]
        let completedAt: TimeInterval
    }

    struct Flight {
        let id: UInt64
        let generation: UInt64
        let task: Task<[GitWorktreeDescriptor], Error>
        let deadlineTask: Task<Void, Never>
    }

    var entries: [String: Entry] = [:]
    var flights: [String: Flight] = [:]
    var generation: UInt64 = 0
    var nextFlightID: UInt64 = 0
    /// Number of requests that joined an in-flight enumeration (diagnostics and tests).
    var joinedFlightCount: UInt64 = 0
    /// Standardized repo-root path -> cache key; a `nil` value marks a root that must bypass the cache.
    var keyByRootPath: [String: SharedWorktreeListingKey?] = [:]
    /// Memoized: sharing is disabled when Git subprocesses inherit a repository location.
    var environmentAllowsSharing: Bool?
}

private enum SharedWorktreeListingError: Error {
    case invalidated
}

/// Identifies one repository's listing. Enumeration always runs from `mainRoot`, so neither the
/// working directory nor the Git environment depends on which caller started it (a caller whose
/// own worktree was removed cannot fail the shared enumeration for healthy callers).
struct SharedWorktreeListingKey: Hashable {
    let commonDirPath: String
    let mainRoot: URL

    var cacheKey: String {
        commonDirPath + "\n" + mainRoot.path
    }
}

extension VCSService {
    /// Worktree listing for periodic, read-only Git context refreshes, shared across windows.
    ///
    /// Every window refreshes its Git worktree context every ~2.5 s. Each refresh runs
    /// `git worktree list` and resolves every linked worktree's `.git` and `commondir`, so windows
    /// whose roots belong to one repository used to repeat the same enumeration. Here those
    /// refreshes share one enumeration per repository:
    /// - entries expire `timeToLive` after their enumeration completes;
    /// - concurrent requests join one flight, regardless of completed-result freshness;
    /// - the separate flight deadline cancels a slow enumeration without starting another while
    ///   it drains; Git's subprocess cancellation and timeout still apply;
    /// - `invalidateSharedWorktreeListings()` (also run by `invalidateCache(for:)` and
    ///   `clearCache()`) drops entries and cancels old flights; their slots remain until drained,
    ///   and their results cannot be returned or stored after a RepoPrompt mutation;
    /// - failures are never cached, and there is no modification-time validation.
    ///
    /// The key is the standardized common Git directory plus the known main-worktree root, and the
    /// enumeration always runs from that main root, so every sharer receives the same descriptors.
    /// Only `isCurrent` depends on the caller, and it is re-projected per request. Roots whose main
    /// worktree cannot be derived from the common directory bypass the cache. A request whose
    /// enumeration was invalidated while it waited retries once, so it never returns a listing
    /// that predates a RepoPrompt mutation it overlapped. Explicit tool listings keep using the
    /// uncached `listGitWorktrees`.
    func sharedGitWorktreeListing(for resolved: VCSResolvedRepo) async throws -> [GitWorktreeDescriptor] {
        guard resolved.backendKind == .git else {
            throw VCSError.unsupportedOperation(operation: "list_worktrees", backend: resolved.backendKind)
        }
        let rootURL = resolved.rootURL
        let lister = gitWorktreeLister()
        // An inherited GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR can redirect an enumeration run from a
        // main checkout, so sharing is only used when Git's environment names no repository.
        guard await sharedWorktreeListingEnvironmentAllowsSharing() else {
            return try await lister(rootURL)
        }
        var descriptors: [GitWorktreeDescriptor] = []
        var receivedCurrentListing = false
        do {
            // One retry: a result never predates an uncached enumeration started when the caller retried.
            for _ in 0 ..< 2 {
                try Task.checkCancellation()
                guard let key = sharedWorktreeListingKey(forRepoRoot: rootURL) else {
                    return try await lister(rootURL)
                }
                let generation = sharedWorktreeListing.generation
                do {
                    descriptors = try await sharedWorktreeListing(forKey: key, lister: lister)
                } catch SharedWorktreeListingError.invalidated {
                    continue
                }
                try Task.checkCancellation()
                guard sharedWorktreeListing.generation == generation else { continue }
                guard Self.listing(descriptors, belongsTo: key) else {
                    // Not recognisably this repository's listing (an inherited GIT_DIR, or a main-root
                    // spelling that differs from Git's): bypass sharing for this root, as before the cache.
                    sharedWorktreeListing.keyByRootPath[rootURL.standardizedFileURL.path] = .some(nil)
                    return try await lister(rootURL)
                }
                receivedCurrentListing = true
                break
            }
            guard receivedCurrentListing else { throw SharedWorktreeListingError.invalidated }
        } catch SharedWorktreeListingError.invalidated {
            // Repeated mutations must fail this refresh, not fall back to an unshared enumeration.
            throw SharedWorktreeListingError.invalidated
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // The shared enumeration from the key's main root failed (e.g. the main checkout moved):
            // re-resolve this root and enumerate from it, as before sharing.
            dropCachedResolution(forRepoRoot: rootURL)
            return try await lister(rootURL)
        }
        guard let match = Self.descriptor(exactlyAt: rootURL, in: descriptors) else {
            // The caller's root is not in its repository's listing (removed, pruned, or spelled
            // differently from Git): bypass sharing for this root until the next invalidation and
            // enumerate from the caller's own root, as before sharing.
            sharedWorktreeListing.keyByRootPath[rootURL.standardizedFileURL.path] = .some(nil)
            return try await lister(rootURL)
        }
        guard Self.isInternallyConsistent(match) else {
            // The listed root now belongs to another repository (e.g. a removed worktree path reused
            // by a new clone). Re-resolve this root only and enumerate from it, as before sharing.
            dropCachedResolution(forRepoRoot: rootURL)
            return try await lister(rootURL)
        }
        return Self.projectingCurrentWorktree(descriptors, currentRepoURL: rootURL)
    }

    /// Drop every shared worktree listing. Call after any RepoPrompt worktree mutation.
    func invalidateSharedWorktreeListings() {
        sharedWorktreeListing.generation &+= 1
        sharedWorktreeListing.entries.removeAll()
        for flight in sharedWorktreeListing.flights.values {
            flight.deadlineTask.cancel()
            flight.task.cancel()
        }
        sharedWorktreeListing.keyByRootPath.removeAll()
    }

    private func sharedWorktreeListing(
        forKey listingKey: SharedWorktreeListingKey,
        lister: @escaping @Sendable (URL) async throws -> [GitWorktreeDescriptor]
    ) async throws -> [GitWorktreeDescriptor] {
        let key = listingKey.cacheKey
        let now = sharedWorktreeListingConfiguration.now()
        if let entry = sharedWorktreeListing.entries[key] {
            if now - entry.completedAt < sharedWorktreeListingConfiguration.timeToLive {
                return entry.descriptors
            }
            sharedWorktreeListing.entries.removeValue(forKey: key)
        }
        if let flight = sharedWorktreeListing.flights[key] {
            sharedWorktreeListing.joinedFlightCount &+= 1
            let result = await flight.task.result
            return try finishSharedWorktreeListing(result, flight: flight, key: listingKey)
        }

        let generation = sharedWorktreeListing.generation
        sharedWorktreeListing.nextFlightID &+= 1
        let flightID = sharedWorktreeListing.nextFlightID
        // Unstructured so one waiter's cancellation cannot fail the other joined waiters.
        let mainRoot = listingKey.mainRoot
        let task = Task {
            let descriptors = try await lister(mainRoot)
            try Task.checkCancellation()
            return descriptors
        }
        let waitForDeadline = sharedWorktreeListingConfiguration.waitForFlightDeadline
        let maximumDuration = sharedWorktreeListingConfiguration.maximumFlightDuration
        let deadlineTask = Task {
            do {
                try await waitForDeadline(maximumDuration)
                try Task.checkCancellation()
                task.cancel()
            } catch {}
        }
        let flight = SharedWorktreeListingState.Flight(
            id: flightID,
            generation: generation,
            task: task,
            deadlineTask: deadlineTask
        )
        sharedWorktreeListing.flights[key] = flight
        let result = await task.result
        return try finishSharedWorktreeListing(result, flight: flight, key: listingKey)
    }

    private func finishSharedWorktreeListing(
        _ result: Result<[GitWorktreeDescriptor], Error>,
        flight: SharedWorktreeListingState.Flight,
        key listingKey: SharedWorktreeListingKey
    ) throws -> [GitWorktreeDescriptor] {
        flight.deadlineTask.cancel()
        let key = listingKey.cacheKey
        let ownsSlot = sharedWorktreeListing.flights[key]?.id == flight.id
        if ownsSlot {
            sharedWorktreeListing.flights.removeValue(forKey: key)
        }
        guard sharedWorktreeListing.generation == flight.generation else {
            throw SharedWorktreeListingError.invalidated
        }
        // A cancelled subprocess may report its own timeout/error while cancellation drains.
        // Normalize it before the caller's ordinary-error fallback can duplicate the enumeration.
        guard !flight.task.isCancelled else { throw CancellationError() }
        let descriptors = try result.get()
        if ownsSlot, Self.listing(descriptors, belongsTo: listingKey) {
            sharedWorktreeListing.entries[key] = SharedWorktreeListingState.Entry(
                descriptors: descriptors,
                completedAt: sharedWorktreeListingConfiguration.now()
            )
        }
        return descriptors
    }

    private func sharedWorktreeListingKey(forRepoRoot rootURL: URL) -> SharedWorktreeListingKey? {
        let rootPath = rootURL.standardizedFileURL.path
        if let memoized = sharedWorktreeListing.keyByRootPath[rootPath] {
            return memoized
        }
        let key: SharedWorktreeListingKey? = if let layout = gitRepositoryLayout(forRepoRoot: rootURL),
                                                let mainRoot = layout.knownMainWorktreeRoot
        {
            SharedWorktreeListingKey(
                commonDirPath: layout.commonDir.standardizedFileURL.path,
                mainRoot: mainRoot.standardizedFileURL
            )
        } else {
            nil
        }
        sharedWorktreeListing.keyByRootPath[rootPath] = .some(key)
        return key
    }

    private func sharedWorktreeListingEnvironmentAllowsSharing() async -> Bool {
        if let allowed = sharedWorktreeListing.environmentAllowsSharing {
            return allowed
        }
        let environment: [String: String] = if let override = sharedWorktreeListingConfiguration.gitProcessEnvironment {
            await override()
        } else {
            await gitBackend().gitProcessEnvironment()
        }
        let allowed = ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"].allSatisfy { environment[$0] == nil }
        sharedWorktreeListing.environmentAllowsSharing = allowed
        return allowed
    }

    private func gitWorktreeLister() -> @Sendable (URL) async throws -> [GitWorktreeDescriptor] {
        if let lister = sharedWorktreeListingConfiguration.lister {
            return lister
        }
        let backend = gitBackend()
        return { url in try await backend.listWorktrees(at: url) }
    }

    /// The listed worktree at exactly the caller's repository root. A caller's resolved root is a
    /// worktree top level, so an ancestor match would mean the root is not a worktree of this listing.
    nonisolated static func descriptor(
        exactlyAt rootURL: URL,
        in descriptors: [GitWorktreeDescriptor]
    ) -> GitWorktreeDescriptor? {
        let rootPath = StandardizedPath.absolute(rootURL.path)
        return descriptors.first { StandardizedPath.absolute($0.path) == rootPath }
    }

    /// A worktree's resolved Git directory must agree with its repository: the main worktree's Git
    /// directory is the common directory, and a linked worktree's lives under `<common>/worktrees`.
    nonisolated static func isInternallyConsistent(_ descriptor: GitWorktreeDescriptor) -> Bool {
        guard let gitDir = descriptor.gitDir else { return false }
        let gitDirPath = StandardizedPath.absolute(gitDir)
        let commonPath = StandardizedPath.absolute(descriptor.repository.commonGitDir)
        return descriptor.isMain
            ? gitDirPath == commonPath
            : StandardizedPath.isDescendant(gitDirPath, of: commonPath + "/worktrees")
    }

    /// A listing belongs to a key only if it reports the key's main root as a consistent main worktree.
    nonisolated static func listing(_ descriptors: [GitWorktreeDescriptor], belongsTo key: SharedWorktreeListingKey) -> Bool {
        descriptors.contains { $0.isMain && $0.path == key.mainRoot.path && isInternallyConsistent($0) }
    }

    /// Mirrors `GitService.makeWorktreeDescriptors`, where `isCurrent` is `path == currentPath`.
    nonisolated static func projectingCurrentWorktree(
        _ descriptors: [GitWorktreeDescriptor],
        currentRepoURL: URL
    ) -> [GitWorktreeDescriptor] {
        let currentPath = currentRepoURL.standardizedFileURL.path
        return descriptors.map { descriptor in
            let isCurrent = descriptor.path == currentPath
            guard descriptor.isCurrent != isCurrent else { return descriptor }
            return GitWorktreeDescriptor(
                worktreeID: descriptor.worktreeID,
                repository: descriptor.repository,
                path: descriptor.path,
                gitDir: descriptor.gitDir,
                name: descriptor.name,
                branch: descriptor.branch,
                head: descriptor.head,
                isMain: descriptor.isMain,
                isCurrent: isCurrent,
                isDetached: descriptor.isDetached,
                isLocked: descriptor.isLocked,
                lockReason: descriptor.lockReason,
                isPrunable: descriptor.isPrunable,
                prunableReason: descriptor.prunableReason
            )
        }
    }
}
