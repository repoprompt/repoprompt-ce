import Foundation

struct GitRepoTargetResolver {
    struct Dependencies {
        var resolveRepo: (URL) async -> GitRepoDescriptor?
        var listWorktrees: (GitRepoDescriptor) async throws -> [GitWorktreeDescriptor]

        static let live = Dependencies(
            resolveRepo: { url in
                guard let resolved = await VCSService.shared.resolveRepo(from: url) else {
                    return nil
                }
                return GitRepoDescriptor(rootURL: resolved.rootURL)
            },
            listWorktrees: { repo in
                try await VCSService.shared.listGitWorktrees(at: repo.rootURL)
            }
        )
    }

    let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func resolveRepoRoots(
        explicitRootTokens: [String]?,
        allRepos: [GitRepoDescriptor],
        visibleRoots: [WorkspaceRootRef],
        defaultRepo: GitRepoDescriptor
    ) async throws -> [GitRepoDescriptor] {
        guard let tokens = explicitRootTokens, !tokens.isEmpty else {
            return [defaultRepo]
        }

        var repos: [GitRepoDescriptor] = []
        var seenKeys = Set<String>()

        for token in tokens {
            let repo = try await resolveRepoRootToken(
                token,
                allRepos: allRepos,
                visibleRoots: visibleRoots,
                defaultRepo: defaultRepo
            )
            let key = repo.rootPath.lowercased()
            if seenKeys.insert(key).inserted {
                repos.append(repo)
            }
        }

        guard !repos.isEmpty else {
            throw GitRepoTargetResolverError.invalidParams("No git repository found for specified roots.")
        }

        return repos
    }

    func resolveRepoRootToken(
        _ token: String,
        allRepos: [GitRepoDescriptor],
        visibleRoots: [WorkspaceRootRef],
        defaultRepo: GitRepoDescriptor
    ) async throws -> GitRepoDescriptor {
        let (baseToken, specifier) = parseRepoTreeSpecifier(token)
        let trimmed = baseToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseRepo = try await resolveBaseRepo(
            trimmed,
            allRepos: allRepos,
            visibleRoots: visibleRoots,
            defaultRepo: defaultRepo,
            allowBareWorktreeSelector: specifier == nil
        )

        if let baseRepo {
            return try await applyTreeSpecifier(
                specifier,
                to: baseRepo,
                allRepos: allRepos,
                defaultRepo: defaultRepo,
                hasExplicitBase: !trimmed.isEmpty,
                authorizedRoots: visibleRoots
            )
        }

        guard specifier == nil else {
            throw GitRepoTargetResolverError.invalidParams("No repo found matching '\(trimmed)'. Available root names: \(visibleRoots.map(\.name).joined(separator: ", "))")
        }

        if let worktree = try await resolveWorktreeSelector(
            trimmed,
            in: candidateRepos(allRepos: allRepos, defaultRepo: defaultRepo),
            selectorKind: .branchNameOrPath
        ) {
            return try await resolveAuthorizedWorktreeRepository(
                worktree,
                advertisingRepos: candidateRepos(allRepos: allRepos, defaultRepo: defaultRepo),
                authorizedRoots: visibleRoots
            )
        }

        let availableNames = visibleRoots.map(\.name).joined(separator: ", ")
        throw GitRepoTargetResolverError.invalidParams("No repo found matching '\(trimmed)'. Available root names: \(availableNames)")
    }

    func resolveWorktree(
        selector rawSelector: String?,
        repo: GitRepoDescriptor,
        allRepos: [GitRepoDescriptor],
        authorizedRoots: [WorkspaceRootRef]? = nil
    ) async throws -> GitWorktreeDescriptor {
        let worktree = try await resolveWorktreeDescriptor(
            selector: rawSelector,
            repo: repo,
            allRepos: allRepos
        )
        if let authorizedRoots {
            _ = try await resolveAuthorizedWorktreeRepository(
                worktree,
                advertisingRepos: [repo],
                authorizedRoots: authorizedRoots
            )
        }
        // Fail closed on stale/prunable worktrees. Git reports a worktree as prunable when its
        // gitdir points to a non-existent location (the checkout was removed or left incomplete).
        // Binding a session to such a worktree, or operating on it, would crawl and search an
        // empty or partial tree and silently return no results, so refuse to resolve it.
        if worktree.isPrunable {
            throw GitRepoTargetResolverError.invalidParams(
                "Worktree '\(worktree.path)' is stale (\(worktree.prunableReason ?? "gitdir points to a non-existent location")). Run `git worktree prune` or recreate the worktree."
            )
        }
        return worktree
    }

    private func resolveWorktreeDescriptor(
        selector rawSelector: String?,
        repo: GitRepoDescriptor,
        allRepos: [GitRepoDescriptor]
    ) async throws -> GitWorktreeDescriptor {
        let selector = rawSelector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "@current"
        let (_, specifier) = parseRepoTreeSpecifier(selector)
        let candidateRepos = candidateRepos(allRepos: allRepos, defaultRepo: repo)

        switch specifier {
        case .current:
            let worktrees = try await worktreesForRepository(containing: repo, candidateRepos: candidateRepos)
            if let current = worktrees.first(where: { samePath($0.path, repo.rootPath) }) {
                return current
            }
            throw GitRepoTargetResolverError.invalidParams("No current worktree found for repo: \(repo.rootPath)")
        case let .main(branch):
            if let branch, !branch.isEmpty {
                if let worktree = try await resolveWorktreeSelector(branch, in: [repo], selectorKind: .branch) {
                    return worktree
                }
                throw GitRepoTargetResolverError.invalidParams("No worktree found for branch '\(branch)'.")
            }
            let worktrees = try await worktreesForRepository(containing: repo, candidateRepos: candidateRepos)
            if let main = worktrees.first(where: \.isMain) {
                return main
            }
            throw GitRepoTargetResolverError.invalidParams("No main worktree found for repo: \(repo.rootPath)")
        case let .id(id):
            if let worktree = try await resolveWorktreeSelector(id, in: candidateRepos, selectorKind: .id) {
                return worktree
            }
            throw GitRepoTargetResolverError.invalidParams("No worktree found for id '\(id)'.")
        case let .branch(branch):
            if let worktree = try await resolveWorktreeSelector(branch, in: candidateRepos, selectorKind: .branch) {
                return worktree
            }
            throw GitRepoTargetResolverError.invalidParams("No worktree found for branch '\(branch)'.")
        case let .worktree(branch):
            if let branch, !branch.isEmpty {
                throw GitRepoTargetResolverError.invalidParams("worktree selector '@wt:\(branch)' is not supported. Use '@branch:\(branch)' to target a worktree by branch or omit the branch.")
            }
            let worktrees = try await worktreesForRepository(containing: repo, candidateRepos: candidateRepos)
            if let current = worktrees.first(where: { samePath($0.path, repo.rootPath) }) {
                return current
            }
            throw GitRepoTargetResolverError.invalidParams("No current worktree found for repo: \(repo.rootPath)")
        case nil:
            if let worktree = try await resolveWorktreeSelector(selector, in: candidateRepos, selectorKind: .branchNameOrPath) {
                return worktree
            }
            throw GitRepoTargetResolverError.invalidParams("No worktree found matching '\(selector)'.")
        }
    }

    // MARK: - Base repo resolution

    private func resolveBaseRepo(
        _ trimmed: String,
        allRepos: [GitRepoDescriptor],
        visibleRoots: [WorkspaceRootRef],
        defaultRepo: GitRepoDescriptor,
        allowBareWorktreeSelector: Bool
    ) async throws -> GitRepoDescriptor? {
        if trimmed.isEmpty {
            return defaultRepo
        }

        let looksLikePath = trimmed.contains("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".")

        if looksLikePath {
            if allowBareWorktreeSelector,
               !trimmed.hasPrefix("/"),
               !trimmed.hasPrefix("~"),
               !trimmed.hasPrefix("."),
               let worktree = try await resolveWorktreeSelector(
                   trimmed,
                   in: candidateRepos(allRepos: allRepos, defaultRepo: defaultRepo),
                   selectorKind: .branchNameOrPath
               )
            {
                return try await resolveAuthorizedWorktreeRepository(
                    worktree,
                    advertisingRepos: candidateRepos(allRepos: allRepos, defaultRepo: defaultRepo),
                    authorizedRoots: visibleRoots
                )
            }

            let visibleRootPaths = visibleRoots.map(\.standardizedFullPath)
            if GitRepoRootAuthorization.isPathWithinAuthorizedRoots(trimmed, roots: visibleRootPaths) {
                let standardized = GitRepoRootAuthorization.canonicalPath(trimmed)

                if let resolved = await dependencies.resolveRepo(URL(fileURLWithPath: standardized)) {
                    return resolved
                }
                throw GitRepoTargetResolverError.invalidParams("No VCS repository found at path: \(trimmed)")
            }

            if let worktree = try await resolveWorktreeSelector(
                trimmed,
                in: candidateRepos(allRepos: allRepos, defaultRepo: defaultRepo),
                selectorKind: .path
            ) {
                return try await resolveAuthorizedWorktreeRepository(
                    worktree,
                    advertisingRepos: candidateRepos(allRepos: allRepos, defaultRepo: defaultRepo),
                    authorizedRoots: visibleRoots
                )
            }

            let rootsList = visibleRootPaths.joined(separator: ", ")
            throw GitRepoTargetResolverError.invalidParams("repo_root path must be inside a loaded root. Received: \(trimmed). Loaded roots: \(rootsList)")
        }

        let lowercasedToken = trimmed.lowercased()

        for folder in visibleRoots where folder.name.lowercased() == lowercasedToken {
            let standardized = folder.standardizedFullPath
            if let resolved = await dependencies.resolveRepo(URL(fileURLWithPath: standardized)) {
                return resolved
            }
        }

        let matches = allRepos.filter { $0.displayName.lowercased() == lowercasedToken }
        if matches.count == 1 {
            return matches[0]
        } else if matches.count > 1 {
            let paths = matches.map(\.rootPath).joined(separator: ", ")
            throw GitRepoTargetResolverError.invalidParams("Ambiguous repo name '\(trimmed)' matches multiple repos: \(paths). Use full path or repo_key to disambiguate.")
        }

        if allowBareWorktreeSelector {
            return nil
        }

        let availableNames = visibleRoots.map(\.name).joined(separator: ", ")
        throw GitRepoTargetResolverError.invalidParams("No repo found matching '\(trimmed)'. Available root names: \(availableNames)")
    }

    // MARK: - Specifier parsing and application

    private enum RepoTreeSpecifier: Equatable {
        case worktree(branch: String?)
        case main(branch: String?)
        case current
        case id(String)
        case branch(String)
    }

    private func parseRepoTreeSpecifier(_ token: String) -> (base: String, specifier: RepoTreeSpecifier?) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = trimmed.lastIndex(of: "@") else {
            return (trimmed, nil)
        }
        let suffix = String(trimmed[trimmed.index(after: atIndex)...])
        let base = String(trimmed[..<atIndex])
        let parts = suffix.split(separator: ":", maxSplits: 1).map(String.init)
        let spec = parts.first?.lowercased() ?? ""
        let valuePart = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let value = (valuePart?.isEmpty ?? true) ? nil : valuePart
        switch spec {
        case "wt", "worktree":
            return (base, .worktree(branch: value))
        case "main", "primary":
            return (base, .main(branch: value))
        case "current":
            return value == nil ? (base, .current) : (trimmed, nil)
        case "id":
            guard let value else { return (trimmed, nil) }
            return (base, .id(value))
        case "branch":
            guard let value else { return (trimmed, nil) }
            return (base, .branch(value))
        default:
            return (trimmed, nil)
        }
    }

    private func applyTreeSpecifier(
        _ specifier: RepoTreeSpecifier?,
        to repo: GitRepoDescriptor,
        allRepos: [GitRepoDescriptor],
        defaultRepo: GitRepoDescriptor,
        hasExplicitBase: Bool,
        authorizedRoots: [WorkspaceRootRef]
    ) async throws -> GitRepoDescriptor {
        guard let specifier else {
            return repo
        }
        switch specifier {
        case let .worktree(branch):
            if let branch, !branch.isEmpty {
                throw GitRepoTargetResolverError.invalidParams("repo_root selector '@wt:\(branch)' is not supported. Use '@main:\(branch)' to target a worktree by branch or omit the branch.")
            }
            return repo
        case let .main(branch):
            if let branch, !branch.isEmpty {
                if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repo.rootURL),
                   let resolution = resolveWorktreeRoot(forBranch: branch, layout: layout),
                   let expected = expectedWorktreeDescriptor(for: resolution, basedOn: repo)
                {
                    return try await resolveAuthorizedWorktreeRepository(
                        expected,
                        advertisingRepos: [repo],
                        authorizedRoots: authorizedRoots
                    )
                }
                if let worktree = try await resolveWorktreeSelector(branch, in: [repo], selectorKind: .branch) {
                    return try await resolveAuthorizedWorktreeRepository(
                        worktree,
                        advertisingRepos: [repo],
                        authorizedRoots: authorizedRoots
                    )
                }
                throw GitRepoTargetResolverError.invalidParams("No worktree found for branch '\(branch)'. Use repo_root=\"@main\" for the main checkout or pass a full worktree path.")
            }
            if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repo.rootURL) {
                if !layout.isLinkedWorktree {
                    guard let expected = expectedWorktreeDescriptor(
                        for: ResolvedWorktreeRoot(root: repo.rootURL, gitDir: nil, isMain: true),
                        basedOn: repo
                    ) else {
                        throw GitRepoTargetResolverError.invalidParams(
                            "The main checkout identity could not be established for repo: \(repo.rootPath)"
                        )
                    }
                    return try await resolveAuthorizedWorktreeRepository(
                        expected,
                        advertisingRepos: [repo],
                        authorizedRoots: authorizedRoots
                    )
                }
                if let mainRoot = Self.resolveMainWorktreeRoot(for: layout),
                   let expected = expectedWorktreeDescriptor(
                       for: ResolvedWorktreeRoot(root: mainRoot, gitDir: nil, isMain: true),
                       basedOn: repo
                   )
                {
                    return try await resolveAuthorizedWorktreeRepository(
                        expected,
                        advertisingRepos: [repo],
                        authorizedRoots: authorizedRoots
                    )
                }
                if let main = try await mainWorktree(for: repo) {
                    return try await resolveAuthorizedWorktreeRepository(
                        main,
                        advertisingRepos: [repo],
                        authorizedRoots: authorizedRoots
                    )
                }
                throw GitRepoTargetResolverError.invalidParams("The main checkout path could not be resolved for repo: \(repo.rootPath)")
            }
            if let main = try await mainWorktree(for: repo) {
                return try await resolveAuthorizedWorktreeRepository(
                    main,
                    advertisingRepos: [repo],
                    authorizedRoots: authorizedRoots
                )
            }
            guard let expected = expectedWorktreeDescriptor(
                for: ResolvedWorktreeRoot(root: repo.rootURL, gitDir: nil, isMain: true),
                basedOn: repo
            ) else {
                throw GitRepoTargetResolverError.invalidParams(
                    "The main checkout identity could not be established for repo: \(repo.rootPath)"
                )
            }
            return try await resolveAuthorizedWorktreeRepository(
                expected,
                advertisingRepos: [repo],
                authorizedRoots: authorizedRoots
            )
        case .current:
            return repo
        case let .id(id):
            let candidates = hasExplicitBase ? [repo] : candidateRepos(allRepos: allRepos, defaultRepo: defaultRepo)
            if let worktree = try await resolveWorktreeSelector(id, in: candidates, selectorKind: .id) {
                return try await resolveAuthorizedWorktreeRepository(
                    worktree,
                    advertisingRepos: candidates,
                    authorizedRoots: authorizedRoots
                )
            }
            throw GitRepoTargetResolverError.invalidParams("No worktree found for id '\(id)'.")
        case let .branch(branch):
            let candidates = hasExplicitBase ? [repo] : candidateRepos(allRepos: allRepos, defaultRepo: defaultRepo)
            if let worktree = try await resolveWorktreeSelector(branch, in: candidates, selectorKind: .branch) {
                return try await resolveAuthorizedWorktreeRepository(
                    worktree,
                    advertisingRepos: candidates,
                    authorizedRoots: authorizedRoots
                )
            }
            throw GitRepoTargetResolverError.invalidParams("No worktree found for branch '\(branch)'.")
        }
    }

    // MARK: - Worktree selectors

    private enum WorktreeSelectorKind {
        case id
        case branch
        case path
        case branchNameOrPath
    }

    private func resolveWorktreeSelector(
        _ selector: String,
        in repos: [GitRepoDescriptor],
        selectorKind: WorktreeSelectorKind
    ) async throws -> GitWorktreeDescriptor? {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let worktrees = try await allWorktrees(for: repos)
        let matches = worktrees.filter { worktree in
            switch selectorKind {
            case .id:
                worktree.worktreeID == trimmed
            case .branch:
                matchesBranch(trimmed, branch: worktree.branch)
            case .path:
                samePath(worktree.path, trimmed)
            case .branchNameOrPath:
                matchesBranch(trimmed, branch: worktree.branch)
                    || matchesName(trimmed, worktree: worktree)
                    || samePath(worktree.path, trimmed)
            }
        }

        if matches.count <= 1 {
            return matches.first
        }

        let paths = matches.map(\.path).joined(separator: ", ")
        throw GitRepoTargetResolverError.invalidParams("Ambiguous worktree selector '\(trimmed)' matches multiple worktrees: \(paths). Use @id:<worktree_id> or an absolute path to disambiguate.")
    }

    private func mainWorktree(for repo: GitRepoDescriptor) async throws -> GitWorktreeDescriptor? {
        let worktrees = try await worktreesForRepository(containing: repo, candidateRepos: [repo])
        return worktrees.first(where: \.isMain)
    }

    private func worktreesForRepository(
        containing repo: GitRepoDescriptor,
        candidateRepos: [GitRepoDescriptor]
    ) async throws -> [GitWorktreeDescriptor] {
        let all = try await allWorktrees(for: candidateRepos)
        if let current = all.first(where: { samePath($0.path, repo.rootPath) }) {
            return all.filter { $0.repository.repositoryID == current.repository.repositoryID }
        }
        return try await dependencies.listWorktrees(repo)
    }

    private func allWorktrees(for repos: [GitRepoDescriptor]) async throws -> [GitWorktreeDescriptor] {
        var result: [GitWorktreeDescriptor] = []
        var seenWorktreeKeys = Set<String>()
        for repo in uniqueRepos(repos) {
            let worktrees = try await dependencies.listWorktrees(repo)
            for worktree in worktrees {
                let key = "\(worktree.repository.repositoryID)\u{0}\(worktree.worktreeID)"
                if seenWorktreeKeys.insert(key).inserted {
                    result.append(worktree)
                }
            }
        }
        return result
    }

    private func candidateRepos(allRepos: [GitRepoDescriptor], defaultRepo: GitRepoDescriptor) -> [GitRepoDescriptor] {
        uniqueRepos([defaultRepo] + allRepos)
    }

    private func uniqueRepos(_ repos: [GitRepoDescriptor]) -> [GitRepoDescriptor] {
        var result: [GitRepoDescriptor] = []
        var seen = Set<String>()
        for repo in repos {
            let key: String = if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repo.rootURL) {
                layout.commonDir.standardizedFileURL.path.lowercased()
            } else {
                repo.rootPath.lowercased()
            }
            if seen.insert(key).inserted {
                result.append(repo)
            }
        }
        return result
    }

    private func matchesName(_ selector: String, worktree: GitWorktreeDescriptor) -> Bool {
        let lower = selector.lowercased()
        if worktree.name?.lowercased() == lower {
            return true
        }
        return URL(fileURLWithPath: worktree.path).lastPathComponent.lowercased() == lower
    }

    private func matchesBranch(_ requested: String, branch: String?) -> Bool {
        guard let branch else { return false }
        return matchesBranch(requested, headRef: branch)
    }

    private struct ResolvedWorktreeRoot {
        let root: URL
        let gitDir: URL?
        let isMain: Bool
    }

    private func expectedWorktreeDescriptor(
        for resolution: ResolvedWorktreeRoot,
        basedOn repo: GitRepoDescriptor
    ) -> GitWorktreeDescriptor? {
        guard let repository = repo.worktreeIdentity?.repository,
              resolution.isMain || resolution.gitDir != nil
        else {
            return nil
        }
        let root = resolution.root.standardizedFileURL
        let worktreeID = GitWorktreeIdentity.worktreeID(
            repositoryID: repository.repositoryID,
            gitDir: resolution.isMain ? nil : resolution.gitDir,
            isMain: resolution.isMain,
            path: root
        )
        return GitWorktreeDescriptor(
            worktreeID: worktreeID,
            repository: repository,
            path: root.path,
            gitDir: resolution.gitDir?.standardizedFileURL.path,
            name: root.lastPathComponent.isEmpty ? nil : root.lastPathComponent,
            branch: nil,
            head: nil,
            isMain: resolution.isMain,
            isCurrent: samePath(root.path, repo.rootPath),
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
    }

    private func resolveAuthorizedWorktreeRepository(
        _ worktree: GitWorktreeDescriptor,
        advertisingRepos: [GitRepoDescriptor],
        authorizedRoots: [WorkspaceRootRef]
    ) async throws -> GitRepoDescriptor {
        let rootPaths = authorizedRoots.map(\.standardizedFullPath)
        let isInsideLoadedRoot = GitRepoRootAuthorization.isPathWithinAuthorizedRoots(
            worktree.path,
            roots: rootPaths
        )
        if isInsideLoadedRoot {
            return GitRepoDescriptor(rootURL: URL(fileURLWithPath: worktree.path))
        }

        // An external checkout must still be advertised by a loaded checkout of the same
        // repository before its fresh target identity can authorize the path.
        let mainRepositoryIsLoaded = worktree.repository.mainWorktreeRoot.map {
            GitRepoRootAuthorization.isPathWithinAuthorizedRoots($0, roots: rootPaths)
        } ?? false
        var matchingLinkedRepositoryIsLoaded = false
        if !mainRepositoryIsLoaded {
            for advertisingRepo in uniqueRepos(advertisingRepos) {
                let loadedRepositoryWorktrees = await (try? dependencies.listWorktrees(advertisingRepo)) ?? []
                if loadedRepositoryWorktrees.contains(where: { candidate in
                    GitRepoRootAuthorization.isPathWithinAuthorizedRoots(candidate.path, roots: rootPaths)
                        && candidate.repository.repositoryID == worktree.repository.repositoryID
                        && samePath(candidate.repository.commonGitDir, worktree.repository.commonGitDir)
                }) {
                    matchingLinkedRepositoryIsLoaded = true
                    break
                }
            }
        }
        let advertisingRepositoryIsLoaded = mainRepositoryIsLoaded || matchingLinkedRepositoryIsLoaded
        guard advertisingRepositoryIsLoaded,
              let resolved = await dependencies.resolveRepo(URL(fileURLWithPath: worktree.path)),
              matchesFreshWorktreeIdentity(resolved, worktree: worktree)
        else {
            let rootsList = rootPaths.joined(separator: ", ")
            throw GitRepoTargetResolverError.invalidParams(
                "worktree path must be inside a loaded root or advertised by a loaded repository. Received: \(worktree.path). Loaded roots: \(rootsList)"
            )
        }
        return resolved
    }

    private func matchesFreshWorktreeIdentity(
        _ resolved: GitRepoDescriptor,
        worktree: GitWorktreeDescriptor
    ) -> Bool {
        guard samePath(resolved.rootPath, worktree.path),
              let identity = resolved.worktreeIdentity
        else {
            return false
        }
        return samePath(identity.worktreeRootPath, worktree.path)
            && identity.repository.repositoryID == worktree.repository.repositoryID
            && samePath(identity.repository.commonGitDir, worktree.repository.commonGitDir)
            && identity.worktreeID == worktree.worktreeID
            && identity.isMain == worktree.isMain
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        GitRepoRootAuthorization.canonicalPath(lhs) == GitRepoRootAuthorization.canonicalPath(rhs)
    }

    // MARK: - Legacy worktree layout helpers

    static func resolveMainWorktreeRoot(for layout: GitRepositoryLayout) -> URL? {
        layout.knownMainWorktreeRoot
    }

    private func readHeadRef(from headURL: URL) -> String? {
        guard let raw = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref:") else {
            return nil
        }
        return trimmed.replacingOccurrences(of: "ref:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesBranch(_ requested: String, headRef: String) -> Bool {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if headRef == trimmed { return true }
        if headRef.hasPrefix("refs/heads/") {
            let short = String(headRef.dropFirst("refs/heads/".count))
            return short == trimmed
        }
        return false
    }

    private func resolveWorktreeRootFromEntry(_ entryURL: URL) -> URL? {
        let gitdirURL = entryURL.appendingPathComponent("gitdir")
        guard let raw = try? String(contentsOf: gitdirURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolvedGitdir: URL = if trimmed.hasPrefix("/") {
            URL(fileURLWithPath: trimmed)
        } else {
            entryURL.appendingPathComponent(trimmed)
        }
        return resolvedGitdir.deletingLastPathComponent().standardizedFileURL
    }

    private func resolveWorktreeRoot(forBranch branch: String, layout: GitRepositoryLayout) -> ResolvedWorktreeRoot? {
        let target = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let fileManager = FileManager.default
        let worktreesDir = layout.commonDir.appendingPathComponent("worktrees", isDirectory: true)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: worktreesDir.path, isDirectory: &isDir), isDir.boolValue {
            if let entries = try? fileManager.contentsOfDirectory(at: worktreesDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                for entry in entries {
                    var isEntryDir: ObjCBool = false
                    guard fileManager.fileExists(atPath: entry.path, isDirectory: &isEntryDir), isEntryDir.boolValue else { continue }
                    let headURL = entry.appendingPathComponent("HEAD")
                    guard let headRef = readHeadRef(from: headURL), matchesBranch(target, headRef: headRef) else {
                        continue
                    }
                    if let root = resolveWorktreeRootFromEntry(entry) {
                        return ResolvedWorktreeRoot(
                            root: root,
                            gitDir: entry.standardizedFileURL,
                            isMain: false
                        )
                    }
                }
            }
        }
        if let mainRoot = Self.resolveMainWorktreeRoot(for: layout) {
            let headURL = layout.commonDir.appendingPathComponent("HEAD")
            if let headRef = readHeadRef(from: headURL), matchesBranch(target, headRef: headRef) {
                return ResolvedWorktreeRoot(root: mainRoot, gitDir: nil, isMain: true)
            }
        }
        return nil
    }
}

struct GitRepoTargetResolverError: LocalizedError, Equatable {
    let message: String

    static func invalidParams(_ message: String) -> GitRepoTargetResolverError {
        GitRepoTargetResolverError(message: message)
    }

    var errorDescription: String? {
        message
    }
}
