import Foundation
import RepoPromptVCS

// MARK: - Git Branch Switch Models

enum GitShortRef {
    static func shortHead(_ head: String) -> String {
        String(head.prefix(7))
    }

    static func detachedLabel(head: String) -> String {
        "detached \(shortHead(head))"
    }
}

struct GitBranchSwitchOptions: Equatable {
    let rootPath: String
    let repoRootPath: String
    let currentBranch: String?
    let currentHead: String
    let isDetached: Bool
    let branches: [VCSBranch]
}

enum GitBranchSwitchPreflightWarning: String, Equatable {
    case detachedHead
    case uncommittedChanges
    case mergeInProgress
}

struct GitBranchSwitchPreflight: Equatable {
    let rootPath: String
    let repoRootPath: String
    let targetBranch: String
    let currentBranch: String?
    let currentHead: String
    let isCurrentBranch: Bool
    let warnings: [GitBranchSwitchPreflightWarning]

    var isDetached: Bool {
        currentBranch == nil
    }
}

struct GitBranchSwitchRequest: Equatable {
    let branchName: String
    let expectedCurrentBranch: String?
    let expectedCurrentHead: String?

    init(
        branchName: String,
        expectedCurrentBranch: String? = nil,
        expectedCurrentHead: String? = nil
    ) {
        self.branchName = branchName
        self.expectedCurrentBranch = expectedCurrentBranch
        self.expectedCurrentHead = expectedCurrentHead
    }
}

struct GitBranchSwitchResult: Equatable {
    let rootPath: String
    let repoRootPath: String
    let previousBranch: String?
    let previousHead: String
    let newBranch: String
    let newHead: String
    let didSwitch: Bool
}

enum GitBranchSwitchError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidBranchName(String)
    case branchNotLocal(String)
    case branchCheckedOutInWorktree(branch: String, worktreePath: String, worktreeName: String?)
    case staleCheckout(expectedBranch: String?, actualBranch: String?, expectedHead: String?, actualHead: String?)
    case gitRefused(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return message
        case let .invalidBranchName(branch):
            return "Invalid Git branch name for branch switching: \(branch)"
        case let .branchNotLocal(branch):
            return "Local branch not found: \(branch). RepoPrompt only switches existing local branches in this UI."
        case let .branchCheckedOutInWorktree(branch, worktreePath, worktreeName):
            if let worktreeName = worktreeName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !worktreeName.isEmpty
            {
                return "Cannot switch this checkout to \(branch) because that branch is already checked out in worktree \(worktreeName) at \(worktreePath)."
            }
            return "Cannot switch this checkout to \(branch) because that branch is already checked out in another worktree at \(worktreePath)."
        case let .staleCheckout(expectedBranch, actualBranch, expectedHead, actualHead):
            let expected = expectedBranch ?? expectedHead.map(GitShortRef.detachedLabel(head:)) ?? "unknown checkout"
            let actual = actualBranch ?? actualHead.map(GitShortRef.detachedLabel(head:)) ?? "unknown checkout"
            return "The checkout changed before RepoPrompt switched branches. Expected \(expected), now on \(actual). Reload branches and try again."
        case let .gitRefused(message):
            return GitService.friendlyErrorDescription(for: message)
        }
    }
}
