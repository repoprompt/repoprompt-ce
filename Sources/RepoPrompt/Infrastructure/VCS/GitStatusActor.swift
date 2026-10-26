import Foundation
import RepoPromptFoundation
import RepoPromptSettingsCore
import RepoPromptVCS
import RepoPromptWorkspaceCore

/// Background actor that handles all VCS (git/jj) operations off the main thread.
/// Communicates with `GitViewModel` via `AsyncStream<GitStatusSnapshot>`.
actor GitStatusActor {
    // MARK: - Types

    enum Trigger {
        case initial
        case rootChanged
        case modeChanged
        case popoverOpen
        case explicitRefresh
        case backgroundPoll
        case branchChanged
    }

    struct RepoDetection {
        let rootPath: String
        let isGitRepo: Bool // Kept for compatibility; true for any VCS (git or jj)
        let backendKind: VCSBackendKind?
        let gitWorktreeContext: GitWorktreeContextSummary?
    }

    struct GitStatusSnapshot {
        let rootPath: String
        let gitRootPath: String? // VCS root path (git or jj)
        let isGitRepo: Bool // Kept for compatibility; true for any VCS
        let backendKind: VCSBackendKind?

        let unstagedFiles: [VCSUncommittedFile]
        let currentBranch: String?
        let availableBranches: [VCSBranch]
        let availableRemoteBranches: [VCSBranch]
        let availableTags: [VCSTag]
        let gitWorktreeContext: GitWorktreeContextSummary?

        let totalAdditions: Int
        let totalDeletions: Int
        let commitDelta: (ahead: Int, behind: Int)?
        let errorMessage: String?

        let trigger: Trigger
        let generation: Int
    }

    // MARK: - Private State

    private let vcsService: VCSService
    private let diffEngine: GitDiffEngine

    /// All known workspace roots (from WorkspaceFilesViewModel)
    private var workspaceRoots: [String] = []

    /// Info about each root's VCS status
    private struct RootInfo {
        let isRepo: Bool
        let repoRootPath: String?
        let backendKind: VCSBackendKind?
        let resolvedRepo: VCSResolvedRepo?
        let gitWorktreeContext: GitWorktreeContextSummary?
    }

    private struct RootContextRequest {
        let rootPath: String
        let resolved: VCSResolvedRepo
    }

    private struct RootContextResult {
        let rootPath: String
        let context: GitWorktreeContextSummary?
    }

    /// rootPath -> repo info
    private var rootInfos: [String: RootInfo] = [:]

    private var selectedRootPath: String?
    private var selectedDiffBranch: String = "HEAD"
    private var inclusionMode: GitDiffInclusionMode = .none

    private var snapshotGeneration: Int = 0
    private var latestSnapshot: GitStatusSnapshot?
    private var activeRefreshes = 0
    private var refreshDrainWaiters: [CheckedContinuation<Void, Never>] = []
    #if DEBUG
        private var test_refreshDrainStarted: (@Sendable () -> Void)?
    #endif

    private var pollingTask: Task<Void, Never>?
    private var isShutDown = false
    private var waitForNextPoll: @Sendable () async throws -> Void = {
        try await Task.sleep(nanoseconds: 5_000_000_000)
    }

    /// AsyncStream for consumers
    private var statusContinuation: AsyncStream<GitStatusSnapshot>.Continuation?

    // MARK: - Public Stream

    nonisolated var statusStream: AsyncStream<GitStatusSnapshot> {
        AsyncStream { continuation in
            Task {
                await self.setStatusContinuation(continuation)
            }
        }
    }

    private func setStatusContinuation(_ continuation: AsyncStream<GitStatusSnapshot>.Continuation) {
        guard !isShutDown else {
            continuation.finish()
            return
        }
        statusContinuation = continuation
        if let snap = latestSnapshot {
            continuation.yield(snap)
        }
    }

    // MARK: - Init

    init(vcsService: VCSService = .shared, diffEngine: GitDiffEngine = .shared) {
        self.vcsService = vcsService
        self.diffEngine = diffEngine
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: - Root Management

    /// Update the list of workspace roots and return detection results
    func updateRoots(_ roots: [String]) async -> [RepoDetection] {
        guard !isShutDown else { return [] }
        let previousRoots = Set(workspaceRoots)
        let currentRoots = Set(roots)
        let removedRoots = previousRoots.subtracting(currentRoots)
        let removedRepos = Set(removedRoots.compactMap { rootInfos[$0]?.repoRootPath })
        workspaceRoots = roots

        rootInfos = rootInfos.filter { key, _ in currentRoots.contains(key) }

        for root in removedRoots {
            await vcsService.invalidateCache(for: URL(fileURLWithPath: root))
        }

        let backend = await vcsService.gitBackend()
        for root in removedRepos {
            await backend.invalidateUntrackedStats(at: URL(fileURLWithPath: root))
        }

        guard !isShutDown else { return [] }
        let rootsToDetect = roots.filter { rootInfos[$0] == nil }
        await withTaskGroup(of: (String, RootInfo).self) { group in
            for root in rootsToDetect {
                group.addTask { [vcsService] in
                    let url = URL(fileURLWithPath: root)
                    if let resolved = await vcsService.resolveRepo(from: url) {
                        return (root, RootInfo(
                            isRepo: true,
                            repoRootPath: resolved.rootURL.path,
                            backendKind: resolved.backendKind,
                            resolvedRepo: resolved,
                            gitWorktreeContext: nil
                        ))
                    } else {
                        return (root, RootInfo(
                            isRepo: false,
                            repoRootPath: nil,
                            backendKind: nil,
                            resolvedRepo: nil,
                            gitWorktreeContext: nil
                        ))
                    }
                }
            }

            for await (root, info) in group {
                rootInfos[root] = info
            }
        }

        guard !isShutDown else { return [] }
        await refreshGitWorktreeContexts(for: roots)

        return roots.map { root in
            let info = rootInfos[root]
            return RepoDetection(
                rootPath: root,
                isGitRepo: info?.isRepo ?? false,
                backendKind: info?.backendKind,
                gitWorktreeContext: info?.gitWorktreeContext
            )
        }
    }

    /// Best-effort cache release on window close; an in-flight refresh can repopulate it.
    /// Poller teardown policy is unchanged.
    func invalidateUntrackedStats() async {
        let backend = await vcsService.gitBackend()
        for root in Set(rootInfos.values.compactMap(\.repoRootPath)) {
            await backend.invalidateUntrackedStats(at: URL(fileURLWithPath: root))
        }
    }

    private func refreshGitWorktreeContexts(for roots: [String]) async {
        let requests = roots.compactMap { root -> RootContextRequest? in
            guard let info = rootInfos[root],
                  info.backendKind == .git,
                  let resolved = info.resolvedRepo
            else { return nil }
            return RootContextRequest(rootPath: root, resolved: resolved)
        }
        guard !requests.isEmpty else { return }

        let grouped = Dictionary(grouping: requests) { request in
            StandardizedPath.absolute(request.resolved.rootURL.path)
        }

        await withTaskGroup(of: [RootContextResult].self) { group in
            for groupRequests in grouped.values {
                group.addTask { [vcsService] in
                    guard let resolved = groupRequests.first?.resolved else { return [] }
                    let worktrees = try? await vcsService.sharedGitWorktreeListing(for: resolved)
                    var results: [RootContextResult] = []
                    results.reserveCapacity(groupRequests.count)
                    for request in groupRequests {
                        let context = await vcsService.gitWorktreeContext(
                            for: URL(fileURLWithPath: request.rootPath),
                            resolved: request.resolved,
                            worktrees: worktrees
                        )
                        results.append(RootContextResult(rootPath: request.rootPath, context: context))
                    }
                    return results
                }
            }

            for await results in group {
                for result in results {
                    guard let current = rootInfos[result.rootPath] else { continue }
                    rootInfos[result.rootPath] = RootInfo(
                        isRepo: current.isRepo,
                        repoRootPath: current.repoRootPath,
                        backendKind: current.backendKind,
                        resolvedRepo: current.resolvedRepo,
                        gitWorktreeContext: result.context
                    )
                }
            }
        }
    }

    func gitEnabledRootPaths() -> [String] {
        workspaceRoots.filter { rootInfos[$0]?.isRepo ?? false }
    }

    func setSelectedRoot(_ rootPath: String?) async {
        guard !isShutDown, selectedRootPath != rootPath else { return }
        selectedRootPath = rootPath
        await refresh(trigger: .rootChanged)
    }

    // MARK: - Mode & Branch Management

    func setInclusionMode(_ mode: GitDiffInclusionMode) async {
        guard !isShutDown, inclusionMode != mode else { return }
        inclusionMode = mode

        if mode == .none {
            stopPolling()
        } else {
            startPollingIfNeeded()
            await refresh(trigger: .modeChanged)
        }
    }

    func setSelectedDiffBranch(_ branch: String) async {
        guard !isShutDown, selectedDiffBranch != branch else { return }
        selectedDiffBranch = branch
        await refresh(trigger: .branchChanged)
    }

    func getSelectedDiffBranch() -> String {
        selectedDiffBranch
    }

    func loadGitBranchSwitchOptions(forRootPath rootPath: String) async throws -> GitBranchSwitchOptions {
        try await vcsService.gitBranchSwitchOptions(at: URL(fileURLWithPath: rootPath))
    }

    func preflightGitBranchSwitch(
        branchName: String,
        forRootPath rootPath: String
    ) async throws -> GitBranchSwitchPreflight {
        try await vcsService.preflightGitBranchSwitch(
            branchName: branchName,
            at: URL(fileURLWithPath: rootPath)
        )
    }

    func switchGitBranch(
        _ request: GitBranchSwitchRequest,
        forRootPath rootPath: String
    ) async throws -> (GitBranchSwitchResult, GitWorktreeContextSummary?) {
        let rootURL = URL(fileURLWithPath: rootPath)
        let result = try await vcsService.switchGitBranch(request, at: rootURL)
        let context = await vcsService.gitWorktreeContext(for: rootURL)
        updateGitWorktreeContext(context, forRootPath: rootPath)
        if selectedRootMatches(rootPath, context: context) {
            await refresh(trigger: .branchChanged)
        }
        return (result, context)
    }

    private func updateGitWorktreeContext(_ context: GitWorktreeContextSummary?, forRootPath rootPath: String) {
        let keys = rootInfoKeys(matching: rootPath, context: context)
        for key in keys {
            guard let current = rootInfos[key] else { continue }
            rootInfos[key] = RootInfo(
                isRepo: current.isRepo,
                repoRootPath: current.repoRootPath,
                backendKind: current.backendKind,
                resolvedRepo: current.resolvedRepo,
                gitWorktreeContext: context
            )
        }
    }

    private func rootInfoKeys(matching rootPath: String, context: GitWorktreeContextSummary?) -> [String] {
        let targetIdentities = checkoutIdentities(rootPath: rootPath, context: context)
        var matches: [String] = []
        var seen = Set<String>()

        for (key, info) in rootInfos {
            guard rootInfoMatches(key: key, info: info, targetIdentities: targetIdentities) else { continue }
            if seen.insert(key).inserted {
                matches.append(key)
            }
        }
        return matches.isEmpty ? [rootPath] : matches
    }

    private func checkoutIdentities(
        rootPath: String,
        context: GitWorktreeContextSummary?
    ) -> Set<CheckoutPathIdentity> {
        Set([rootPath, context?.worktreePath].compactMap(CheckoutPathIdentity.init))
    }

    private func rootInfoCheckoutIdentities(key: String, info: RootInfo) -> Set<CheckoutPathIdentity> {
        Set([
            key,
            info.gitWorktreeContext?.worktreePath,
            info.repoRootPath,
            info.resolvedRepo?.rootURL.path
        ].compactMap(CheckoutPathIdentity.init))
    }

    private func rootInfoMatches(
        key: String,
        info: RootInfo,
        targetIdentities: Set<CheckoutPathIdentity>
    ) -> Bool {
        !rootInfoCheckoutIdentities(key: key, info: info).isDisjoint(with: targetIdentities)
    }

    private func selectedRootMatches(_ rootPath: String, context: GitWorktreeContextSummary?) -> Bool {
        guard let selectedRootPath,
              let selectedInfo = rootInfo(for: selectedRootPath),
              !checkoutIdentities(rootPath: rootPath, context: context).isEmpty
        else { return false }
        return rootInfoMatches(
            key: selectedInfo.key,
            info: selectedInfo.info,
            targetIdentities: checkoutIdentities(rootPath: rootPath, context: context)
        )
    }

    private func rootInfo(for rootPath: String) -> (key: String, info: RootInfo)? {
        if let info = rootInfos[rootPath] {
            return (rootPath, info)
        }
        guard let identity = CheckoutPathIdentity(rootPath) else { return nil }
        return rootInfos.first { key, info in
            rootInfoCheckoutIdentities(key: key, info: info).contains(identity)
        }.map { (key: $0.key, info: $0.value) }
    }

    // MARK: - Status Refresh

    @discardableResult
    func refresh(trigger: Trigger) async -> GitStatusSnapshot? {
        guard !isShutDown else { return nil }
        activeRefreshes += 1
        defer {
            activeRefreshes -= 1
            if activeRefreshes == 0 {
                let waiters = refreshDrainWaiters
                refreshDrainWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        guard let rootPath = selectedRootPath else {
            snapshotGeneration &+= 1
            let snap = GitStatusSnapshot(
                rootPath: "",
                gitRootPath: nil,
                isGitRepo: false,
                backendKind: nil,
                unstagedFiles: [],
                currentBranch: nil,
                availableBranches: [],
                availableRemoteBranches: [],
                availableTags: [],
                gitWorktreeContext: nil,
                totalAdditions: 0,
                totalDeletions: 0,
                commitDelta: nil,
                errorMessage: "No root folder selected",
                trigger: trigger,
                generation: snapshotGeneration
            )
            latestSnapshot = snap
            statusContinuation?.yield(snap)
            return snap
        }

        // For background polls, skip work if git is disabled
        if inclusionMode == .none && trigger == .backgroundPoll {
            return latestSnapshot
        }

        let rootInfo = rootInfos[rootPath]
        let isRepo = rootInfo?.isRepo ?? false
        let gitRootPath = rootInfo?.repoRootPath
        let backendKind = rootInfo?.backendKind

        // If not a repo, emit an error snapshot
        guard isRepo, let gitRoot = gitRootPath else {
            snapshotGeneration &+= 1
            let snap = GitStatusSnapshot(
                rootPath: rootPath,
                gitRootPath: nil,
                isGitRepo: false,
                backendKind: nil,
                unstagedFiles: [],
                currentBranch: nil,
                availableBranches: [],
                availableRemoteBranches: [],
                availableTags: [],
                gitWorktreeContext: nil,
                totalAdditions: 0,
                totalDeletions: 0,
                commitDelta: nil,
                errorMessage: "Not a VCS repository",
                trigger: trigger,
                generation: snapshotGeneration
            )
            latestSnapshot = snap
            statusContinuation?.yield(snap)
            return snap
        }

        let repoURL = URL(fileURLWithPath: gitRoot)
        let backend = await vcsService.backend(forRepoRoot: repoURL)
        guard !isShutDown else { return nil }

        // Passive refresh uses existing tracking refs. Fetch remains an
        // explicit operation: opening a popover must not start transports.

        // Compute compare spec (normalize HEAD for jj backend)
        let baseRef = backend.normalizeBaseRef(selectedDiffBranch)
        let compareSpec: GitDiffCompareSpec = selectedDiffBranch.caseInsensitiveCompare("HEAD") == .orderedSame
            ? .uncommitted(base: baseRef)
            : .uncommittedMergeBase(base: baseRef)

        // Parallel fetch from VCS backend
        async let statsTask: (files: [VCSUncommittedFile], error: Error?) = {
            do {
                let files = try await backend.getChangedFilesStats(
                    compare: compareSpec,
                    includeUntrackedWhenApplicable: true,
                    detectRenames: false,
                    at: repoURL
                )
                return (files, nil)
            } catch {
                return ([], error)
            }
        }()
        async let branchTask = (try? backend.getCurrentBranch(at: repoURL))
        async let branchesTask = (try? backend.getLocalBranches(at: repoURL, limit: 50))
        async let remoteBranchesTask = (try? backend.getRemoteBranches(at: repoURL, limit: 10))
        async let tagsTask = (try? backend.getTags(at: repoURL, limit: 50))
        async let gitWorktreeContextTask = vcsService.gitWorktreeContext(for: URL(fileURLWithPath: rootPath))

        var files: [VCSUncommittedFile] = []
        var currentBranch: String?
        var branches: [VCSBranch] = []
        var remoteBranches: [VCSBranch] = []
        var tags: [VCSTag] = []
        var gitWorktreeContext: GitWorktreeContextSummary?
        var errorMsg: String?
        var delta: (ahead: Int, behind: Int)?

        let statsResult = await statsTask
        files = statsResult.files
        if let error = statsResult.error {
            errorMsg = error.localizedDescription
        }
        currentBranch = await branchTask
        branches = await branchesTask ?? []
        remoteBranches = await remoteBranchesTask ?? []
        tags = await tagsTask ?? []
        gitWorktreeContext = await gitWorktreeContextTask ?? rootInfo?.gitWorktreeContext
        guard !isShutDown else { return nil }
        rootInfos[rootPath] = RootInfo(
            isRepo: true,
            repoRootPath: gitRoot,
            backendKind: backendKind,
            resolvedRepo: backendKind.map { VCSResolvedRepo(rootURL: repoURL, backendKind: $0) },
            gitWorktreeContext: gitWorktreeContext
        )

        // Ahead/behind for non-tag branches (only when comparing to a branch, not HEAD)
        if selectedDiffBranch != "HEAD" {
            let isTag = tags.contains { $0.name == selectedDiffBranch }
            if !isTag {
                delta = try? await backend.getAheadBehind(vs: selectedDiffBranch, at: repoURL)
            }
        }
        guard !isShutDown else { return nil }

        let totalAdd = files.compactMap(\.additions).reduce(0, +)
        let totalDel = files.compactMap(\.deletions).reduce(0, +)

        let sortedBranches = branches.sortedForDisplay(by: .recent)
        var cappedBranches = Array(sortedBranches.prefix(10))
        if selectedDiffBranch != "HEAD",
           !cappedBranches.contains(where: { $0.name == selectedDiffBranch }),
           let selectedBranch = branches.first(where: { $0.name == selectedDiffBranch })
        {
            cappedBranches.insert(selectedBranch, at: 0)
            if cappedBranches.count > 10 {
                cappedBranches.removeLast()
            }
        }

        // Remote branches are already sorted by most recent commit date from GitService
        // Cap to 10 but keep selected remote branch visible if it's a remote ref
        var cappedRemoteBranches = Array(remoteBranches.prefix(10))
        if selectedDiffBranch != "HEAD",
           selectedDiffBranch.contains("/"), // Remote branches contain "/" (e.g., origin/main)
           !cappedRemoteBranches.contains(where: { $0.name == selectedDiffBranch }),
           let selectedRemote = remoteBranches.first(where: { $0.name == selectedDiffBranch })
        {
            cappedRemoteBranches.insert(selectedRemote, at: 0)
            if cappedRemoteBranches.count > 10 {
                cappedRemoteBranches.removeLast()
            }
        }

        snapshotGeneration &+= 1
        let snap = GitStatusSnapshot(
            rootPath: rootPath,
            gitRootPath: gitRoot,
            isGitRepo: true,
            backendKind: backendKind,
            unstagedFiles: files,
            currentBranch: currentBranch,
            availableBranches: cappedBranches,
            availableRemoteBranches: cappedRemoteBranches,
            availableTags: tags,
            gitWorktreeContext: gitWorktreeContext,
            totalAdditions: totalAdd,
            totalDeletions: totalDel,
            commitDelta: delta,
            errorMessage: errorMsg,
            trigger: trigger,
            generation: snapshotGeneration
        )

        latestSnapshot = snap
        statusContinuation?.yield(snap)
        return snap
    }

    // MARK: - Polling

    private func startPollingIfNeeded() {
        guard !isShutDown, pollingTask == nil, inclusionMode != .none else { return }

        pollingTask = Task {
            while !Task.isCancelled {
                try? await waitForNextPoll()
                if Task.isCancelled { break }

                guard !isShutDown, inclusionMode != .none else { break }
                _ = await refresh(trigger: .backgroundPoll)
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func restartPollingIfNeeded() {
        guard !isShutDown else { return }
        stopPolling()
        startPollingIfNeeded()
    }

    /// Terminal window teardown: late mode/root updates must not restart this actor's poller.
    func shutdown() async {
        isShutDown = true
        pollingTask?.cancel()
        statusContinuation?.finish()
        statusContinuation = nil
        // Keep the handle until it drains so concurrent shutdown callers also wait for it.
        await pollingTask?.value
        pollingTask = nil
        // Observer refreshes and previously cancelled polls may not own the current task handle.
        if activeRefreshes > 0 {
            await withCheckedContinuation { continuation in
                refreshDrainWaiters.append(continuation)
                #if DEBUG
                    test_refreshDrainStarted?()
                #endif
            }
        }
    }

    #if DEBUG
        func test_setRefreshDrainStarted(_ callback: (@Sendable () -> Void)?) {
            test_refreshDrainStarted = callback
        }

        func test_setPollingWait(_ wait: @escaping @Sendable () async throws -> Void) {
            precondition(pollingTask == nil && !isShutDown)
            waitForNextPoll = wait
        }

        var test_hasPollingTask: Bool {
            pollingTask != nil
        }

        var test_latestSnapshot: GitStatusSnapshot? {
            latestSnapshot
        }
    #endif

    // MARK: - Diff Generation

    private func ensureSnapshot(for rootPath: String, forceRefresh: Bool = false) async -> GitStatusSnapshot? {
        if !forceRefresh, let snap = latestSnapshot, snap.rootPath == rootPath {
            return snap
        }
        return await refresh(trigger: .explicitRefresh)
    }

    func generateDiff(
        rootPath: String,
        inclusionMode: GitDiffInclusionMode,
        selectedAbsolutePaths: [String],
        vsBranch explicitBranch: String? = nil,
        forceRefreshSnapshot: Bool = false
    ) async -> String? {
        guard inclusionMode != .none else { return nil }
        guard let snap = await ensureSnapshot(for: rootPath, forceRefresh: forceRefreshSnapshot),
              snap.rootPath == rootPath,
              snap.isGitRepo,
              let gitRoot = snap.gitRootPath
        else { return nil }

        let repoURL = URL(fileURLWithPath: gitRoot)
        let effectiveBranch = explicitBranch ?? selectedDiffBranch

        // Comparing a remote branch reads the last explicitly fetched refs.

        let scope: GitDiffScope = (inclusionMode == .all) ? .all : .selected
        let selectedAbs = (inclusionMode == .selectedFiles) ? selectedAbsolutePaths : []
        do {
            let target: GitDiffTarget = effectiveBranch.caseInsensitiveCompare("HEAD") == .orderedSame
                ? .uncommitted(base: effectiveBranch)
                : .uncommittedMergeBase(base: effectiveBranch)
            let result = try await diffEngine.diffText(
                target: target,
                scope: scope,
                selectedAbsolutePaths: selectedAbs,
                repoURL: repoURL,
                allowCachedResult: !forceRefreshSnapshot
            )
            return result.text.isEmpty ? nil : result.text
        } catch {
            return nil
        }
    }

    /// Get the latest snapshot synchronously (useful for checking current state)
    func getLatestSnapshot() -> GitStatusSnapshot? {
        latestSnapshot
    }
}
