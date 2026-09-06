import CryptoKit
import Foundation

enum GitWorktreeDefaultPathPlanner {
    enum Purpose: Equatable {
        case standaloneCreate(now: Date)
        case agentStart(sessionID: String)
    }

    struct Request: Equatable {
        var mainWorktreeRoot: URL
        var existingWorktreeRoots: [URL]
        var explicitPath: URL?
        var branch: String?
        var baseRef: String?
        var detach: Bool
        var force: Bool
        var lockReason: String?
        var allowExternalPath: Bool
        var purpose: Purpose

        init(
            mainWorktreeRoot: URL,
            existingWorktreeRoots: [URL] = [],
            explicitPath: URL? = nil,
            branch: String? = nil,
            baseRef: String? = nil,
            detach: Bool = false,
            force: Bool = false,
            lockReason: String? = nil,
            allowExternalPath: Bool = false,
            purpose: Purpose
        ) {
            self.mainWorktreeRoot = mainWorktreeRoot
            self.existingWorktreeRoots = existingWorktreeRoots
            self.explicitPath = explicitPath
            self.branch = branch
            self.baseRef = baseRef
            self.detach = detach
            self.force = force
            self.lockReason = lockReason
            self.allowExternalPath = allowExternalPath
            self.purpose = purpose
        }
    }

    struct Plan: Equatable {
        var path: URL
        var branch: String?
        var appManagedContainer: URL
        var createRequest: GitWorktreeCreateRequest
    }

    static func plan(_ request: Request) throws -> Plan {
        let mainRoot = request.mainWorktreeRoot.standardizedFileURL
        let container = defaultContainer(forMainWorktreeRoot: mainRoot)
        let existingRoots = standardizedExistingRoots(request.existingWorktreeRoots, mainRoot: mainRoot)
        let path: URL
        if let explicitPath = request.explicitPath {
            let expanded = expandTilde(in: explicitPath).standardizedFileURL
            try validate(
                path: expanded,
                mainWorktreeRoot: mainRoot,
                knownWorktreeRoots: existingRoots,
                appManagedContainer: container,
                allowExternalPath: request.allowExternalPath
            )
            path = expanded
        } else {
            path = uniqueDefaultPath(
                in: container,
                leaf: defaultLeaf(for: request),
                occupiedRoots: existingRoots
            )
        }

        let branch = normalizedBranch(request.branch) ?? defaultBranch(for: request)
        let copyWorktreeIncludeFiles = isPath(path, equalToOrInside: container)
        let createRequest = GitWorktreeCreateRequest(
            path: path,
            branch: branch,
            baseRef: request.baseRef,
            detach: request.detach,
            force: request.force,
            lockReason: request.lockReason,
            allowExternalPath: request.allowExternalPath,
            appManagedContainer: container,
            mainWorktreeRoot: mainRoot,
            knownWorktreeRoots: existingRoots,
            copyWorktreeIncludeFiles: copyWorktreeIncludeFiles
        )
        return Plan(path: path, branch: branch, appManagedContainer: container, createRequest: createRequest)
    }

    static func defaultContainer(forMainWorktreeRoot mainRoot: URL) -> URL {
        mainRoot
            .deletingLastPathComponent()
            .appendingPathComponent(".repoprompt-worktrees", isDirectory: true)
            .appendingPathComponent(mainRoot.lastPathComponent, isDirectory: true)
            .standardizedFileURL
    }

    static func validate(
        path rawPath: URL,
        mainWorktreeRoot: URL,
        knownWorktreeRoots: [URL],
        appManagedContainer: URL?,
        allowExternalPath: Bool
    ) throws {
        let path = expandTilde(in: rawPath).standardizedFileURL
        guard path.path.hasPrefix("/") else {
            throw GitService.GitError(message: "worktree path must be absolute: \(rawPath.path)")
        }

        let mainRoot = mainWorktreeRoot.standardizedFileURL
        let knownRoots = standardizedExistingRoots(knownWorktreeRoots, mainRoot: mainRoot)
        for root in knownRoots {
            let dotGit = root.appendingPathComponent(".git", isDirectory: true)
            if isPath(path, equalToOrInside: dotGit) {
                throw GitService.GitError(message: "worktree path must not be inside a .git directory: \(path.path)")
            }
            if isPath(path, equalToOrInside: root) {
                throw GitService.GitError(message: "worktree path must not be inside an existing worktree: \(path.path)")
            }
        }

        if let appManagedContainer,
           !isPath(path, equalToOrInside: appManagedContainer.standardizedFileURL),
           !allowExternalPath
        {
            throw GitService.GitError(message: "external worktree path requires allow_external_path=true: \(path.path)")
        }
    }

    private static func defaultLeaf(for request: Request) -> String {
        let slug = readableSlug(from: request.branch ?? request.baseRef ?? fallbackSlug(for: request.purpose))
        let branchHashComponent = request.branch.map { "-\(shortHash($0))" } ?? ""
        switch request.purpose {
        case .standaloneCreate:
            return "rp-worktree-\(slug)\(branchHashComponent)-\(shortHash(slug))"
        case let .agentStart(sessionID):
            return "rp-agent-\(shortSessionID(sessionID))-\(slug)\(branchHashComponent)"
        }
    }

    private static func defaultBranch(for request: Request) -> String? {
        guard !request.detach else { return nil }
        let slug = readableSlug(from: request.branch ?? request.baseRef ?? fallbackSlug(for: request.purpose))
        switch request.purpose {
        case let .standaloneCreate(now):
            return "rp/worktree/\(dateStamp(now))-\(slug)"
        case let .agentStart(sessionID):
            return "rp/agent/\(shortSessionID(sessionID))-\(slug)"
        }
    }

    private static func uniqueDefaultPath(in container: URL, leaf: String, occupiedRoots: [URL]) -> URL {
        var candidate = container.appendingPathComponent(leaf, isDirectory: true).standardizedFileURL
        var suffix = 2
        let occupiedPaths = Set(occupiedRoots.map(\.standardizedFileURL.path))
        while pathExists(candidate) || occupiedPaths.contains(candidate.path) {
            candidate = container.appendingPathComponent("\(leaf)-\(suffix)", isDirectory: true).standardizedFileURL
            suffix += 1
        }
        return candidate
    }

    private static func standardizedExistingRoots(_ roots: [URL], mainRoot: URL) -> [URL] {
        let standardizedMain = mainRoot.standardizedFileURL
        var result = [standardizedMain]
        var seen = Set([standardizedMain.path])
        for root in roots.map({ expandTilde(in: $0).standardizedFileURL }) {
            if seen.insert(root.path).inserted {
                result.append(root)
            }
        }
        return result
    }

    private static func normalizedBranch(_ branch: String?) -> String? {
        guard let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty else {
            return nil
        }
        return branch
    }

    private static func fallbackSlug(for purpose: Purpose) -> String {
        switch purpose {
        case .standaloneCreate:
            "worktree"
        case .agentStart:
            "agent"
        }
    }

    private static func readableSlug(from input: String) -> String {
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
        if slug.count > 32 {
            slug = String(slug.prefix(32))
            while slug.hasSuffix("-") {
                slug.removeLast()
            }
        }
        return slug.isEmpty ? "worktree" : slug
    }

    private static func shortSessionID(_ sessionID: String) -> String {
        let slug = readableSlug(from: sessionID)
        return String(slug.prefix(8)).isEmpty ? shortHash(sessionID) : String(slug.prefix(8))
    }

    private static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func shortHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    private static func expandTilde(in url: URL) -> URL {
        let path = url.path
        guard path == "~" || path.hasPrefix("~/") else { return url }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let suffix = path == "~" ? "" : String(path.dropFirst(2))
        return URL(fileURLWithPath: home).appendingPathComponent(suffix)
    }

    private static func pathExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func isPath(_ path: URL, equalToOrInside root: URL) -> Bool {
        let pathComponents = path.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard pathComponents.count >= rootComponents.count else { return false }
        return Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }
}
