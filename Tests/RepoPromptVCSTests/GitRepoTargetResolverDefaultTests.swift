import Foundation
import RepoPromptVCS
import XCTest

/// Issue #1431: selectors that identify a repository or worktree resolve without a supplied default
/// repository. Only requests relative to a default ask the caller to elect one, and the resolver never
/// substitutes a discovered candidate (such as the first loaded root) for that election.
final class GitRepoTargetResolverDefaultTests: XCTestCase {
    // MARK: - Relative requests ask the caller for an elected default

    func testRelativeRepoRootTokensSignalDefaultRequiredInsteadOfUsingFirstCandidate() async {
        let fixture = Fixture()
        // Beta is discovered first, so a load-order fallback would silently answer with beta.
        let betaDiscoveredFirst = [fixture.beta, fixture.alpha, fixture.gammaLoaded]
        let relativeTokens = [
            "", "   ", "@main", "@primary", "@current", "@wt", "@worktree", "@main:only-beta", "@primary:only-beta"
        ]

        for token in relativeTokens {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveRepoRootToken(
                    token,
                    allRepos: betaDiscoveredFirst,
                    visibleRoots: fixture.visibleRoots,
                    defaultRepo: nil
                ).rootPath
            }
            XCTAssertEqual(outcome, .defaultRequired, "repo_root=\(token.debugDescription)")
        }
    }

    func testRepoRootListsSignalDefaultRequiredOnlyAfterIdentifyingTokensResolve() async {
        let fixture = Fixture()
        let cases: [(tokens: [String]?, defaultRepo: GitRepoDescriptor?, expected: Outcome)] = [
            (nil, nil, .defaultRequired),
            ([], nil, .defaultRequired),
            (["beta", "@main"], nil, .defaultRequired),
            (["@current", "beta"], nil, .defaultRequired),
            // A final selector error outranks the request for a default.
            (["@main", "no-such-root"], nil, .failed(Fixture.noRepoMessage("no-such-root"))),
            // Identifying-only lists keep their order and path de-duplication without a default.
            (
                ["beta", "@id:wt-alpha-only", Fixture.betaPath],
                nil,
                .resolved([Fixture.betaPath, Fixture.alphaOnlyPath].joined(separator: "|"))
            ),
            // The caller's retry pass resolves the relative token against the elected default.
            (["beta", "@main"], fixture.alpha, .resolved([Fixture.betaPath, Fixture.alphaPath].joined(separator: "|")))
        ]

        for testCase in cases {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveRepoRoots(
                    explicitRootTokens: testCase.tokens,
                    allRepos: fixture.allRepos,
                    visibleRoots: fixture.visibleRoots,
                    defaultRepo: testCase.defaultRepo
                ).map(\.rootPath).joined(separator: "|")
            }
            XCTAssertEqual(
                outcome,
                testCase.expected,
                "repo_root=\(String(describing: testCase.tokens)) default=\(testCase.defaultRepo?.rootPath ?? "nil")"
            )
        }
    }

    func testRelativeWorktreeSelectorsSignalDefaultRequired() async {
        let fixture = Fixture()
        let relativeSelectors: [String?] = [
            nil, "@current", "@main", "@primary", "@main:only-beta", "@primary:only-beta", "@wt", "@worktree"
        ]

        for selector in relativeSelectors {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveWorktree(
                    selector: selector,
                    repo: nil,
                    allRepos: fixture.allRepos,
                    authorizedRoots: fixture.visibleRoots
                ).worktreeID
            }
            XCTAssertEqual(outcome, .defaultRequired, "worktree=\(selector ?? "<omitted>")")
        }
    }

    // MARK: - Identifying selectors need no default

    func testIdentifyingSelectorsResolveWithoutAnyDefaultCandidate() async {
        let fixture = Fixture()
        // No discovered repository exists to stand in for a default.
        let repoRootCases: [(token: String, expected: Outcome)] = [
            ("beta", .resolved(Fixture.betaPath)),
            (Fixture.betaPath, .resolved(Fixture.betaPath)),
            ("beta@main", .resolved(Fixture.betaPath)),
            ("beta@branch:only-beta", .resolved(Fixture.betaOnlyPath)),
            ("@id:wt-beta-only", .failed("No worktree found for id 'wt-beta-only'.")),
            (
                "@wt:feature",
                .failed(
                    "repo_root selector '@wt:feature' is not supported. Use '@main:feature' to target a worktree by branch or omit the branch."
                )
            )
        ]
        for testCase in repoRootCases {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveRepoRootToken(
                    testCase.token,
                    allRepos: [],
                    visibleRoots: fixture.visibleRoots,
                    defaultRepo: nil
                ).rootPath
            }
            XCTAssertEqual(outcome, testCase.expected, "repo_root=\(testCase.token)")
        }

        let worktreeCases: [(selector: String, expected: Outcome)] = [
            ("@id:wt-beta-only", .failed("No worktree found for id 'wt-beta-only'.")),
            ("beta-only", .failed("No worktree found matching 'beta-only'.")),
            (
                "@wt:feature",
                .failed(
                    "worktree selector '@wt:feature' is not supported. Use '@branch:feature' to target a worktree by branch or omit the branch."
                )
            )
        ]
        for testCase in worktreeCases {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveWorktree(
                    selector: testCase.selector,
                    repo: nil,
                    allRepos: [],
                    authorizedRoots: fixture.visibleRoots
                ).worktreeID
            }
            XCTAssertEqual(outcome, testCase.expected, "worktree=\(testCase.selector)")
        }
    }

    func testWorktreeSelectorWithoutRepositoryAuthorizesThroughAdvertisingCandidate() async {
        let fixture = Fixture()
        // Gamma's external checkout is advertised only by gamma's loaded linked checkout, not by the
        // first discovered repository (alpha).
        let selectors = ["@id:wt-gamma-target", "@branch:gamma-target", "gamma-target", Fixture.gammaTargetPath]

        for selector in selectors {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveWorktree(
                    selector: selector,
                    repo: nil,
                    allRepos: fixture.allRepos,
                    authorizedRoots: fixture.visibleRoots
                ).worktreeID
            }
            XCTAssertEqual(outcome, .resolved("wt-gamma-target"), "worktree=\(selector)")
        }
    }

    func testUniqueIdentifyingSelectorsResolveWithoutDefault() async {
        let fixture = Fixture()
        let repoRootCases: [(token: String, expectedPath: String)] = [
            ("beta", Fixture.betaPath),
            (Fixture.betaPath, Fixture.betaPath),
            ("@id:wt-beta-only", Fixture.betaOnlyPath),
            ("@branch:only-beta", Fixture.betaOnlyPath),
            ("only-beta", Fixture.betaOnlyPath),
            ("beta-only", Fixture.betaOnlyPath),
            (Fixture.betaOnlyPath, Fixture.betaOnlyPath),
            ("beta@main", Fixture.betaPath),
            ("beta@main:only-beta", Fixture.betaOnlyPath),
            // An explicit repository scopes an otherwise ambiguous branch.
            ("beta@branch:shared", Fixture.betaSharedPath),
            ("alpha@id:wt-alpha-only", Fixture.alphaOnlyPath)
        ]
        for testCase in repoRootCases {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveRepoRootToken(
                    testCase.token,
                    allRepos: fixture.allRepos,
                    visibleRoots: fixture.visibleRoots,
                    defaultRepo: nil
                ).rootPath
            }
            XCTAssertEqual(outcome, .resolved(testCase.expectedPath), "repo_root=\(testCase.token)")
        }

        let worktreeSelectors = ["@id:wt-beta-only", "@branch:only-beta", "only-beta", "beta-only", Fixture.betaOnlyPath]
        for selector in worktreeSelectors {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveWorktree(
                    selector: selector,
                    repo: nil,
                    allRepos: fixture.allRepos,
                    authorizedRoots: fixture.visibleRoots
                ).worktreeID
            }
            XCTAssertEqual(outcome, .resolved("wt-beta-only"), "worktree=\(selector)")
        }
    }

    func testAmbiguousIdentifyingSelectorsStayAmbiguousWithoutDefault() async {
        let fixture = Fixture()
        let sameDisplayName = ["dup-one", "dup-two"].map { name in
            let path = Fixture.base + "/" + name
            return GitRepoDescriptor(
                rootURL: URL(fileURLWithPath: path),
                rootPath: path,
                repoKey: "key-\(name)",
                displayName: "dup"
            )
        }
        let allRepos = fixture.allRepos + sameDisplayName

        let repoRootCases: [(token: String, expectedPrefix: String)] = [
            ("@branch:shared", "Ambiguous worktree selector 'shared'"),
            ("shared", "Ambiguous worktree selector 'shared'"),
            ("@branch:main", "Ambiguous worktree selector 'main'"),
            ("main", "Ambiguous worktree selector 'main'"),
            ("twin", "Ambiguous worktree selector 'twin'"),
            ("@id:wt-dup", "Ambiguous worktree selector 'wt-dup'"),
            ("dup", "Ambiguous repo name 'dup'")
        ]
        for testCase in repoRootCases {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveRepoRootToken(
                    testCase.token,
                    allRepos: allRepos,
                    visibleRoots: fixture.visibleRoots,
                    defaultRepo: nil
                ).rootPath
            }
            assertFailure(outcome, hasPrefix: testCase.expectedPrefix, "repo_root=\(testCase.token)")
        }

        let worktreeCases: [(selector: String, expectedPrefix: String)] = [
            ("@branch:shared", "Ambiguous worktree selector 'shared'"),
            ("shared", "Ambiguous worktree selector 'shared'"),
            ("main", "Ambiguous worktree selector 'main'"),
            ("twin", "Ambiguous worktree selector 'twin'"),
            ("@id:wt-dup", "Ambiguous worktree selector 'wt-dup'")
        ]
        for testCase in worktreeCases {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveWorktree(
                    selector: testCase.selector,
                    repo: nil,
                    allRepos: allRepos,
                    authorizedRoots: fixture.visibleRoots
                ).worktreeID
            }
            assertFailure(outcome, hasPrefix: testCase.expectedPrefix, "worktree=\(testCase.selector)")
        }
    }

    func testDuplicateVisibleRootNamesKeepFirstVisibleMatchWithoutDefault() async {
        let notARepository = VCSRepositoryRoot(name: "app", fullPath: Fixture.base + "/zero/app")
        let first = Fixture.checkout(for: Fixture.worktree(
            "wt-one",
            in: Fixture.repository("repo-one", mainWorktreeRoot: Fixture.base + "/one/app"),
            path: Fixture.base + "/one/app",
            branch: "main",
            isMain: true
        ))
        let second = Fixture.checkout(for: Fixture.worktree(
            "wt-two",
            in: Fixture.repository("repo-two", mainWorktreeRoot: Fixture.base + "/two/app"),
            path: Fixture.base + "/two/app",
            branch: "main",
            isMain: true
        ))
        let checkouts = [first, second]
        let resolver = GitRepoTargetResolver(dependencies: .init(
            resolveRepo: { url in checkouts.first { $0.rootPath == url.standardizedFileURL.path } },
            listWorktrees: { _ in [] }
        ))
        let visibleRoots = [notARepository, Fixture.root(for: first), Fixture.root(for: second)]

        for token in ["app", "APP"] {
            let outcome = await Outcome.of {
                // Discovery order is reversed: visible-root order alone decides the first match.
                try await resolver.resolveRepoRootToken(
                    token,
                    allRepos: [second, first],
                    visibleRoots: visibleRoots,
                    defaultRepo: nil
                ).rootPath
            }
            XCTAssertEqual(outcome, .resolved(first.rootPath), "repo_root=\(token)")
        }
    }

    func testExternalLinkedWorktreeNeedsAdvertisementAndFreshIdentityWithoutDefault() async {
        let tokens = ["@id:wt-gamma-target", "@branch:gamma-target", "gamma-target", Fixture.gammaTargetPath]

        let advertised = Fixture()
        for token in tokens {
            let outcome = await Outcome.of {
                let repo = try await advertised.resolver.resolveRepoRootToken(
                    token,
                    allRepos: advertised.allRepos,
                    visibleRoots: advertised.visibleRoots,
                    defaultRepo: nil
                )
                return "\(repo.rootPath)#\(repo.worktreeIdentity?.worktreeID ?? "no-identity")"
            }
            XCTAssertEqual(outcome, .resolved("\(Fixture.gammaTargetPath)#wt-gamma-target"), "advertised repo_root=\(token)")
        }

        let replacementRepository = Fixture.repository("repo-replacement", mainWorktreeRoot: Fixture.base + "/elsewhere")
        let replacement = Fixture.checkout(for: Fixture.worktree(
            "wt-replacement",
            in: replacementRepository,
            path: Fixture.gammaTargetPath,
            branch: "gamma-target"
        ))
        let replaced = Fixture(freshOverrides: [Fixture.gammaTargetPath: replacement])
        let rejected = "worktree path must be inside a loaded root or advertised by a loaded repository"
        for token in tokens {
            let repoRootOutcome = await Outcome.of {
                try await replaced.resolver.resolveRepoRootToken(
                    token,
                    allRepos: replaced.allRepos,
                    visibleRoots: replaced.visibleRoots,
                    defaultRepo: nil
                ).rootPath
            }
            assertFailure(repoRootOutcome, hasPrefix: rejected, "replaced repo_root=\(token)")

            let worktreeOutcome = await Outcome.of {
                try await replaced.resolver.resolveWorktree(
                    selector: token,
                    repo: nil,
                    allRepos: replaced.allRepos,
                    authorizedRoots: replaced.visibleRoots
                ).worktreeID
            }
            assertFailure(worktreeOutcome, hasPrefix: rejected, "replaced worktree=\(token)")
        }

        // Without a loaded checkout of gamma, nothing advertises its external worktree.
        let unloadedRepos = [advertised.alpha, advertised.beta]
        let unloadedRoots = unloadedRepos.map(Fixture.root(for:))
        let unadvertisedRepoRootCases: [(token: String, expectedPrefix: String)] = [
            ("@id:wt-gamma-target", "No worktree found for id 'wt-gamma-target'."),
            ("@branch:gamma-target", "No worktree found for branch 'gamma-target'."),
            ("gamma-target", "No repo found matching 'gamma-target'."),
            (Fixture.gammaTargetPath, "repo_root path must be inside a loaded root.")
        ]
        for testCase in unadvertisedRepoRootCases {
            let outcome = await Outcome.of {
                try await advertised.resolver.resolveRepoRootToken(
                    testCase.token,
                    allRepos: unloadedRepos,
                    visibleRoots: unloadedRoots,
                    defaultRepo: nil
                ).rootPath
            }
            assertFailure(outcome, hasPrefix: testCase.expectedPrefix, "unadvertised repo_root=\(testCase.token)")
        }
        let unadvertisedWorktreeCases: [(selector: String, expectedPrefix: String)] = [
            ("@id:wt-gamma-target", "No worktree found for id 'wt-gamma-target'."),
            (Fixture.gammaTargetPath, "No worktree found matching '\(Fixture.gammaTargetPath)'.")
        ]
        for testCase in unadvertisedWorktreeCases {
            let outcome = await Outcome.of {
                try await advertised.resolver.resolveWorktree(
                    selector: testCase.selector,
                    repo: nil,
                    allRepos: unloadedRepos,
                    authorizedRoots: unloadedRoots
                ).worktreeID
            }
            assertFailure(outcome, hasPrefix: testCase.expectedPrefix, "unadvertised worktree=\(testCase.selector)")
        }
    }

    func testPrunableWorktreeIsRejectedWithoutDefault() async {
        let fixture = Fixture()
        let selectors = ["@id:wt-beta-stale", "@branch:stale", "stale", Fixture.betaStalePath]

        for selector in selectors {
            let outcome = await Outcome.of {
                try await fixture.resolver.resolveWorktree(
                    selector: selector,
                    repo: nil,
                    allRepos: fixture.allRepos,
                    authorizedRoots: fixture.visibleRoots
                ).worktreeID
            }
            assertFailure(outcome, hasPrefix: "Worktree '\(Fixture.betaStalePath)' is stale", "worktree=\(selector)")
        }
    }

    // MARK: - Compatibility entry points

    func testCompatibilityEntryPointsMatchOptionalOverloadsWithSuppliedDefault() async {
        let fixture = Fixture()
        let tokens = [
            "", "@main", "@current", "@wt", "@main:only-beta", "@wt:feature", "@id:wt-beta-only", "@branch:shared",
            "only-beta", "beta", "alpha@main", "gamma-target", "no-such-root"
        ]
        let tokenLists: [[String]?] = [nil, [], ["beta", "@main"], ["@main", "no-such-root"]]
        let selectors: [String?] = [
            nil, "@current", "@main", "@main:only-beta", "@wt", "@wt:feature", "@id:wt-beta-only",
            "@id:wt-gamma-target", "shared", "beta-only"
        ]

        for elected in [fixture.alpha, fixture.beta] {
            let supplied: GitRepoDescriptor? = elected
            for token in tokens {
                let compatibility = await Outcome.of {
                    try await fixture.resolver.resolveRepoRootToken(
                        token,
                        allRepos: fixture.allRepos,
                        visibleRoots: fixture.visibleRoots,
                        defaultRepo: elected
                    ).rootPath
                }
                let optional = await Outcome.of {
                    try await fixture.resolver.resolveRepoRootToken(
                        token,
                        allRepos: fixture.allRepos,
                        visibleRoots: fixture.visibleRoots,
                        defaultRepo: supplied
                    ).rootPath
                }
                XCTAssertNotEqual(compatibility, .defaultRequired, "repo_root=\(token) default=\(elected.rootPath)")
                XCTAssertEqual(optional, compatibility, "repo_root=\(token) default=\(elected.rootPath)")
            }

            for tokenList in tokenLists {
                let compatibility = await Outcome.of {
                    try await fixture.resolver.resolveRepoRoots(
                        explicitRootTokens: tokenList,
                        allRepos: fixture.allRepos,
                        visibleRoots: fixture.visibleRoots,
                        defaultRepo: elected
                    ).map(\.rootPath).joined(separator: "|")
                }
                let optional = await Outcome.of {
                    try await fixture.resolver.resolveRepoRoots(
                        explicitRootTokens: tokenList,
                        allRepos: fixture.allRepos,
                        visibleRoots: fixture.visibleRoots,
                        defaultRepo: supplied
                    ).map(\.rootPath).joined(separator: "|")
                }
                let label = "repo_root=\(String(describing: tokenList)) default=\(elected.rootPath)"
                XCTAssertNotEqual(compatibility, .defaultRequired, label)
                XCTAssertEqual(optional, compatibility, label)
            }

            for selector in selectors {
                let compatibility = await Outcome.of {
                    try await fixture.resolver.resolveWorktree(
                        selector: selector,
                        repo: elected,
                        allRepos: fixture.allRepos,
                        authorizedRoots: fixture.visibleRoots
                    ).worktreeID
                }
                let optional = await Outcome.of {
                    try await fixture.resolver.resolveWorktree(
                        selector: selector,
                        repo: supplied,
                        allRepos: fixture.allRepos,
                        authorizedRoots: fixture.visibleRoots
                    ).worktreeID
                }
                let label = "worktree=\(selector ?? "<omitted>") repo=\(elected.rootPath)"
                XCTAssertNotEqual(compatibility, .defaultRequired, label)
                XCTAssertEqual(optional, compatibility, label)
            }
        }

        // The compatibility entry points answer with the caller's default, not discovery order, and a
        // `@main:<branch>` request stays relative to that repository.
        let omitted = await Outcome.of {
            try await fixture.resolver.resolveRepoRoots(
                explicitRootTokens: nil,
                allRepos: fixture.allRepos,
                visibleRoots: fixture.visibleRoots,
                defaultRepo: fixture.beta
            ).map(\.rootPath).joined(separator: "|")
        }
        XCTAssertEqual(omitted, .resolved(Fixture.betaPath))
        let branchInBeta = await Outcome.of {
            try await fixture.resolver.resolveRepoRootToken(
                "@main:only-beta",
                allRepos: fixture.allRepos,
                visibleRoots: fixture.visibleRoots,
                defaultRepo: fixture.beta
            ).rootPath
        }
        XCTAssertEqual(branchInBeta, .resolved(Fixture.betaOnlyPath))
        let branchInAlpha = await Outcome.of {
            try await fixture.resolver.resolveRepoRootToken(
                "@main:only-beta",
                allRepos: fixture.allRepos,
                visibleRoots: fixture.visibleRoots,
                defaultRepo: fixture.alpha
            ).rootPath
        }
        assertFailure(branchInAlpha, hasPrefix: "No worktree found for branch 'only-beta'.", "@main:only-beta in alpha")
        let currentInBeta = await Outcome.of {
            try await fixture.resolver.resolveWorktree(
                selector: nil,
                repo: fixture.beta,
                allRepos: fixture.allRepos,
                authorizedRoots: fixture.visibleRoots
            ).worktreeID
        }
        XCTAssertEqual(currentInBeta, .resolved("wt-beta-main"))
    }

    // MARK: - Helpers

    private func assertFailure(
        _ outcome: Outcome,
        hasPrefix prefix: String,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failed(message) = outcome, message.hasPrefix(prefix) else {
            XCTFail("\(context): expected a failure starting with \(prefix.debugDescription), got \(outcome)", file: file, line: line)
            return
        }
    }
}

private enum Outcome: Equatable {
    case resolved(String)
    case defaultRequired
    case failed(String)
    case unexpected(String)

    static func of(_ operation: () async throws -> String) async -> Outcome {
        do {
            return try await .resolved(operation())
        } catch is GitRepoTargetResolver.DefaultRepositoryRequired {
            return .defaultRequired
        } catch let error as GitRepoTargetResolverError {
            return .failed(error.message)
        } catch {
            return .unexpected(String(describing: error))
        }
    }
}

/// Three repositories behind fake, nonexistent paths so no real Git layout is ever read.
///
/// - alpha and beta: main checkouts loaded as roots, each with linked worktrees inside the root.
/// - gamma: a linked checkout loaded as a root; its main checkout and `gamma-target` are external.
/// - `shared` and `main` branches, the `twin` name, and the `wt-dup` ID each match more than one worktree.
private struct Fixture {
    static let base = "/rp-issue-1431-resolver-fixture"
    static let alphaPath = base + "/alpha"
    static let alphaOnlyPath = alphaPath + "/.worktrees/alpha-only"
    static let betaPath = base + "/beta"
    static let betaOnlyPath = betaPath + "/.worktrees/beta-only"
    static let betaSharedPath = betaPath + "/.worktrees/beta-shared"
    static let betaStalePath = betaPath + "/.worktrees/stale"
    static let gammaPath = base + "/gamma"
    static let gammaMainPath = base + "/external/gamma-main"
    static let gammaTargetPath = base + "/external/gamma-target"

    let resolver: GitRepoTargetResolver
    let alpha: GitRepoDescriptor
    let beta: GitRepoDescriptor
    let gammaLoaded: GitRepoDescriptor

    var allRepos: [GitRepoDescriptor] {
        [alpha, beta, gammaLoaded]
    }

    var visibleRoots: [VCSRepositoryRoot] {
        allRepos.map(Self.root(for:))
    }

    init(freshOverrides: [String: GitRepoDescriptor] = [:]) {
        let repoA = Self.repository("repo-a", mainWorktreeRoot: Self.alphaPath)
        let repoB = Self.repository("repo-b", mainWorktreeRoot: Self.betaPath)
        let repoC = Self.repository("repo-c", mainWorktreeRoot: Self.gammaMainPath)
        let worktrees = [
            Self.worktree("wt-alpha-main", in: repoA, path: Self.alphaPath, branch: "main", isMain: true),
            Self.worktree("wt-alpha-only", in: repoA, path: Self.alphaOnlyPath, branch: "only-alpha"),
            Self.worktree("wt-alpha-shared", in: repoA, path: Self.alphaPath + "/.worktrees/alpha-shared", branch: "shared"),
            Self.worktree("wt-dup", in: repoA, path: Self.alphaPath + "/.worktrees/twin", branch: "twin-a"),
            Self.worktree("wt-beta-main", in: repoB, path: Self.betaPath, branch: "main", isMain: true),
            Self.worktree("wt-beta-only", in: repoB, path: Self.betaOnlyPath, branch: "only-beta"),
            Self.worktree("wt-beta-shared", in: repoB, path: Self.betaSharedPath, branch: "shared"),
            Self.worktree("wt-dup", in: repoB, path: Self.betaPath + "/.worktrees/twin", branch: "twin-b"),
            Self.worktree(
                "wt-beta-stale",
                in: repoB,
                path: Self.betaStalePath,
                branch: "stale",
                prunableReason: "gitdir file points to non-existent location"
            ),
            Self.worktree("wt-gamma-main", in: repoC, path: Self.gammaMainPath, branch: "main", isMain: true),
            Self.worktree("wt-gamma-loaded", in: repoC, path: Self.gammaPath, branch: "gamma-loaded"),
            Self.worktree("wt-gamma-target", in: repoC, path: Self.gammaTargetPath, branch: "gamma-target")
        ]
        var checkouts = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.path, Self.checkout(for: $0)) })
        let loaded = (
            alpha: checkouts[Self.alphaPath],
            beta: checkouts[Self.betaPath],
            gamma: checkouts[Self.gammaPath]
        )
        guard let alpha = loaded.alpha, let beta = loaded.beta, let gamma = loaded.gamma else {
            preconditionFailure("fixture checkouts must include every loaded root")
        }
        checkouts.merge(freshOverrides) { _, override in override }
        let freshCheckouts = checkouts

        self.alpha = alpha
        self.beta = beta
        gammaLoaded = gamma
        resolver = GitRepoTargetResolver(dependencies: .init(
            resolveRepo: { url in freshCheckouts[url.standardizedFileURL.path] },
            listWorktrees: { repo in
                // Like `git worktree list`, any checkout of a repository lists all of its worktrees.
                guard let listed = worktrees.first(where: { $0.path == repo.rootPath }) else { return [] }
                return worktrees.filter { $0.repository.repositoryID == listed.repository.repositoryID }
            }
        ))
    }

    static func noRepoMessage(_ token: String) -> String {
        "No repo found matching '\(token)'. Available root names: alpha, beta, gamma"
    }

    static func root(for checkout: GitRepoDescriptor) -> VCSRepositoryRoot {
        VCSRepositoryRoot(name: URL(fileURLWithPath: checkout.rootPath).lastPathComponent, fullPath: checkout.rootPath)
    }

    static func repository(_ repositoryID: String, mainWorktreeRoot: String) -> GitWorktreeRepositoryIdentity {
        GitWorktreeRepositoryIdentity(
            repositoryID: repositoryID,
            repoKey: "key-\(repositoryID)",
            displayName: URL(fileURLWithPath: mainWorktreeRoot).lastPathComponent,
            commonGitDir: mainWorktreeRoot + "/.git",
            mainWorktreeRoot: mainWorktreeRoot
        )
    }

    static func worktree(
        _ worktreeID: String,
        in repository: GitWorktreeRepositoryIdentity,
        path: String,
        branch: String,
        isMain: Bool = false,
        prunableReason: String? = nil
    ) -> GitWorktreeDescriptor {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return GitWorktreeDescriptor(
            worktreeID: worktreeID,
            repository: repository,
            path: path,
            gitDir: isMain ? nil : repository.commonGitDir + "/worktrees/" + name,
            name: name,
            branch: branch,
            head: "abc123",
            isMain: isMain,
            isCurrent: false,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: prunableReason != nil,
            prunableReason: prunableReason
        )
    }

    /// The fresh descriptor `resolveRepo` reports for a checkout path.
    static func checkout(for worktree: GitWorktreeDescriptor) -> GitRepoDescriptor {
        GitRepoDescriptor(
            rootURL: URL(fileURLWithPath: worktree.path),
            rootPath: worktree.path,
            repoKey: "key-\(worktree.worktreeID)",
            displayName: URL(fileURLWithPath: worktree.path).lastPathComponent,
            worktreeIdentity: GitWorktreeIdentitySnapshot(
                repository: worktree.repository,
                worktreeID: worktree.worktreeID,
                worktreeRootPath: worktree.path,
                isMain: worktree.isMain
            )
        )
    }
}
