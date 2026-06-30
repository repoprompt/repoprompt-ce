import CryptoKit
import Foundation

// MARK: - Git Worktree Models

public struct GitWorktreeRepositoryIdentity: Sendable, Equatable, Hashable {
    public let repositoryID: String
    public let repoKey: String
    public let displayName: String
    public let commonGitDir: String
    public let mainWorktreeRoot: String?

    public init(
        repositoryID: String,
        repoKey: String,
        displayName: String,
        commonGitDir: String,
        mainWorktreeRoot: String?
    ) {
        self.repositoryID = repositoryID
        self.repoKey = repoKey
        self.displayName = displayName
        self.commonGitDir = commonGitDir
        self.mainWorktreeRoot = mainWorktreeRoot
    }
}

public struct GitWorktreeDescriptor: Sendable, Equatable, Hashable {
    public let worktreeID: String
    public let repository: GitWorktreeRepositoryIdentity
    public let path: String
    public let gitDir: String?
    public let name: String?
    public let branch: String?
    public let head: String?
    public let isMain: Bool
    public let isCurrent: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool
    public let prunableReason: String?

    public init(
        worktreeID: String,
        repository: GitWorktreeRepositoryIdentity,
        path: String,
        gitDir: String?,
        name: String?,
        branch: String?,
        head: String?,
        isMain: Bool,
        isCurrent: Bool,
        isDetached: Bool,
        isLocked: Bool,
        lockReason: String?,
        isPrunable: Bool,
        prunableReason: String?
    ) {
        self.worktreeID = worktreeID
        self.repository = repository
        self.path = path
        self.gitDir = gitDir
        self.name = name
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.isCurrent = isCurrent
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
    }
}

public struct GitWorktreeContextSummary: Sendable, Equatable, Hashable {
    public let repositoryID: String
    public let repoKey: String
    public let repositoryDisplayName: String
    public let worktreeID: String?
    public let worktreePath: String
    public let worktreeName: String
    public let isMain: Bool
    public let branch: String?
    public let head: String?
    public let isDetached: Bool

    public init(
        repositoryID: String,
        repoKey: String,
        repositoryDisplayName: String,
        worktreeID: String?,
        worktreePath: String,
        worktreeName: String,
        isMain: Bool,
        branch: String?,
        head: String?,
        isDetached: Bool
    ) {
        self.repositoryID = repositoryID
        self.repoKey = repoKey
        self.repositoryDisplayName = repositoryDisplayName
        self.worktreeID = worktreeID
        self.worktreePath = worktreePath
        self.worktreeName = worktreeName
        self.isMain = isMain
        self.branch = Self.normalizedOptional(branch)
        self.head = Self.normalizedOptional(head)
        self.isDetached = isDetached
    }

    public init(descriptor: GitWorktreeDescriptor) {
        self.init(
            repositoryID: descriptor.repository.repositoryID,
            repoKey: descriptor.repository.repoKey,
            repositoryDisplayName: descriptor.repository.displayName,
            worktreeID: descriptor.worktreeID,
            worktreePath: descriptor.path,
            worktreeName: descriptor.name ?? Self.fallbackWorktreeName(from: descriptor.path),
            isMain: descriptor.isMain,
            branch: descriptor.branch,
            head: descriptor.head,
            isDetached: descriptor.isDetached
        )
    }

    public var branchDisplayText: String? {
        if let branch {
            return branch
        }
        if isDetached, let short = shortHead {
            return "detached @ \(short)"
        }
        if let short = shortHead {
            return "HEAD @ \(short)"
        }
        return nil
    }

    public var breadcrumbText: String {
        [repositoryDisplayName, worktreeName, branchDisplayText]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    public var checkoutDisplayText: String {
        isMain ? "main repository checkout" : "linked worktree"
    }

    public var tooltipText: String {
        let branchText = branchDisplayText ?? "unknown branch"
        let parts = [
            "Repository: \(repositoryDisplayName)",
            "Checkout: \(checkoutDisplayText)",
            "Worktree: \(worktreeName)",
            "Branch: \(branchText)",
            "Path: \(worktreePath)"
        ]
        return parts.joined(separator: "\n")
    }

    public var accessibilityText: String {
        let branchText = branchDisplayText ?? "unknown branch"
        return "Git repository \(repositoryDisplayName), \(checkoutDisplayText) \(worktreeName), branch \(branchText)"
    }

    private var shortHead: String? {
        guard let head else { return nil }
        return String(head.prefix(7))
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func fallbackWorktreeName(from path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? "worktree" : last
    }
}

public struct GitWorktreeCreateRequest: Sendable, Equatable {
    public let path: URL
    public let branch: String?
    public let baseRef: String?
    public let detach: Bool
    public let force: Bool
    public let lockReason: String?
    public let allowExternalPath: Bool
    public let appManagedContainer: URL?
    public let mainWorktreeRoot: URL?
    public let knownWorktreeRoots: [URL]
    public let copyWorktreeIncludeFiles: Bool

    public init(
        path: URL,
        branch: String? = nil,
        baseRef: String? = nil,
        detach: Bool = false,
        force: Bool = false,
        lockReason: String? = nil,
        allowExternalPath: Bool = false,
        appManagedContainer: URL? = nil,
        mainWorktreeRoot: URL? = nil,
        knownWorktreeRoots: [URL] = [],
        copyWorktreeIncludeFiles: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.baseRef = baseRef
        self.detach = detach
        self.force = force
        self.lockReason = lockReason
        self.allowExternalPath = allowExternalPath
        self.appManagedContainer = appManagedContainer
        self.mainWorktreeRoot = mainWorktreeRoot
        self.knownWorktreeRoots = knownWorktreeRoots
        self.copyWorktreeIncludeFiles = copyWorktreeIncludeFiles
    }
}

public struct GitWorktreeCreateResult: Sendable, Equatable {
    public let descriptor: GitWorktreeDescriptor
    public let includeCopyResult: GitWorktreeIncludeCopyResult?
    let initializationReceipt: GitWorktreeCreationReceipt?
    let initializationFallbackReason: WorkspaceRootSeedFallbackReason?

    public init(
        descriptor: GitWorktreeDescriptor,
        includeCopyResult: GitWorktreeIncludeCopyResult? = nil
    ) {
        self.descriptor = descriptor
        self.includeCopyResult = includeCopyResult
        initializationReceipt = nil
        initializationFallbackReason = nil
    }

    init(
        descriptor: GitWorktreeDescriptor,
        includeCopyResult: GitWorktreeIncludeCopyResult?,
        initializationReceipt: GitWorktreeCreationReceipt?,
        initializationFallbackReason: WorkspaceRootSeedFallbackReason? = nil
    ) {
        self.descriptor = descriptor
        self.includeCopyResult = includeCopyResult
        self.initializationReceipt = initializationReceipt
        self.initializationFallbackReason = initializationFallbackReason
    }
}

public struct GitWorktreeIncludeCopyResult: Sendable, Equatable {
    public let copiedCount: Int
    public let matchedCount: Int
    public let copiedRelativePaths: [String]
    public let skippedSummaries: [String]
    public let errorSummaries: [String]

    public init(
        copiedCount: Int,
        matchedCount: Int,
        copiedRelativePaths: [String] = [],
        skippedSummaries: [String] = [],
        errorSummaries: [String] = []
    ) {
        self.copiedCount = copiedCount
        self.matchedCount = matchedCount
        self.copiedRelativePaths = copiedRelativePaths
        self.skippedSummaries = skippedSummaries
        self.errorSummaries = errorSummaries
    }

    public var warningText: String? {
        let details = (skippedSummaries + errorSummaries).filter { !$0.isEmpty }
        guard !details.isEmpty else { return nil }
        let detailText = details.prefix(5).joined(separator: "; ")
        let remaining = details.count - min(details.count, 5)
        let suffix = remaining > 0 ? "; +\(remaining) more" : ""
        return ".worktreeinclude copied \(copiedCount) of \(matchedCount) eligible file(s); some files were skipped or failed: \(detailText)\(suffix)"
    }
}

// MARK: - Git Worktree Identity Helpers

enum GitWorktreeIdentity {
    static func repositoryIdentity(
        commonGitDir: URL,
        mainWorktreeRoot: URL?
    ) -> GitWorktreeRepositoryIdentity {
        let commonGitDirPath = standardizedPath(commonGitDir)
        let mainPath = mainWorktreeRoot.map(standardizedPath)
        let displayName: String
        if let mainWorktreeRoot {
            displayName = mainWorktreeRoot.lastPathComponent
        } else {
            let last = commonGitDir.deletingLastPathComponent().lastPathComponent
            displayName = last.isEmpty ? "repository" : last
        }
        let repoKey = makeRepoKey(for: commonGitDirPath, displayName: displayName)
        return GitWorktreeRepositoryIdentity(
            repositoryID: "gitrepo_\(sha256Hex(commonGitDirPath))",
            repoKey: repoKey,
            displayName: displayName,
            commonGitDir: commonGitDirPath,
            mainWorktreeRoot: mainPath
        )
    }

    static func worktreeID(
        repositoryID: String,
        gitDir: URL?,
        isMain: Bool,
        path: URL
    ) -> String {
        let stableComponent: String = if isMain {
            "main"
        } else if let gitDir {
            standardizedPath(gitDir)
        } else {
            // Prunable/malformed linked worktrees may no longer have a resolvable gitdir.
            // Keep an ID available for list output; if the worktree is repaired/moved,
            // V1 treats that as a new identity.
            standardizedPath(path)
        }
        return "wt_\(sha256Hex("\(repositoryID)\u{0}\(stableComponent)"))"
    }

    static func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func makeRepoKey(for path: String, displayName: String) -> String {
        "\(sanitizeSlug(displayName))-\(String(sha256Hex(path).prefix(8)))"
    }

    private static func sanitizeSlug(_ input: String) -> String {
        var slug = ""
        var lastWasHyphen = true
        for character in input.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                slug.append("-")
                lastWasHyphen = true
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        if slug.count > 24 {
            slug = String(slug.prefix(24))
            while slug.hasSuffix("-") {
                slug.removeLast()
            }
        }
        return slug.isEmpty ? "repo" : slug
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Git Worktree Porcelain Parser

struct GitWorktreePorcelainRecord: Equatable {
    var path: String
    var head: String?
    var branch: String?
    var isDetached: Bool
    var isBare: Bool
    var isLocked: Bool
    var lockReason: String?
    var isPrunable: Bool
    var prunableReason: String?
}

enum GitWorktreePorcelainFormat {
    case nulTerminated
    case newlineTerminated
}

enum GitWorktreePorcelainParser {
    static func parse(_ output: String, format: GitWorktreePorcelainFormat) throws -> [GitWorktreePorcelainRecord] {
        switch format {
        case .nulTerminated:
            try parseTokens(output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init))
        case .newlineTerminated:
            try parseTokens(output.components(separatedBy: .newlines))
        }
    }

    private static func parseTokens(_ tokens: [String]) throws -> [GitWorktreePorcelainRecord] {
        var records: [GitWorktreePorcelainRecord] = []
        var builder: GitWorktreePorcelainRecordBuilder?

        for rawToken in tokens {
            guard !rawToken.isEmpty else {
                if let current = builder {
                    try records.append(current.finish())
                    builder = nil
                }
                continue
            }

            let (key, value) = splitAttribute(rawToken)
            if key == "worktree" {
                if let current = builder {
                    try records.append(current.finish())
                }
                builder = GitWorktreePorcelainRecordBuilder(path: value)
                continue
            }

            guard builder != nil else {
                throw VCSError.parseError(message: "worktree porcelain attribute appeared before worktree path: \(key)")
            }
            try builder?.apply(key: key, value: value)
        }

        if let current = builder {
            try records.append(current.finish())
        }
        return records
    }

    private static func splitAttribute(_ line: String) -> (key: String, value: String) {
        guard let spaceIndex = line.firstIndex(of: " ") else {
            return (line, "")
        }
        let key = String(line[..<spaceIndex])
        let valueStart = line.index(after: spaceIndex)
        return (key, String(line[valueStart...]))
    }
}

private struct GitWorktreePorcelainRecordBuilder {
    var path: String
    var head: String?
    var branch: String?
    var isDetached = false
    var isBare = false
    var isLocked = false
    var lockReason: String?
    var isPrunable = false
    var prunableReason: String?

    mutating func apply(key: String, value: String) throws {
        switch key {
        case "HEAD":
            head = value.isEmpty ? nil : value
        case "branch":
            branch = normalizeBranch(value)
        case "detached":
            isDetached = true
        case "bare":
            isBare = true
        case "locked":
            isLocked = true
            lockReason = value.isEmpty ? nil : value
        case "prunable":
            isPrunable = true
            prunableReason = value.isEmpty ? nil : value
        default:
            // Preserve forward compatibility with future porcelain attributes.
            break
        }
    }

    func finish() throws -> GitWorktreePorcelainRecord {
        guard !path.isEmpty else {
            throw VCSError.parseError(message: "worktree porcelain record is missing a path")
        }
        return GitWorktreePorcelainRecord(
            path: path,
            head: head,
            branch: branch,
            isDetached: isDetached,
            isBare: isBare,
            isLocked: isLocked,
            lockReason: lockReason,
            isPrunable: isPrunable,
            prunableReason: prunableReason
        )
    }

    private func normalizeBranch(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let prefix = "refs/heads/"
        if value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }
}

// MARK: - Git Worktree Mutation Coordinator

actor GitWorktreeMutationCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var busyKeys: Set<String> = []
    private var waitersByKey: [String: [Waiter]] = [:]
    #if DEBUG
        private var queuedWaiterObservationContinuationsByKey: [
            String: [CheckedContinuation<Void, Never>]
        ] = [:]
    #endif

    func withLock<T: Sendable>(
        key: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        #if DEBUG
            let benchmarkMetricTag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
            let waitStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        try await acquire(key: key)
        #if DEBUG
            let acquired = DispatchTime.now().uptimeNanoseconds
        #endif
        do {
            try Task.checkCancellation()
            let value = try await operation()
            #if DEBUG
                let finished = DispatchTime.now().uptimeNanoseconds
                WorktreeStartupInstrumentation.recordBenchmarkMutationLock(
                    tag: benchmarkMetricTag,
                    queueWaitMicroseconds: (acquired - waitStarted) / 1000,
                    heldMicroseconds: (finished - acquired) / 1000
                )
            #endif
            release(key: key)
            return value
        } catch {
            #if DEBUG
                let finished = DispatchTime.now().uptimeNanoseconds
                WorktreeStartupInstrumentation.recordBenchmarkMutationLock(
                    tag: benchmarkMetricTag,
                    queueWaitMicroseconds: (acquired - waitStarted) / 1000,
                    heldMicroseconds: (finished - acquired) / 1000
                )
            #endif
            release(key: key)
            throw error
        }
    }

    private func acquire(key: String) async throws {
        if !busyKeys.contains(key) {
            busyKeys.insert(key)
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waitersByKey[key, default: []].append(Waiter(id: waiterID, continuation: continuation))
                #if DEBUG
                    let observationContinuations = queuedWaiterObservationContinuationsByKey
                        .removeValue(forKey: key) ?? []
                    for observationContinuation in observationContinuations {
                        observationContinuation.resume()
                    }
                #endif
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, id: waiterID) }
        }
    }

    private func release(key: String) {
        guard var waiters = waitersByKey[key], !waiters.isEmpty else {
            busyKeys.remove(key)
            waitersByKey.removeValue(forKey: key)
            return
        }

        let next = waiters.removeFirst()
        waitersByKey[key] = waiters.isEmpty ? nil : waiters
        next.continuation.resume()
    }

    private func cancelWaiter(key: String, id: UUID) {
        guard var waiters = waitersByKey[key],
              let index = waiters.firstIndex(where: { $0.id == id })
        else { return }

        let waiter = waiters.remove(at: index)
        waitersByKey[key] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    #if DEBUG
        func waitForQueuedWaiterForTesting(key: String) async {
            if waitersByKey[key]?.isEmpty == false { return }
            await withCheckedContinuation { continuation in
                queuedWaiterObservationContinuationsByKey[key, default: []].append(continuation)
            }
        }
    #endif
}
