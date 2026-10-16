import CryptoKit
import Foundation
import RepoPromptInstrumentation

// MARK: - Git Worktree Models

public struct GitWorktreeRepositoryIdentity: Codable, Sendable, Equatable, Hashable {
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

/// Fresh identity resolved from the Git metadata at a worktree root.
///
/// The repository ID and key are derived from the common Git directory, while the worktree ID
/// also incorporates the per-worktree Git directory (or the explicit main-worktree marker).
/// Keeping those values together prevents a path-only resolution from becoming an authority.
public struct GitWorktreeIdentitySnapshot: Codable, Sendable, Equatable, Hashable {
    public let repository: GitWorktreeRepositoryIdentity
    public let worktreeID: String
    public let worktreeRootPath: String
    public let isMain: Bool

    public init(
        repository: GitWorktreeRepositoryIdentity,
        worktreeID: String,
        worktreeRootPath: String,
        isMain: Bool
    ) {
        self.repository = repository
        self.worktreeID = worktreeID
        self.worktreeRootPath = worktreeRootPath
        self.isMain = isMain
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

// MARK: - Git Worktree Identity Helpers

package enum GitWorktreeIdentity {
    package static func repositoryIdentity(
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

    package static func worktreeID(
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

    package static func standardizedPath(_ url: URL) -> String {
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

/// Resolves repository and worktree identity directly from the current Git layout.
///
/// This deliberately performs an uncached metadata read so callers can revalidate a persisted
/// binding after a path has been replaced. Ancestors are considered for bindings to a logical
/// subdirectory inside a checkout; the returned path is always the actual checkout root.
public enum GitWorktreeIdentityResolver {
    public static func resolve(atWorkTreeRoot root: URL) -> GitWorktreeIdentitySnapshot? {
        var candidate = root.standardizedFileURL
        while true {
            if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: candidate) {
                let isMain = !layout.isLinkedWorktree
                let repository = GitWorktreeIdentity.repositoryIdentity(
                    commonGitDir: layout.commonDir,
                    mainWorktreeRoot: isMain ? layout.workTreeRoot : layout.knownMainWorktreeRoot
                )
                let worktreeID = GitWorktreeIdentity.worktreeID(
                    repositoryID: repository.repositoryID,
                    gitDir: isMain ? nil : layout.gitDir,
                    isMain: isMain,
                    path: layout.workTreeRoot
                )
                return GitWorktreeIdentitySnapshot(
                    repository: repository,
                    worktreeID: worktreeID,
                    worktreeRootPath: layout.workTreeRoot.standardizedFileURL.path,
                    isMain: isMain
                )
            }

            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }
}

// MARK: - Git Worktree Porcelain Parser

package struct GitWorktreePorcelainRecord: Equatable {
    package var path: String
    package var head: String?
    package var branch: String?
    package var isDetached: Bool
    package var isBare: Bool
    package var isLocked: Bool
    package var lockReason: String?
    package var isPrunable: Bool
    package var prunableReason: String?

    package init(
        path: String,
        head: String? = nil,
        branch: String? = nil,
        isDetached: Bool,
        isBare: Bool,
        isLocked: Bool,
        lockReason: String? = nil,
        isPrunable: Bool,
        prunableReason: String? = nil
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
    }
}

package enum GitWorktreePorcelainFormat {
    case nulTerminated
    case newlineTerminated
}

package enum GitWorktreePorcelainParser {
    package static func parse(_ output: String, format: GitWorktreePorcelainFormat) throws -> [GitWorktreePorcelainRecord] {
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
