import Darwin
import Foundation
import MCP
@testable import RepoPrompt
import XCTest

private final class AgentRunWorktreeStartGitSeedRepository: @unchecked Sendable {
    private struct FileIdentity {
        let device: UInt64
        let inode: UInt64
        let linkCount: UInt64
    }

    private static let trackedContents = "original\n"

    private let containerURL: URL
    private let repositoryURL: URL
    private let expectedHead: String

    static func create(in containerURL: URL) throws -> AgentRunWorktreeStartGitSeedRepository {
        let repositoryURL = containerURL.appendingPathComponent("repo", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        _ = try GitWorktreeTestSupport.runGit(["init"], cwd: repositoryURL)
        _ = try GitWorktreeTestSupport.runGit(["config", "user.name", "RepoPrompt Test"], cwd: repositoryURL)
        _ = try GitWorktreeTestSupport.runGit(
            ["config", "user.email", "repoprompt@example.test"],
            cwd: repositoryURL
        )
        _ = try GitWorktreeTestSupport.runGit(["config", "commit.gpgSign", "false"], cwd: repositoryURL)
        _ = try GitWorktreeTestSupport.runGit(["checkout", "-b", "main"], cwd: repositoryURL)
        try trackedContents.write(
            to: repositoryURL.appendingPathComponent("Tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try GitWorktreeTestSupport.runGit(["add", "Tracked.txt"], cwd: repositoryURL)
        _ = try GitWorktreeTestSupport.runGit(["commit", "-m", "Initial commit"], cwd: repositoryURL)
        let expectedHead = try GitWorktreeTestSupport.runGit(["rev-parse", "HEAD"], cwd: repositoryURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = AgentRunWorktreeStartGitSeedRepository(
            containerURL: containerURL,
            repositoryURL: repositoryURL,
            expectedHead: expectedHead
        )
        let failures = seed.immutabilityFailures()
        guard failures.isEmpty else {
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]
            )
        }
        return seed
    }

    func copyRepository(to destinationURL: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Git seed copy destination already exists: \(destinationURL.path)"]
            )
        }

        try fileManager.copyItem(at: repositoryURL, to: destinationURL)
        try validateRepositoryLayout(at: destinationURL)

        let seedFiles = try regularFileIdentities(in: repositoryURL)
        let copiedFiles = try regularFileIdentities(in: destinationURL)
        guard Set(seedFiles.keys) == Set(copiedFiles.keys) else {
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Git seed copy did not preserve the exact regular-file set"]
            )
        }
        for relativePath in seedFiles.keys.sorted() {
            guard let seedIdentity = seedFiles[relativePath], let copyIdentity = copiedFiles[relativePath] else {
                continue
            }
            guard seedIdentity.linkCount == 1, copyIdentity.linkCount == 1 else {
                throw NSError(
                    domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Hardlinked regular file detected at \(relativePath)"]
                )
            }
            guard seedIdentity.device != copyIdentity.device || seedIdentity.inode != copyIdentity.inode else {
                throw NSError(
                    domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Git seed and scenario copy share an inode at \(relativePath)"]
                )
            }
        }
    }

    func tearDown() -> [String] {
        var failures = immutabilityFailures()
        if FileManager.default.fileExists(atPath: containerURL.path) {
            do {
                try FileManager.default.removeItem(at: containerURL)
            } catch {
                failures.append("remove immutable Git seed container \(containerURL.path): \(error.localizedDescription)")
            }
        }
        if FileManager.default.fileExists(atPath: containerURL.path) {
            failures.append("immutable Git seed container leaked: \(containerURL.path)")
        }
        return failures
    }

    private init(containerURL: URL, repositoryURL: URL, expectedHead: String) {
        self.containerURL = containerURL
        self.repositoryURL = repositoryURL
        self.expectedHead = expectedHead
    }

    private func immutabilityFailures() -> [String] {
        var failures: [String] = []
        guard FileManager.default.fileExists(atPath: repositoryURL.path) else {
            return ["immutable Git seed repository is missing: \(repositoryURL.path)"]
        }

        do {
            let head = try GitWorktreeTestSupport.runGit(["rev-parse", "HEAD"], cwd: repositoryURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if head != expectedHead {
                failures.append("immutable Git seed HEAD changed from \(expectedHead) to \(head)")
            }
        } catch {
            failures.append("read immutable Git seed HEAD: \(error.localizedDescription)")
        }
        do {
            let branch = try GitWorktreeTestSupport.runGit(["branch", "--show-current"], cwd: repositoryURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if branch != "main" {
                failures.append("immutable Git seed branch changed from main to \(branch)")
            }
        } catch {
            failures.append("read immutable Git seed branch: \(error.localizedDescription)")
        }
        do {
            let status = try GitWorktreeTestSupport.runGit(["status", "--porcelain"], cwd: repositoryURL)
            if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("immutable Git seed working tree is dirty: \(status)")
            }
        } catch {
            failures.append("read immutable Git seed status: \(error.localizedDescription)")
        }
        do {
            let contents = try String(
                contentsOf: repositoryURL.appendingPathComponent("Tracked.txt"),
                encoding: .utf8
            )
            if contents != Self.trackedContents {
                failures.append("immutable Git seed Tracked.txt contents changed")
            }
        } catch {
            failures.append("read immutable Git seed Tracked.txt: \(error.localizedDescription)")
        }
        do {
            let output = try GitWorktreeTestSupport.runGit(["worktree", "list", "--porcelain"], cwd: repositoryURL)
            let worktrees = output
                .split(separator: "\n")
                .compactMap { line -> String? in
                    let prefix = "worktree "
                    guard line.hasPrefix(prefix) else { return nil }
                    return canonicalPath(URL(fileURLWithPath: String(line.dropFirst(prefix.count))))
                }
            if worktrees != [canonicalPath(repositoryURL)] {
                failures.append("immutable Git seed has unexpected worktrees: \(worktrees)")
            }
        } catch {
            failures.append("list immutable Git seed worktrees: \(error.localizedDescription)")
        }
        do {
            try validateRepositoryLayout(at: repositoryURL)
            let identities = try regularFileIdentities(in: repositoryURL)
            if let hardlinkedPath = identities.first(where: { $0.value.linkCount != 1 })?.key {
                failures.append("immutable Git seed contains a hardlinked regular file: \(hardlinkedPath)")
            }
        } catch {
            failures.append("validate immutable Git seed isolation: \(error.localizedDescription)")
        }
        return failures
    }

    private func validateRepositoryLayout(at repository: URL) throws {
        let fileManager = FileManager.default
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Copied repository does not have an ordinary .git directory"]
            )
        }
        guard !fileManager.fileExists(atPath: gitDirectory.appendingPathComponent("objects/info/alternates").path) else {
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Copied repository contains Git object alternates"]
            )
        }
        guard !fileManager.fileExists(atPath: gitDirectory.appendingPathComponent("worktrees").path),
              !fileManager.fileExists(atPath: gitDirectory.appendingPathComponent("commondir").path),
              !fileManager.fileExists(atPath: gitDirectory.appendingPathComponent("gitdir").path)
        else {
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Copied repository contains linked-worktree metadata"]
            )
        }
        let config = try String(contentsOf: gitDirectory.appendingPathComponent("config"), encoding: .utf8)
        guard !config.contains("[remote "), !config.contains(repositoryURL.path), !config.contains(containerURL.path) else {
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Copied repository config refers to a remote or immutable seed path"]
            )
        }
        guard fileManager.isWritableFile(atPath: repository.path), fileManager.isWritableFile(atPath: gitDirectory.path) else {
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Copied repository or .git directory is not writable"]
            )
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func regularFileIdentities(in root: URL) throws -> [String: FileIdentity] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                enumerationError = NSError(
                    domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                    code: 13,
                    userInfo: [
                        NSUnderlyingErrorKey: error,
                        NSLocalizedDescriptionKey: "Unable to enumerate repository path \(url.path)"
                    ]
                )
                return false
            }
        ) else {
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Unable to enumerate repository copy at \(root.path)"]
            )
        }

        var identities: [String: FileIdentity] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw NSError(
                    domain: "AgentRunWorktreeStartTests.GitSeedRepository",
                    code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "Repository copy contains symbolic link: \(url.path)"]
                )
            }
            guard values.isRegularFile == true else { continue }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "lstat failed for \(url.path)"]
                )
            }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            identities[relativePath] = FileIdentity(
                device: UInt64(bitPattern: Int64(metadata.st_dev)),
                inode: UInt64(metadata.st_ino),
                linkCount: UInt64(metadata.st_nlink)
            )
        }
        if let enumerationError {
            throw enumerationError
        }
        return identities
    }
}

private final class AgentRunWorktreeStartGitSeedOwner: @unchecked Sendable {
    private enum State {
        case notInstalled
        case installing
        case ready(AgentRunWorktreeStartGitSeedRepository)
        case failed(message: String, residualContainerURL: URL?)
        case cleaned
    }

    private let lock = NSLock()
    private var state: State = .notInstalled

    func install() {
        lock.lock()
        guard case .notInstalled = state else {
            lock.unlock()
            return
        }
        state = .installing
        lock.unlock()

        let containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentRunWorktreeStartTests-GitSeed-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        let installedState: State
        do {
            installedState = try .ready(AgentRunWorktreeStartGitSeedRepository.create(in: containerURL))
        } catch {
            var message = "create immutable Git seed: \(error.localizedDescription)"
            var residualContainerURL: URL?
            if FileManager.default.fileExists(atPath: containerURL.path) {
                do {
                    try FileManager.default.removeItem(at: containerURL)
                } catch {
                    message += "; remove partial seed container: \(error.localizedDescription)"
                    residualContainerURL = containerURL
                }
            }
            installedState = .failed(message: message, residualContainerURL: residualContainerURL)
        }

        lock.lock()
        state = installedState
        lock.unlock()
    }

    func requireSeed() throws -> AgentRunWorktreeStartGitSeedRepository {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case let .ready(seed):
            return seed
        case let .failed(message, _):
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedOwner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        case .notInstalled:
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedOwner",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Immutable Git seed was not installed by XCTest class setup"]
            )
        case .installing:
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedOwner",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Immutable Git seed setup is still in progress"]
            )
        case .cleaned:
            throw NSError(
                domain: "AgentRunWorktreeStartTests.GitSeedOwner",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Immutable Git seed was already cleaned"]
            )
        }
    }

    func tearDown() -> [String] {
        lock.lock()
        let installedState = state
        state = .cleaned
        lock.unlock()

        switch installedState {
        case let .ready(seed):
            return seed.tearDown()
        case let .failed(message, residualContainerURL):
            var failures = [message]
            if let residualContainerURL, FileManager.default.fileExists(atPath: residualContainerURL.path) {
                do {
                    try FileManager.default.removeItem(at: residualContainerURL)
                } catch {
                    failures.append(
                        "remove residual immutable Git seed container \(residualContainerURL.path): \(error.localizedDescription)"
                    )
                }
                if FileManager.default.fileExists(atPath: residualContainerURL.path) {
                    failures.append("residual immutable Git seed container leaked: \(residualContainerURL.path)")
                }
            }
            return failures
        case .notInstalled:
            return ["immutable Git seed owner was never installed"]
        case .installing:
            return ["immutable Git seed owner was still installing during class teardown"]
        case .cleaned:
            return []
        }
    }
}

class AgentRunWorktreeStartGitSeedTestCase: XCTestCase {
    private static let gitSeedOwner = AgentRunWorktreeStartGitSeedOwner()

    override class func setUp() {
        super.setUp()
        gitSeedOwner.install()
    }

    override class func tearDown() {
        let failures = gitSeedOwner.tearDown()
        if !failures.isEmpty {
            XCTFail("AgentRunWorktreeStartTests Git seed cleanup failures:\n- \(failures.joined(separator: "\n- "))")
        }
        super.tearDown()
    }

    fileprivate final func requireGitSeedRepository() throws -> AgentRunWorktreeStartGitSeedRepository {
        try Self.gitSeedOwner.requireSeed()
    }
}

@MainActor
final class AgentRunWorktreeStartTests: AgentRunWorktreeStartGitSeedTestCase {
    private var lifecycleFixture: LifecycleFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        lifecycleFixture = try LifecycleFixture(seedRepository: requireGitSeedRepository())
    }

    override func tearDown() async throws {
        let failures = await lifecycleFixture?.tearDown() ?? []
        lifecycleFixture = nil
        if !failures.isEmpty {
            XCTFail("AgentRunWorktreeStartTests lifecycle cleanup failures:\n- \(failures.joined(separator: "\n- "))")
        }
        try await super.tearDown()
    }

    func testPrimaryLogicalRootRequiresOneExactStandardizedVisibleMatch() throws {
        let primary = try makeTemporaryDirectory(named: "primary-logical-root")
        let secondary = try makeTemporaryDirectory(named: "secondary-logical-root")
        let primaryRef = WorkspaceRootRef(id: UUID(), name: "Primary", fullPath: primary.path)
        let secondaryRef = WorkspaceRootRef(id: UUID(), name: "Secondary", fullPath: secondary.path)

        XCTAssertEqual(
            AgentWorktreeRuntimeWorkspaceResolver.primaryLogicalRoot(
                in: [secondaryRef, primaryRef],
                fallbackWorkspacePath: primary.appendingPathComponent("..").appendingPathComponent(primary.lastPathComponent).path
            )?.id,
            primaryRef.id
        )
        XCTAssertNil(
            AgentWorktreeRuntimeWorkspaceResolver.primaryLogicalRoot(
                in: [primaryRef, WorkspaceRootRef(id: UUID(), name: "Duplicate", fullPath: primary.path)],
                fallbackWorkspacePath: primary.path
            )
        )
        XCTAssertNil(
            AgentWorktreeRuntimeWorkspaceResolver.primaryLogicalRoot(
                in: [secondaryRef],
                fallbackWorkspacePath: primary.path
            )
        )
        XCTAssertNil(
            AgentWorktreeRuntimeWorkspaceResolver.primaryLogicalRoot(
                in: [primaryRef],
                fallbackWorkspacePath: nil
            )
        )
    }

    func testEffectiveWorkspacePathCoversBoundUnboundAndMissingRecovery() throws {
        let root = try makeTemporaryDirectory(named: "root")
        let worktree = try makeTemporaryDirectory(named: "worktree")
        let missingWorktree = root.appendingPathComponent("missing-worktree")
        let viewModel = makeViewModel(workspacePath: root.path)

        let boundSession = AgentModeViewModel.TabSession(tabID: UUID())
        boundSession.worktreeBindings = [makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path)]
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: boundSession), worktree.path)

        let unboundSession = AgentModeViewModel.TabSession(tabID: UUID())
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: unboundSession), root.path)

        let missingSession = AgentModeViewModel.TabSession(tabID: UUID())
        missingSession.worktreeBindings = [
            makeBinding(
                logicalRoot: root.path,
                worktreeRoot: missingWorktree.path,
                label: "Feature WT"
            )
        ]
        XCTAssertThrowsError(try viewModel.effectiveWorkspacePath(for: missingSession)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(message.contains("Feature WT"), message)
            XCTAssertTrue(message.contains(missingWorktree.path), message)
            XCTAssertTrue(message.contains("unbind the session"), message)
        }
    }

    func testAgentRunSnapshotIncludesWorktreeBindingFields() throws {
        let root = try makeTemporaryDirectory(named: "root")
        let worktree = try makeTemporaryDirectory(named: "worktree")
        let binding = makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path, label: "Feature WT")
        let runID = UUID()
        let snapshot = AgentRunMCPSnapshot(
            sessionID: UUID(),
            runID: runID,
            tabID: UUID(),
            sessionName: "Worktree Agent",
            agentRaw: AgentProviderKind.codexExec.rawValue,
            agentDisplayName: AgentProviderKind.codexExec.displayName,
            modelRaw: "codex",
            reasoningEffortRaw: nil,
            status: .running,
            statusText: nil,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [AgentRunMCPSnapshot.WorktreeBinding(binding: binding)],
            activeWorktreeMerges: []
        )

        let object = snapshot.asObject()
        XCTAssertEqual(object["run_id"]?.stringValue, runID.uuidString)
        XCTAssertNil(AgentRunMCPSnapshot.expired(sessionID: UUID()).asObject()["run_id"])
        let worktreeObject = try XCTUnwrap(object["worktree"]?.objectValue)
        XCTAssertEqual(worktreeObject["worktree_id"]?.stringValue, "wt_test")
        XCTAssertEqual(worktreeObject["worktree_root_path"]?.stringValue, worktree.path)
        XCTAssertEqual(worktreeObject["visual_label"]?.stringValue, "Feature WT")
        XCTAssertEqual(worktreeObject["unavailable"]?.boolValue, false)
        XCTAssertEqual(object["worktree_bindings"]?.arrayValue?.count, 1)
    }

    func testCanonicalAgentRunReviewSourceStagesBindsToFreshWorktreeChildAndCleansUp() async throws {
        let root = try makeTemporaryDirectory(named: "canonical-review-root")
        let worktree = try makeTemporaryDirectory(named: "canonical-review-child-worktree")
        let window = try await makeWindow(root: root)
        let viewModel = window.agentModeViewModel
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let target = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: "Canonical review child",
            parentSessionID: nil,
            inheritWorktreeBindings: true
        )
        let targetSessionID = try XCTUnwrap(target.sessionID)
        try await viewModel.mcpActivateControlContext(
            forTabID: target.tabID,
            sessionID: targetSessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        let targetBinding = makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path)
        viewModel.session(for: target.tabID).worktreeBindings = [targetBinding]

        let selectedPath = root.appendingPathComponent("Tracked.txt").path
        let source = AgentRunOracleReviewSource.captured(.init(
            sourceTabID: sourceTabID,
            workspaceID: workspaceID,
            sourceSelectionRevision: 7,
            promptText: "frozen canonical prompt",
            selection: StoredSelection(selectedPaths: [selectedPath]),
            lookupContext: .visibleWorkspace,
            reviewGitContext: .automaticOnly(base: "HEAD", workspaceRootPaths: [root.path]),
            sourceAgentSessionID: nil,
            sourceAgentRunID: nil,
            sourceWorktreeBindings: []
        ))
        try viewModel.mcpStageAgentRunOracleReviewSource(
            source,
            targetTabID: target.tabID,
            targetSessionID: targetSessionID,
            expectedParentSessionID: nil
        )

        let runID = UUID()
        let delegated = try XCTUnwrap(
            viewModel.mcpBindPendingAgentRunOracleReviewContext(tabID: target.tabID, runID: runID)
        )
        XCTAssertEqual(delegated.targetRunID, runID)
        XCTAssertEqual(delegated.target.worktreeBindings, [targetBinding])
        XCTAssertEqual(delegated.capturedSource?.sourceWorktreeBindings, [])
        XCTAssertEqual(delegated.capturedSource?.promptText, "frozen canonical prompt")
        XCTAssertEqual(delegated.capturedSource?.exactSelectedIdentities, [selectedPath])
        XCTAssertEqual(
            try viewModel.mcpDelegatedAgentRunOracleReviewContext(
                tabID: target.tabID,
                workspaceID: workspaceID,
                sessionID: targetSessionID,
                runID: runID
            )?.source.delegationID,
            source.delegationID
        )
        XCTAssertThrowsError(try viewModel.mcpDelegatedAgentRunOracleReviewContext(
            tabID: target.tabID,
            workspaceID: workspaceID,
            sessionID: targetSessionID,
            runID: UUID()
        )) { error in
            XCTAssertEqual(error as? AgentRunOracleReviewUnavailableReason, .pendingContextAlreadyConsumed)
        }

        await viewModel.mcpDeactivateControlContext(sessionID: targetSessionID, cleanupSessionStore: true)
        XCTAssertNil(try viewModel.mcpDelegatedAgentRunOracleReviewContext(
            tabID: target.tabID,
            workspaceID: workspaceID,
            sessionID: targetSessionID,
            runID: runID
        ))
    }

    func testExternalStarterStagesFrozenReviewSourceWhenTargetIsSourceTab() async throws {
        let root = try makeTemporaryDirectory(named: "same-tab-review-root")
        let window = try await makeWindow(root: root)
        let viewModel = window.agentModeViewModel
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let target = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: sourceTabID,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: "Same-tab review child",
            parentSessionID: nil
        )
        let targetSessionID = try XCTUnwrap(target.sessionID)
        let source = AgentRunOracleReviewSource.captured(.init(
            sourceTabID: sourceTabID,
            workspaceID: workspaceID,
            sourceSelectionRevision: 13,
            promptText: "frozen before same-tab activation",
            selection: StoredSelection(selectedPaths: [root.appendingPathComponent("Tracked.txt").path]),
            lookupContext: .visibleWorkspace,
            reviewGitContext: .automaticOnly(base: "HEAD", workspaceRootPaths: [root.path]),
            sourceAgentSessionID: nil,
            sourceAgentRunID: nil,
            sourceWorktreeBindings: []
        ))

        _ = try await AgentExternalMCPRunStarter.start(
            target: target,
            message: "Review the frozen source.",
            metadata: .init(
                connectionID: nil,
                clientName: "same-tab-review-test",
                windowID: window.windowID,
                runPurpose: .unknown
            ),
            bindCurrentRequestToTab: { _, _ in },
            agentModeVM: viewModel,
            agentRaw: nil,
            modelRaw: nil,
            reasoningEffortRaw: nil,
            expectedParentSessionID: nil,
            oracleReviewSource: source,
            dispatchInstruction: { _, _, _, _, _ in .startedRun }
        )

        let runID = UUID()
        let delegated = try XCTUnwrap(
            viewModel.mcpBindPendingAgentRunOracleReviewContext(tabID: sourceTabID, runID: runID)
        )
        XCTAssertEqual(delegated.source.delegationID, source.delegationID)
        XCTAssertEqual(delegated.capturedSource?.promptText, "frozen before same-tab activation")
        await viewModel.mcpDeactivateControlContext(
            sessionID: targetSessionID,
            cleanupSessionStore: true
        )
    }

    func testReviewSourceStagingRejectsParentMutationAfterTargetCreation() async throws {
        let root = try makeTemporaryDirectory(named: "parent-mutation-review-root")
        let window = try await makeWindow(root: root)
        let viewModel = window.agentModeViewModel
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let expectedParentSessionID = UUID()
        let target = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: "Parent mutation child",
            parentSessionID: expectedParentSessionID
        )
        let targetSessionID = try XCTUnwrap(target.sessionID)
        try await viewModel.mcpActivateControlContext(
            forTabID: target.tabID,
            sessionID: targetSessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        viewModel.session(for: target.tabID).parentSessionID = UUID()
        let source = AgentRunOracleReviewSource.captured(.init(
            sourceTabID: sourceTabID,
            workspaceID: workspaceID,
            sourceSelectionRevision: 17,
            promptText: "parent mutation source",
            selection: StoredSelection(),
            lookupContext: .visibleWorkspace,
            reviewGitContext: .automaticOnly(base: "HEAD", workspaceRootPaths: [root.path]),
            sourceAgentSessionID: expectedParentSessionID,
            sourceAgentRunID: nil,
            sourceWorktreeBindings: []
        ))
        try viewModel.mcpStageAgentRunOracleReviewSource(
            source,
            targetTabID: target.tabID,
            targetSessionID: targetSessionID,
            expectedParentSessionID: expectedParentSessionID
        )
        let runID = UUID()
        let delegated = try XCTUnwrap(
            viewModel.mcpBindPendingAgentRunOracleReviewContext(
                tabID: target.tabID,
                runID: runID
            )
        )
        XCTAssertEqual(delegated.unavailableReason, .parentSessionMismatch)

        XCTAssertThrowsError(try viewModel.mcpDelegatedAgentRunOracleReviewContext(
            tabID: target.tabID,
            workspaceID: workspaceID,
            sessionID: targetSessionID,
            runID: runID
        )) { error in
            XCTAssertEqual(error as? AgentRunOracleReviewUnavailableReason, .targetActivationMismatch)
        }
        await viewModel.mcpDeactivateControlContext(
            sessionID: targetSessionID,
            cleanupSessionStore: true
        )
    }

    func testLinkedWorktreeAgentRunReviewSourceAllowsDifferentFrozenTargetAndRejectsDrift() async throws {
        let root = try makeTemporaryDirectory(named: "linked-review-root")
        let worktree = try makeTemporaryDirectory(named: "linked-review-worktree")
        let window = try await makeWindow(root: root)
        let viewModel = window.agentModeViewModel
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let parentSessionID = UUID()
        let binding = makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path)
        installParentAgentSession(
            parentSessionID,
            binding: binding,
            sourceTabID: sourceTabID,
            in: window
        )
        let sourceRunID = UUID()
        viewModel.session(for: sourceTabID).runID = sourceRunID
        let source = AgentRunOracleReviewSource.captured(.init(
            sourceTabID: sourceTabID,
            workspaceID: workspaceID,
            sourceSelectionRevision: 11,
            promptText: "frozen worktree prompt",
            selection: StoredSelection(selectedPaths: [worktree.appendingPathComponent("Tracked.txt").path]),
            lookupContext: .visibleWorkspace,
            reviewGitContext: .automaticOnly(
                base: "HEAD",
                workspaceRootPaths: [root.path],
                bindings: [binding]
            ),
            sourceAgentSessionID: parentSessionID,
            sourceAgentRunID: sourceRunID,
            sourceWorktreeBindings: [binding]
        ))

        let inheritedTarget = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: "Inherited review child",
            parentSessionID: parentSessionID,
            inheritWorktreeBindings: true
        )
        let inheritedSessionID = try XCTUnwrap(inheritedTarget.sessionID)
        try await viewModel.mcpActivateControlContext(
            forTabID: inheritedTarget.tabID,
            sessionID: inheritedSessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        try viewModel.mcpStageAgentRunOracleReviewSource(
            source,
            targetTabID: inheritedTarget.tabID,
            targetSessionID: inheritedSessionID,
            expectedParentSessionID: parentSessionID
        )
        let runID = UUID()
        _ = viewModel.mcpBindPendingAgentRunOracleReviewContext(tabID: inheritedTarget.tabID, runID: runID)
        let delegated = try XCTUnwrap(try viewModel.mcpDelegatedAgentRunOracleReviewContext(
            tabID: inheritedTarget.tabID,
            workspaceID: workspaceID,
            sessionID: inheritedSessionID,
            runID: runID
        ))
        XCTAssertEqual(delegated.capturedSource?.sourceWorktreeBindings, [binding])
        viewModel.session(for: inheritedTarget.tabID).worktreeBindings = []
        XCTAssertThrowsError(try viewModel.mcpDelegatedAgentRunOracleReviewContext(
            tabID: inheritedTarget.tabID,
            workspaceID: workspaceID,
            sessionID: inheritedSessionID,
            runID: runID
        )) { error in
            XCTAssertEqual(error as? AgentRunOracleReviewUnavailableReason, .targetBindingMismatch)
        }
        await viewModel.mcpDeactivateControlContext(sessionID: inheritedSessionID, cleanupSessionStore: true)

        let mismatchedTarget = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: "Mismatched review child",
            parentSessionID: parentSessionID,
            inheritWorktreeBindings: false
        )
        let mismatchedSessionID = try XCTUnwrap(mismatchedTarget.sessionID)
        try await viewModel.mcpActivateControlContext(
            forTabID: mismatchedTarget.tabID,
            sessionID: mismatchedSessionID,
            originatingConnectionID: nil,
            startPending: true
        )
        try viewModel.mcpStageAgentRunOracleReviewSource(
            source,
            targetTabID: mismatchedTarget.tabID,
            targetSessionID: mismatchedSessionID,
            expectedParentSessionID: parentSessionID
        )
        let mismatchedRunID = UUID()
        let unboundDelegated = try XCTUnwrap(viewModel.mcpBindPendingAgentRunOracleReviewContext(
            tabID: mismatchedTarget.tabID,
            runID: mismatchedRunID
        ))
        XCTAssertEqual(unboundDelegated.capturedSource?.sourceWorktreeBindings, [binding])
        XCTAssertEqual(unboundDelegated.target.worktreeBindings, [])
        XCTAssertNotNil(try viewModel.mcpDelegatedAgentRunOracleReviewContext(
            tabID: mismatchedTarget.tabID,
            workspaceID: workspaceID,
            sessionID: mismatchedSessionID,
            runID: mismatchedRunID
        ))

        viewModel.session(for: mismatchedTarget.tabID).worktreeBindings = [binding]
        XCTAssertThrowsError(try viewModel.mcpDelegatedAgentRunOracleReviewContext(
            tabID: mismatchedTarget.tabID,
            workspaceID: workspaceID,
            sessionID: mismatchedSessionID,
            runID: mismatchedRunID
        )) { error in
            XCTAssertEqual(error as? AgentRunOracleReviewUnavailableReason, .targetBindingMismatch)
        }
        await viewModel.mcpDeactivateControlContext(sessionID: mismatchedSessionID, cleanupSessionStore: true)
    }

    func testProductionCapturePreservesBoundStoredSelectionInsteadOfCanonicalUI() async throws {
        let logicalRoot = try makeTemporaryDirectory(named: "capture-logical-root")
        let worktreeRoot = try makeTemporaryDirectory(named: "capture-worktree-root")
        let window = try await makeWindow(root: logicalRoot)
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let parentSessionID = UUID()
        let binding = makeBinding(
            logicalRoot: logicalRoot.path,
            worktreeRoot: worktreeRoot.path
        )
        installParentAgentSession(
            parentSessionID,
            binding: binding,
            sourceTabID: sourceTabID,
            in: window
        )

        let storedSelection = StoredSelection(
            selectedPaths: [
                logicalRoot.appendingPathComponent("Sources/Feature.swift").path,
                logicalRoot.appendingPathComponent(
                    "Workspace.repoprompt/_git_data/repos/repo/snapshot/diff/all.patch"
                ).path
            ],
            codemapAutoEnabled: false
        )
        var composeTab = try XCTUnwrap(window.workspaceManager.composeTab(with: sourceTabID))
        composeTab.selection = storedSelection
        composeTab.activeAgentSessionID = parentSessionID
        window.workspaceManager.updateComposeTab(composeTab, markDirty: false)
        // The fixture's asynchronous Git-data maintenance may publish one final canonical
        // selection revision after workspace setup. Freeze only after that launch boundary has
        // settled; production capture must continue to reject any later revision change.
        try await Task.sleep(for: .seconds(2))
        await window.workspaceFilesViewModel.applyStoredSelection(StoredSelection())
        let divergentUISelection = window.workspaceFilesViewModel.snapshotSelection()
        XCTAssertTrue(divergentUISelection.selectedPaths.isEmpty)
        XCTAssertNotEqual(divergentUISelection, storedSelection)

        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let launchSnapshot = AgentRunOracleReviewLaunchSnapshot(
            route: .explicitTabContext,
            windowID: window.windowID,
            workspaceID: workspaceID,
            tabID: sourceTabID,
            selectionRevision: window.workspaceManager.selectionRevisionForMCP(
                workspaceID: workspaceID,
                tabID: sourceTabID
            ),
            promptText: composeTab.promptText,
            selection: storedSelection,
            sourceAgentSessionID: parentSessionID,
            routedRunID: nil
        )
        let source = await window.mcpServer.testCaptureAgentRunOracleReviewSource(
            snapshot: launchSnapshot,
            targetWindow: window
        )
        guard case let .captured(captured) = source else {
            if case let .unavailable(unavailable) = source {
                return XCTFail(
                    "Expected production source capture: \(unavailable.reason.localizedDescription)"
                )
            }
            return XCTFail("Expected production source capture")
        }
        XCTAssertEqual(captured.selection, storedSelection)
        XCTAssertEqual(captured.sourceAgentSessionID, parentSessionID)
        XCTAssertEqual(captured.sourceWorktreeBindings, [binding])
        XCTAssertEqual(
            Set(captured.exactSelectedIdentities),
            Set(storedSelection.selectedPaths)
        )
    }

    func testChildSessionWorktreeBindingInheritanceCanBeOptedOut() throws {
        let root = try makeTemporaryDirectory(named: "root")
        let worktree = try makeTemporaryDirectory(named: "worktree")
        let parentID = UUID()
        let viewModel = makeViewModel(workspacePath: root.path)
        let parent = viewModel.session(for: UUID())
        parent.testInstallPersistentSessionBinding(sessionID: parentID)
        parent.worktreeBindings = [makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path)]

        let inheritedChild = viewModel.session(for: UUID())
        inheritedChild.testInstallPersistentSessionBinding(sessionID: UUID())
        viewModel.applySpawnParentSessionID(parentID, to: inheritedChild)
        XCTAssertEqual(inheritedChild.parentSessionID, parentID)
        XCTAssertEqual(inheritedChild.worktreeBindings, parent.worktreeBindings)
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: inheritedChild), worktree.path)

        let optedOutChild = viewModel.session(for: UUID())
        optedOutChild.testInstallPersistentSessionBinding(sessionID: UUID())
        viewModel.applySpawnParentSessionID(parentID, to: optedOutChild, inheritWorktreeBindings: false)
        XCTAssertEqual(optedOutChild.parentSessionID, parentID)
        XCTAssertTrue(optedOutChild.worktreeBindings.isEmpty)
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: optedOutChild), root.path)
    }

    func testAgentRunAndExploreStartPreserveInheritanceOptOutAndTopLevelBehavior() async throws {
        let root = try makeTemporaryDirectory(named: "root")
        let worktree = try makeTemporaryDirectory(named: "worktree")
        let window = try await makeWindow(root: root)
        let viewModel = window.agentModeViewModel
        let initialSourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let parentBinding = makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path)
        let runCases: [(label: String, sourceIsMCPControlled: Bool, inherits: Bool)] = [
            ("run MCP controlled inherited", true, true),
            ("run MCP controlled opt out", true, false),
            ("run non-MCP inherited", false, true),
            ("run non-MCP opt out", false, false)
        ]

        for (index, testCase) in runCases.enumerated() {
            let sourceTabID: UUID
            if index == 0 {
                sourceTabID = initialSourceTabID
            } else {
                await window.promptManager.createBlankComposeTab(createAgentSession: false)
                sourceTabID = try XCTUnwrap(
                    window.workspaceManager.activeWorkspace?.activeComposeTabID,
                    testCase.label
                )
            }
            let parentID = UUID()
            if testCase.sourceIsMCPControlled {
                installParentAgentSession(parentID, binding: parentBinding, sourceTabID: sourceTabID, in: window)
            } else {
                let source = viewModel.session(for: sourceTabID)
                source.testInstallPersistentSessionBinding(sessionID: parentID)
                source.worktreeBindings = [parentBinding]
                XCTAssertNil(source.mcpControlContext, testCase.label)
            }
            let service = makeAgentRunStartService(window: window, sourceTabID: sourceTabID)
            var args: [String: Value] = [
                "op": .string("start"),
                "message": .string(testCase.label),
                "detach": .bool(true),
                "timeout": .int(0)
            ]
            if !testCase.inherits {
                args["inherit_worktree"] = .bool(false)
            }

            let value = try await service.execute(args: args)

            let object = try XCTUnwrap(value.objectValue, testCase.label)
            let sessionObject = try XCTUnwrap(object["session"]?.objectValue, testCase.label)
            let childSessionID = try XCTUnwrap(
                try UUID(uuidString: XCTUnwrap(object["session_id"]?.stringValue, testCase.label)),
                testCase.label
            )
            let childTabID = try XCTUnwrap(
                try UUID(uuidString: XCTUnwrap(sessionObject["context_id"]?.stringValue, testCase.label)),
                testCase.label
            )
            XCTAssertEqual(sessionObject["parent_session_id"]?.stringValue, parentID.uuidString, testCase.label)

            let child = viewModel.session(for: childTabID)
            XCTAssertEqual(child.activeAgentSessionID, childSessionID, testCase.label)
            XCTAssertEqual(child.parentSessionID, parentID, testCase.label)
            if testCase.inherits {
                let bindings = try XCTUnwrap(object["worktree_bindings"]?.arrayValue, testCase.label)
                XCTAssertEqual(bindings.count, 1, testCase.label)
                let bindingObject = try XCTUnwrap(bindings.first?.objectValue, testCase.label)
                XCTAssertEqual(bindingObject["worktree_root_path"]?.stringValue, worktree.path, testCase.label)
                XCTAssertEqual(child.worktreeBindings, [parentBinding], testCase.label)
                XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: child), worktree.path, testCase.label)
            } else {
                XCTAssertNil(object["worktree"], testCase.label)
                XCTAssertNil(object["worktree_bindings"], testCase.label)
                XCTAssertTrue(child.worktreeBindings.isEmpty, testCase.label)
                XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: child), root.path, testCase.label)
            }
        }

        let topLevelService = makeAgentRunStartService(window: window, sourceTabID: nil)
        let topLevelValue = try await topLevelService.execute(args: [
            "op": .string("start"),
            "message": .string("legitimate external top-level start"),
            "detach": .bool(true),
            "timeout": .int(0)
        ])
        let topLevelObject = try XCTUnwrap(topLevelValue.objectValue)
        let topLevelSessionObject = try XCTUnwrap(topLevelObject["session"]?.objectValue)
        let topLevelTabID = try XCTUnwrap(
            try UUID(uuidString: XCTUnwrap(topLevelSessionObject["context_id"]?.stringValue))
        )
        XCTAssertNil(topLevelSessionObject["parent_session_id"]?.stringValue)
        XCTAssertNil(topLevelObject["worktree"])
        XCTAssertNil(topLevelObject["worktree_bindings"])
        let topLevelChild = viewModel.session(for: topLevelTabID)
        XCTAssertNil(topLevelChild.parentSessionID)
        XCTAssertTrue(topLevelChild.worktreeBindings.isEmpty)
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: topLevelChild), root.path)

        for testCase in [
            (label: "explore inherited", inherits: true),
            (label: "explore opt out", inherits: false)
        ] {
            await window.promptManager.createBlankComposeTab(createAgentSession: false)
            let sourceTabID = try XCTUnwrap(
                window.workspaceManager.activeWorkspace?.activeComposeTabID,
                testCase.label
            )
            let parentID = UUID()
            installParentAgentSession(parentID, binding: parentBinding, sourceTabID: sourceTabID, in: window)
            let recorder = ExploreStartRecorder()
            let service = makeAgentExploreStartService(window: window, sourceTabID: sourceTabID, recorder: recorder)
            var args: [String: Value] = [
                "op": .string("start"),
                "message": .string("inspect inherited worktree"),
                "detach": .bool(true),
                "timeout": .int(0)
            ]
            if !testCase.inherits {
                args["inherit_worktree"] = .bool(false)
            }

            _ = try await service.execute(args: args)

            let observation = try XCTUnwrap(recorder.observations.first, testCase.label)
            XCTAssertEqual(recorder.observations.count, 1, testCase.label)
            XCTAssertEqual(observation.message, "inspect inherited worktree", testCase.label)
            XCTAssertEqual(observation.taskLabelKind, .explore, testCase.label)
            XCTAssertNil(observation.workflow, testCase.label)
            XCTAssertNotEqual(observation.tabID, sourceTabID, testCase.label)
            let child = viewModel.session(for: observation.tabID)
            XCTAssertEqual(child.parentSessionID, parentID, testCase.label)
            if testCase.inherits {
                XCTAssertEqual(observation.bindings, [parentBinding], testCase.label)
                XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: child), worktree.path, testCase.label)
            } else {
                XCTAssertTrue(observation.bindings.isEmpty, testCase.label)
                XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: child), root.path, testCase.label)
            }
        }
    }

    func testManualFirstSendCreatesAndBindsNewWorktreeAcrossNewAndLinkedRoutes() async throws {
        let routeCases: [(label: String, linked: Bool, text: String)] = [
            ("new destination tab", false, "start in a worktree"),
            ("existing fresh linked tab", true, "start linked thread in a worktree")
        ]

        for testCase in routeCases {
            let fixture = try makeGitFixture()
            let window = try await makeWindow(root: fixture.repo)
            let viewModel = window.agentModeViewModel
            window.apiSettingsViewModel.isCodexConnected = true
            let originalTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID, testCase.label)
            let sourceTabID: UUID
            if testCase.linked {
                let createdTabID = await viewModel.createAndActivateSessionTab()
                sourceTabID = try XCTUnwrap(createdTabID, testCase.label)
            } else {
                sourceTabID = originalTabID
            }
            let sourceSession = await viewModel.ensureSessionReady(tabID: sourceTabID)
            sourceSession.selectedAgent = .codexExec
            viewModel.selectedAgent = .codexExec
            viewModel.selectInitialStartLocation(.newWorktree, for: sourceTabID)
            let target = try XCTUnwrap(
                viewModel.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession),
                testCase.label
            )
            if testCase.linked {
                XCTAssertEqual(target.route, .existingAgentSession, testCase.label)
            }
            let initialTabCount = try XCTUnwrap(window.workspaceManager.activeWorkspace, testCase.label).composeTabs.count

            try await withIsolatedBootstrapSocketNamespace(window: window) { namespace in
                if testCase.linked {
                    namespace.track(tabID: sourceTabID, session: sourceSession)
                }
                let result = await viewModel.submitUserTurnCreatingSessionIfNeeded(
                    text: testCase.text,
                    target: target,
                    createAndActivateSessionTab: {
                        if testCase.linked {
                            XCTFail("Linked first send must not create another destination tab: \(testCase.label)")
                            return nil
                        }
                        let destinationTabID = await viewModel.createAndActivateSessionTab()
                        if let destinationTabID {
                            namespace.track(tabID: destinationTabID, session: viewModel.session(for: destinationTabID))
                        }
                        return destinationTabID
                    }
                )

                XCTAssertEqual(result, .submitted, testCase.label)
                if result == .submitted {
                    try await namespace.acceptedSubmitAndAwaitOwnedSocket()
                }
                let activeTabID = try XCTUnwrap(
                    window.workspaceManager.activeWorkspace?.activeComposeTabID,
                    testCase.label
                )
                let destinationSession = viewModel.session(for: activeTabID)
                if testCase.linked {
                    XCTAssertEqual(activeTabID, sourceTabID, testCase.label)
                    XCTAssertEqual(
                        window.workspaceManager.activeWorkspace?.composeTabs.count,
                        initialTabCount,
                        testCase.label
                    )
                } else {
                    XCTAssertNotEqual(activeTabID, sourceTabID, testCase.label)
                    XCTAssertEqual(
                        window.workspaceManager.activeWorkspace?.composeTabs.count,
                        initialTabCount + 1,
                        testCase.label
                    )
                }
                let binding = try XCTUnwrap(destinationSession.worktreeBindings.first, testCase.label)
                XCTAssertEqual(binding.source, "agent_ui.initial_send", testCase.label)
                XCTAssertEqual(binding.logicalRootPath, fixture.repo.path, testCase.label)
                XCTAssertTrue(binding.worktreeRootPath.contains(".repoprompt-worktrees"), testCase.label)
                XCTAssertEqual(
                    try viewModel.effectiveWorkspacePath(for: destinationSession),
                    binding.worktreeRootPath,
                    testCase.label
                )
                XCTAssertNil(viewModel.initialStartLocationProps(tabID: activeTabID), testCase.label)
                XCTAssertEqual(
                    viewModel.executionLocationProps(tabID: activeTabID)?.indicator?.worktreeID,
                    binding.worktreeID,
                    testCase.label
                )
                XCTAssertEqual(
                    destinationSession.items.first(where: { $0.kind == .user })?.text,
                    testCase.text,
                    testCase.label
                )
            }
        }
    }

    func testManualNewWorktreeFirstSendRejectsNonGitRootAcrossNewAndLinkedRoutes() async throws {
        let root = try makeTemporaryDirectory(named: "non-git-root")
        let window = try await makeWindow(root: root)
        let viewModel = window.agentModeViewModel
        window.apiSettingsViewModel.isCodexConnected = true
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let sourceSession = await viewModel.ensureSessionReady(tabID: sourceTabID)
        sourceSession.selectedAgent = .codexExec
        viewModel.selectedAgent = .codexExec
        viewModel.selectInitialStartLocation(.newWorktree, for: sourceTabID)
        let sourceTarget = try XCTUnwrap(
            viewModel.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession)
        )
        let sourceTabCount = try XCTUnwrap(window.workspaceManager.activeWorkspace).composeTabs.count

        let sourceResult = await viewModel.submitUserTurnCreatingSessionIfNeeded(
            text: "cannot create worktree",
            target: sourceTarget
        )
        guard case let .blocked(sourceMessage) = sourceResult else {
            return XCTFail("Expected non-Git source worktree start to be blocked")
        }
        XCTAssertTrue(sourceMessage.contains("Git-backed primary workspace root"), sourceMessage)
        XCTAssertEqual(window.workspaceManager.activeWorkspace?.activeComposeTabID, sourceTabID)
        XCTAssertEqual(window.workspaceManager.activeWorkspace?.composeTabs.count, sourceTabCount)
        XCTAssertEqual(sourceSession.pendingInitialStartLocation, .newWorktree)
        XCTAssertTrue(sourceSession.worktreeBindings.isEmpty)
        XCTAssertTrue(sourceSession.items.isEmpty)
        XCTAssertEqual(viewModel.initialStartLocationProps(tabID: sourceTabID)?.selection, .newWorktree)

        let createdLinkedTabID = await viewModel.createAndActivateSessionTab()
        let linkedTabID = try XCTUnwrap(createdLinkedTabID)
        let linkedSession = await viewModel.ensureSessionReady(tabID: linkedTabID)
        linkedSession.selectedAgent = .codexExec
        viewModel.selectInitialStartLocation(.newWorktree, for: linkedTabID)
        let linkedTarget = try XCTUnwrap(
            viewModel.makeComposerSubmitTarget(tabID: linkedTabID, session: linkedSession)
        )
        XCTAssertEqual(linkedTarget.route, .existingAgentSession)
        let linkedTabCount = try XCTUnwrap(window.workspaceManager.activeWorkspace).composeTabs.count

        let linkedResult = await viewModel.submitUserTurnCreatingSessionIfNeeded(
            text: "cannot create linked worktree",
            target: linkedTarget,
            createAndActivateSessionTab: {
                XCTFail("Non-Git linked route must not create another destination tab")
                return nil
            }
        )
        guard case let .blocked(linkedMessage) = linkedResult else {
            return XCTFail("Expected non-Git linked worktree start to be blocked")
        }
        XCTAssertTrue(linkedMessage.contains("Git-backed primary workspace root"), linkedMessage)
        XCTAssertEqual(window.workspaceManager.activeWorkspace?.activeComposeTabID, linkedTabID)
        XCTAssertEqual(window.workspaceManager.activeWorkspace?.composeTabs.count, linkedTabCount)
        XCTAssertEqual(linkedSession.pendingInitialStartLocation, .newWorktree)
        XCTAssertTrue(linkedSession.worktreeBindings.isEmpty)
        XCTAssertTrue(linkedSession.items.isEmpty)
        XCTAssertEqual(viewModel.initialStartLocationProps(tabID: linkedTabID)?.selection, .newWorktree)
    }

    func testManualFirstSendListsAndBindsExistingPrimaryRepositoryWorktree() async throws {
        let fixture = try makeGitFixture()
        let sibling = fixture.sandbox.appendingPathComponent("existing-ui-worktree", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature/existing-ui-\(fixture.suffix)", sibling.path, "HEAD"], cwd: fixture.repo)
        let window = try await makeWindow(root: fixture.repo)
        let viewModel = window.agentModeViewModel
        window.apiSettingsViewModel.isCodexConnected = true
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let sourceSession = await viewModel.ensureSessionReady(tabID: sourceTabID)
        sourceSession.selectedAgent = .codexExec
        viewModel.selectedAgent = .codexExec

        let choices = try await viewModel.availableExecutionWorktrees(for: sourceTabID)
        let existing = try XCTUnwrap(choices.first { samePath($0.path, sibling.path) })
        XCTAssertFalse(choices.contains { samePath($0.path, fixture.repo.path) })
        let selectionResult = await viewModel.selectExecutionLocation(.existingWorktree(existing), for: sourceTabID)
        XCTAssertEqual(selectionResult, .applied)
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))

        try await withIsolatedBootstrapSocketNamespace(window: window) { namespace in
            let result = await viewModel.submitUserTurnCreatingSessionIfNeeded(
                text: "start in existing",
                target: target,
                createAndActivateSessionTab: {
                    let destinationTabID = await viewModel.createAndActivateSessionTab()
                    if let destinationTabID {
                        namespace.track(tabID: destinationTabID, session: viewModel.session(for: destinationTabID))
                    }
                    return destinationTabID
                }
            )

            XCTAssertEqual(result, .submitted)
            if result == .submitted {
                try await namespace.acceptedSubmitAndAwaitOwnedSocket()
            }
            let destinationTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
            let destination = viewModel.session(for: destinationTabID)
            let binding = try XCTUnwrap(destination.worktreeBindings.first)
            XCTAssertEqual(binding.worktreeID, existing.worktreeID)
            XCTAssertEqual(binding.worktreeRootPath, sibling.standardizedFileURL.path)
            XCTAssertEqual(binding.source, "agent_ui.initial_send_existing")
            XCTAssertEqual(viewModel.executionLocationProps(tabID: destinationTabID)?.indicator?.worktreeID, existing.worktreeID)
        }
    }

    func testStartedThreadLocationChangesPreserveConfirmationIdentityAndPendingHandoffContracts() async throws {
        let fixture = try makeGitFixture()
        let sibling = fixture.sandbox.appendingPathComponent("reusable-location", isDirectory: true)
        try runGit(
            ["worktree", "add", "-b", "feature/reusable-location-\(fixture.suffix)", sibling.path, "HEAD"],
            cwd: fixture.repo
        )
        let window = try await makeWindow(root: fixture.repo)
        let viewModel = window.agentModeViewModel
        let createdTabID = await viewModel.createAndActivateSessionTab()
        let tabID = try XCTUnwrap(createdTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.selectedAgent = .codexExec
        session.providerSessionID = "old-provider-cwd"
        session.codexConversationID = "old-codex-cwd"
        session.codexRolloutPath = "/tmp/old-rollout"
        session.items = [
            .user("Previous question", sequenceIndex: 0),
            .assistant("Previous answer", sequenceIndex: 1)
        ]
        session.worktreeBindings = [makeBinding(logicalRoot: fixture.repo.path, worktreeRoot: sibling.path)]

        let localWarning = await viewModel.selectExecutionLocation(.local, for: tabID)
        XCTAssertEqual(localWarning, .confirmationRequired(.startedThreadRestart))
        XCTAssertEqual(session.worktreeBindings.first?.worktreeRootPath, sibling.standardizedFileURL.path)
        XCTAssertEqual(session.providerSessionID, "old-provider-cwd")
        XCTAssertEqual(session.codexConversationID, "old-codex-cwd")
        XCTAssertEqual(session.codexRolloutPath, "/tmp/old-rollout")

        let localResult = await viewModel.selectExecutionLocation(
            .local,
            for: tabID,
            confirmedChange: .startedThreadRestart
        )
        XCTAssertEqual(localResult, .applied)
        XCTAssertTrue(session.worktreeBindings.isEmpty)
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: session), fixture.repo.path)
        XCTAssertNil(session.providerSessionID)
        XCTAssertNil(session.codexConversationID)
        XCTAssertNil(session.codexRolloutPath)
        let pendingPayload = try XCTUnwrap(session.pendingHandoff.payload)
        XCTAssertFalse(session.pendingHandoff.defersProviderLockUntilSend)
        XCTAssertFalse(session.pendingHandoff.isStagedForSend)
        XCTAssertEqual(viewModel.executionLocationProps(tabID: tabID)?.selection, .local)
        XCTAssertEqual(viewModel.executionLocationProps(tabID: tabID)?.isEnabled, true)

        let unchanged = await viewModel.selectExecutionLocation(.local, for: tabID)
        XCTAssertEqual(unchanged, .unchanged)

        let newWarning = await viewModel.selectExecutionLocation(.newWorktree, for: tabID)
        XCTAssertEqual(newWarning, .confirmationRequired(.startedThreadRestart))
        XCTAssertTrue(session.worktreeBindings.isEmpty)
        let newResult = await viewModel.selectExecutionLocation(
            .newWorktree,
            for: tabID,
            confirmedChange: .startedThreadRestart
        )
        XCTAssertEqual(newResult, .applied)
        let newBinding = try XCTUnwrap(session.worktreeBindings.first)
        XCTAssertEqual(newBinding.source, "agent_ui.location_change_new")
        XCTAssertTrue(newBinding.worktreeRootPath.contains(".repoprompt-worktrees"), newBinding.worktreeRootPath)
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: session), newBinding.worktreeRootPath)
        XCTAssertEqual(session.pendingHandoff.payload, pendingPayload)
        XCTAssertFalse(session.pendingHandoff.isStagedForSend)
        XCTAssertEqual(viewModel.executionLocationProps(tabID: tabID)?.isEnabled, true)

        let choices = try await viewModel.availableExecutionWorktrees(for: tabID)
        let existing = try XCTUnwrap(choices.first { samePath($0.path, sibling.path) })
        let existingWarning = await viewModel.selectExecutionLocation(.existingWorktree(existing), for: tabID)
        XCTAssertEqual(existingWarning, .confirmationRequired(.startedThreadRestart))
        let existingResult = await viewModel.selectExecutionLocation(
            .existingWorktree(existing),
            for: tabID,
            confirmedChange: .startedThreadRestart
        )
        XCTAssertEqual(existingResult, .applied)
        XCTAssertEqual(session.worktreeBindings.first?.worktreeID, existing.worktreeID)
        XCTAssertEqual(session.pendingHandoff.payload, pendingPayload)
        XCTAssertFalse(session.pendingHandoff.isStagedForSend)
        XCTAssertEqual(viewModel.executionLocationProps(tabID: tabID)?.isEnabled, true)
    }

    func testBindingTransitionMaterializesAndInitializesSessionWorktreeCodemap() async throws {
        let root = try makeTemporaryDirectory(named: "transition-root")
        let worktree = try makeTemporaryDirectory(named: "transition-worktree")
        let sourceFile = worktree.appendingPathComponent("Sources/Transition.swift")
        try FileManager.default.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "struct TransitionWorktreeType {\n    func transitionMethod() {}\n}\n".write(
            to: sourceFile,
            atomically: true,
            encoding: .utf8
        )
        let window = try await makeWindow(root: root)
        let viewModel = window.agentModeViewModel
        let createdTabID = await viewModel.createAndActivateSessionTab()
        let tabID = try XCTUnwrap(createdTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        let binding = makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path, worktreeID: "transition")

        _ = try await viewModel.transitionWorktreeBindings(
            [binding],
            forSessionID: sessionID,
            intent: .externalManagement
        )

        XCTAssertEqual(session.worktreeBindings, [binding])
        let materializedProjection = await window.mcpServer.materializeWorkspaceBindingProjection(
            sessionID: sessionID,
            bindings: [binding]
        )
        let projection = try XCTUnwrap(materializedProjection)
        let physicalRoot = try XCTUnwrap(projection.physicalRootRefs.first)
        let redundantInitialization = await window.workspaceFileContextStore.initializeCodemapsForSessionWorktreeRoots(
            rootIDs: [physicalRoot.id]
        )
        XCTAssertTrue(redundantInitialization.isEmpty)
        let result = await window.workspaceFileContextStore.lookupPath(
            sourceFile.path,
            profile: .mcpRead,
            rootScope: projection.lookupRootScope
        )
        let file = try XCTUnwrap(result?.file)
        let repair = try await window.workspaceFileContextStore.repairMissingCodemapSnapshots(
            for: [file],
            timeout: .seconds(6)
        )
        let immediateSnapshot = repair.snapshotsByFileID[file.id]
        let snapshot: WorkspaceCodemapSnapshot
        if immediateSnapshot == nil {
            XCTAssertEqual(repair.pendingFileIDs, [file.id])
            snapshot = try await waitForCodemapSnapshot(
                store: window.workspaceFileContextStore,
                fileID: file.id
            )
        } else {
            snapshot = try XCTUnwrap(immediateSnapshot)
        }
        XCTAssertTrue(snapshot.fileAPI?.apiDescription.contains("TransitionWorktreeType") == true)

        let activeDiagnostics = await window.workspaceFileContextStore.readSearchRootDiagnosticsSnapshot()
        let activeRoot = try XCTUnwrap(activeDiagnostics.first { $0.rootID == physicalRoot.id })
        XCTAssertTrue(activeRoot.watcherActive)
        XCTAssertEqual(activeRoot.sessionWorktreeOwnerCount, 1)
        XCTAssertEqual(activeRoot.crawlCount, 1)

        _ = await window.mcpServer.materializeWorkspaceBindingProjection(
            sessionID: sessionID,
            bindings: [binding]
        )
        let repeatedDiagnostics = await window.workspaceFileContextStore.readSearchRootDiagnosticsSnapshot()
        XCTAssertEqual(repeatedDiagnostics.first { $0.rootID == physicalRoot.id }?.crawlCount, 1)
        XCTAssertEqual(repeatedDiagnostics.first { $0.rootID == physicalRoot.id }?.sessionWorktreeOwnerCount, 1)

        _ = try await viewModel.transitionWorktreeBindings(
            [],
            forSessionID: sessionID,
            intent: .externalManagement
        )
        XCTAssertTrue(session.worktreeBindings.isEmpty)
        let rootsAfterUnbind = await window.workspaceFileContextStore.roots()
        XCTAssertFalse(rootsAfterUnbind.contains { $0.id == physicalRoot.id })
        let releasedOwnership = await window.workspaceFileContextStore.sessionWorktreeOwnershipDebugSnapshotForTesting()
        XCTAssertEqual(releasedOwnership.installedOwnerCount, 0)
        XCTAssertEqual(releasedOwnership.rootClaimCount, 0)
    }

    func testBindingTransitionValidatesAndMaterializesChangedSecondaryBindingWithoutRestartingPrimaryIdentity() async throws {
        let primaryRoot = try makeTemporaryDirectory(named: "transition-primary-root")
        let primaryWorktree = try makeTemporaryDirectory(named: "transition-primary-worktree")
        let missingSecondaryRoot = try makeTemporaryDirectory(named: "transition-missing-secondary-root")
        let validSecondaryRoot = try makeTemporaryDirectory(named: "transition-valid-secondary-root")
        let missingSecondaryWorktree = missingSecondaryRoot.appendingPathComponent("missing-worktree")
        let validSecondaryWorktree = try makeTemporaryDirectory(named: "transition-valid-secondary-worktree")
        try "struct SecondaryWorktreeType {}\n".write(
            to: validSecondaryWorktree.appendingPathComponent("Secondary.swift"),
            atomically: true,
            encoding: .utf8
        )
        let window = try await makeWindow(root: primaryRoot)
        _ = try await window.workspaceFileContextStore.loadRoot(path: missingSecondaryRoot.path)
        _ = try await window.workspaceFileContextStore.loadRoot(path: validSecondaryRoot.path)
        let viewModel = window.agentModeViewModel
        let createdTabID = await viewModel.createAndActivateSessionTab()
        let tabID = try XCTUnwrap(createdTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        session.hasLoadedPersistedState = true
        session.runState = .running
        session.runID = UUID()
        session.providerSessionID = "stable-provider-identity"
        session.codexConversationID = "stable-codex-identity"
        let primaryBinding = makeBinding(
            logicalRoot: primaryRoot.path,
            worktreeRoot: primaryWorktree.path,
            worktreeID: "primary"
        )
        let unavailableSecondary = makeBinding(
            logicalRoot: missingSecondaryRoot.path,
            worktreeRoot: missingSecondaryWorktree.path,
            worktreeID: "missing-secondary"
        )
        let validSecondary = makeBinding(
            logicalRoot: validSecondaryRoot.path,
            worktreeRoot: validSecondaryWorktree.path,
            worktreeID: "valid-secondary"
        )
        session.worktreeBindings = [primaryBinding]

        do {
            _ = try await viewModel.transitionWorktreeBindings(
                [primaryBinding, unavailableSecondary],
                forSessionID: sessionID,
                intent: .externalManagement
            )
            XCTFail("Expected every changed binding set to be validated before commit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(missingSecondaryWorktree.path), error.localizedDescription)
        }
        XCTAssertEqual(session.worktreeBindings, [primaryBinding])
        XCTAssertEqual(session.providerSessionID, "stable-provider-identity")
        XCTAssertEqual(session.codexConversationID, "stable-codex-identity")

        _ = try await viewModel.transitionWorktreeBindings(
            [primaryBinding, validSecondary],
            forSessionID: sessionID,
            intent: .externalManagement
        )
        XCTAssertEqual(session.worktreeBindings, [primaryBinding, validSecondary])
        XCTAssertEqual(session.providerSessionID, "stable-provider-identity")
        XCTAssertEqual(session.codexConversationID, "stable-codex-identity")
        let materializedProjection = await window.mcpServer.materializeWorkspaceBindingProjection(
            sessionID: sessionID,
            bindings: session.worktreeBindings
        )
        let projection = try XCTUnwrap(materializedProjection)
        XCTAssertEqual(projection.physicalRootPaths, Set([
            primaryWorktree.standardizedFileURL.path,
            validSecondaryWorktree.standardizedFileURL.path
        ]))
    }

    func testDeferredPendingHandoffStillBlocksStartedThreadLocationChange() async throws {
        let root = try makeTemporaryDirectory(named: "deferred-root")
        let worktree = try makeTemporaryDirectory(named: "deferred-worktree")
        let viewModel = makeViewModel(workspacePath: root.path)
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.worktreeBindings = [makeBinding(logicalRoot: root.path, worktreeRoot: worktree.path)]
        session.pendingHandoff = .init(payload: "fork handoff", defersProviderLockUntilSend: true)
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let props = try XCTUnwrap(viewModel.executionLocationProps(tabID: tabID))
        XCTAssertFalse(props.isEnabled)
        XCTAssertEqual(props.disabledReason, "Send or clear the pending handoff before changing location.")

        let result = await viewModel.selectExecutionLocation(.local, for: tabID)

        XCTAssertEqual(result, .blocked("This thread cannot change execution location right now."))
        XCTAssertEqual(session.worktreeBindings.first?.worktreeRootPath, worktree.path)
        XCTAssertEqual(session.pendingHandoff.payload, "fork handoff")
    }

    func testActiveStartedThreadRequiresConfirmationAndNeverCommitsStaleIdentityMidSwitch() async throws {
        let root = try makeTemporaryDirectory(named: "active-root")
        let oldWorktree = try makeTemporaryDirectory(named: "old-worktree")
        let viewModel = makeViewModel(workspacePath: root.path)
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        let sessionID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test")
        session.providerSessionID = "provider-from-old-cwd"
        session.worktreeBindings = [makeBinding(logicalRoot: root.path, worktreeRoot: oldWorktree.path)]
        session.items = [.user("in-flight prompt", sequenceIndex: 0)]
        session.pendingACPSteeringInstructions = [
            .init(
                id: UUID(),
                targetRunID: session.runID,
                targetRunAttemptID: session.activeRunAttemptID,
                providerText: "provider-wrapped queued steering",
                interruptedPromptProviderText: "in-flight prompt",
                attachments: [],
                taggedFileAttachments: [],
                draftText: "queued ACP draft",
                optimisticUserItemID: nil,
                createdAt: Date()
            )
        ]
        session.pendingInstructions = ["queued shared draft"]
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let result = await viewModel.selectExecutionLocation(.local, for: tabID)

        XCTAssertEqual(result, .confirmationRequired(.activeRunStop))
        XCTAssertEqual(session.worktreeBindings.first?.worktreeRootPath, oldWorktree.path)
        XCTAssertEqual(session.providerSessionID, "provider-from-old-cwd")

        let applied = await viewModel.selectExecutionLocation(
            .local,
            for: tabID,
            confirmedChange: .activeRunStop
        )
        XCTAssertEqual(applied, .applied)
        XCTAssertTrue(session.worktreeBindings.isEmpty)
        XCTAssertNil(session.providerSessionID)
        XCTAssertEqual(viewModel.retrieveDraftText(for: tabID), "queued ACP draft\nqueued shared draft")
        XCTAssertFalse(viewModel.retrieveDraftText(for: tabID).contains("in-flight prompt"))
        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["in-flight prompt"])
    }

    func testLiveMCPWorktreeSwitchPreservesActiveRuntimeIdentityAndFutureWorkspacePath() async throws {
        let root = try makeTemporaryDirectory(named: "live-switch-root")
        let oldWorktree = try makeTemporaryDirectory(named: "live-switch-old-worktree")
        let newWorktree = try makeTemporaryDirectory(named: "live-switch-new-worktree")
        let window = try await makeWindow(root: root)
        let viewModel = window.agentModeViewModel
        let createdTabID = await viewModel.createAndActivateSessionTab()
        let tabID = try XCTUnwrap(createdTabID)
        let session = await viewModel.ensureSessionReady(tabID: tabID)
        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
        let runID = UUID()
        let controller = LiveSwitchWorktreeStartFakeCodexController()
        let oldBinding = makeBinding(
            logicalRoot: root.path,
            worktreeRoot: oldWorktree.path,
            worktreeID: "live-old"
        )
        let newBinding = makeBinding(
            logicalRoot: root.path,
            worktreeRoot: newWorktree.path,
            worktreeID: "live-new"
        )
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.selectedAgent = .codexExec
        session.runState = .running
        session.runID = runID
        session.providerSessionID = "provider-session-old-cwd"
        session.codexConversationID = "codex-conversation-old-cwd"
        session.codexRolloutPath = "/tmp/codex-rollout-old-cwd"
        session.codexController = controller
        session.codexControllerWorkspacePath = oldWorktree.path
        session.codexControllerGoalSupportEnabled = CodexGoalSupport.isEnabled
        session.pendingInstructions = ["queued instruction"]
        session.worktreeBindings = [oldBinding]
        let controllerGeneration = session.codexControllerGeneration

        _ = try await viewModel.transitionWorktreeBindings(
            [newBinding],
            forSessionID: sessionID,
            intent: .liveMCPWorktreeSwitch
        )

        XCTAssertEqual(session.worktreeBindings, [newBinding])
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.runID, runID)
        XCTAssertEqual(session.providerSessionID, "provider-session-old-cwd")
        XCTAssertEqual(session.codexConversationID, "codex-conversation-old-cwd")
        XCTAssertEqual(session.codexRolloutPath, "/tmp/codex-rollout-old-cwd")
        XCTAssertEqual(session.pendingInstructions, ["queued instruction"])
        XCTAssertTrue(session.codexController === controller)
        XCTAssertEqual(session.codexControllerGeneration, controllerGeneration)
        XCTAssertTrue(session.retainsCodexControllerForLiveWorktreeSwitch(controller))
        XCTAssertEqual(session.codexControllerWorkspacePath, oldWorktree.path)
        XCTAssertEqual(try viewModel.effectiveWorkspacePath(for: session), newWorktree.path)

        await viewModel.codexCoordinator.ensureCodexNativeSession(
            session: session,
            deferReconnectForCurrentActiveTurn: true,
            preserveExistingRunID: true,
            semanticRunState: .running
        )

        XCTAssertTrue(session.codexController === controller)
        XCTAssertEqual(controller.shutdownCount, 0)
        XCTAssertEqual(session.codexControllerWorkspacePath, oldWorktree.path)

        session.codexEventTask?.cancel()
        session.codexEventTask = nil
        session.codexController = nil
        session.runState = .idle
        session.runID = nil
        await controller.shutdown()
    }

    func testExternalPrimaryRebindRejectsDuringActiveRunWithoutDroppingOldIdentity() async throws {
        let root = try makeTemporaryDirectory(named: "managed-active-root")
        let oldWorktree = try makeTemporaryDirectory(named: "managed-old-worktree")
        let newWorktree = try makeTemporaryDirectory(named: "managed-new-worktree")
        let viewModel = makeViewModel(workspacePath: root.path)
        let session = viewModel.session(for: UUID())
        let sessionID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.runState = .running
        session.runID = UUID()
        session.providerSessionID = "managed-old-identity"
        let oldBinding = makeBinding(logicalRoot: root.path, worktreeRoot: oldWorktree.path, worktreeID: "wt_old")
        let newBinding = makeBinding(logicalRoot: root.path, worktreeRoot: newWorktree.path, worktreeID: "wt_new")
        session.worktreeBindings = [oldBinding]

        do {
            _ = try await viewModel.transitionWorktreeBindings(
                [newBinding],
                forSessionID: sessionID,
                intent: .externalManagement
            )
            XCTFail("Active external worktree rebinding must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Stop the active Agent run"), error.localizedDescription)
        }
        XCTAssertEqual(session.worktreeBindings, [oldBinding])
        XCTAssertEqual(session.providerSessionID, "managed-old-identity")
    }

    func testAgentStartExplicitWorktreeIDOverridesInheritedBindingAcrossRunAndExplore() async throws {
        let fixture = try makeGitFixture()
        let parentWorktree = fixture.sandbox.appendingPathComponent("parent-worktree", isDirectory: true)
        let explicitWorktree = fixture.sandbox.appendingPathComponent("explicit-worktree", isDirectory: true)
        let expectedHead = try GitWorktreeTestSupport.runGit(["rev-parse", "HEAD"], cwd: fixture.repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parentBranch = "feature/parent-\(fixture.suffix)"
        let explicitBranch = "feature/explicit-\(fixture.suffix)"
        try runGit(["worktree", "add", "-b", parentBranch, parentWorktree.path, "HEAD"], cwd: fixture.repo)
        try runGit(["worktree", "add", "-b", explicitBranch, explicitWorktree.path, "HEAD"], cwd: fixture.repo)
        _ = try await GitWorktreeTestSupport.waitForStableDescriptor(
            repo: fixture.repo,
            path: parentWorktree,
            expectedBranch: parentBranch,
            expectedHead: expectedHead,
            listDescriptors: { try await VCSService.shared.listGitWorktrees(at: fixture.repo) }
        )
        let explicitDescriptor = try await GitWorktreeTestSupport.waitForStableDescriptor(
            repo: fixture.repo,
            path: explicitWorktree,
            expectedBranch: explicitBranch,
            expectedHead: expectedHead,
            listDescriptors: { try await VCSService.shared.listGitWorktrees(at: fixture.repo) }
        )
        let window = try await makeWindow(root: fixture.repo)
        let viewModel = window.agentModeViewModel
        let parentBinding = makeBinding(
            logicalRoot: fixture.repo.path,
            worktreeRoot: parentWorktree.standardizedFileURL.path,
            worktreeID: "parent-\(fixture.suffix)"
        )

        for testCase in [
            (label: "run explicit override with inheritance", inherits: true),
            (label: "run explicit override with opt out", inherits: false)
        ] {
            await window.promptManager.createBlankComposeTab(createAgentSession: false)
            let sourceTabID = try XCTUnwrap(
                window.workspaceManager.activeWorkspace?.activeComposeTabID,
                testCase.label
            )
            let parentID = UUID()
            installParentAgentSession(parentID, binding: parentBinding, sourceTabID: sourceTabID, in: window)
            let service = makeAgentRunStartService(window: window, sourceTabID: sourceTabID)
            var args: [String: Value] = [
                "op": .string("start"),
                "message": .string(testCase.label),
                "detach": .bool(true),
                "timeout": .int(0),
                "worktree_id": .string(explicitDescriptor.worktreeID)
            ]
            if !testCase.inherits {
                args["inherit_worktree"] = .bool(false)
            }

            let value: Value
            do {
                value = try await service.execute(args: args)
            } catch {
                let descriptors = await (try? VCSService.shared.listGitWorktrees(at: fixture.repo)) ?? []
                XCTFail("""
                \(testCase.label) failed after explicit worktree descriptor had stabilized: \(error.localizedDescription)
                requested_worktree_id: \(explicitDescriptor.worktreeID)
                \(GitWorktreeTestSupport.descriptorDump(
                    repo: fixture.repo,
                    expectedPath: explicitWorktree,
                    requestedID: explicitDescriptor.worktreeID,
                    descriptors: descriptors
                ))
                """)
                throw error
            }

            let object = try XCTUnwrap(value.objectValue, testCase.label)
            let sessionObject = try XCTUnwrap(object["session"]?.objectValue, testCase.label)
            let childSessionID = try XCTUnwrap(
                try UUID(uuidString: XCTUnwrap(object["session_id"]?.stringValue, testCase.label)),
                testCase.label
            )
            let childTabID = try XCTUnwrap(
                try UUID(uuidString: XCTUnwrap(sessionObject["context_id"]?.stringValue, testCase.label)),
                testCase.label
            )
            XCTAssertEqual(sessionObject["parent_session_id"]?.stringValue, parentID.uuidString, testCase.label)
            let bindings = try XCTUnwrap(object["worktree_bindings"]?.arrayValue, testCase.label)
            XCTAssertEqual(bindings.count, 1, testCase.label)
            let bindingObject = try XCTUnwrap(bindings.first?.objectValue, testCase.label)
            XCTAssertEqual(bindingObject["worktree_id"]?.stringValue, explicitDescriptor.worktreeID, testCase.label)
            XCTAssertEqual(bindingObject["worktree_root_path"]?.stringValue, explicitDescriptor.path, testCase.label)
            XCTAssertNotEqual(bindingObject["worktree_id"]?.stringValue, parentBinding.worktreeID, testCase.label)
            let child = viewModel.session(for: childTabID)
            XCTAssertEqual(child.activeAgentSessionID, childSessionID, testCase.label)
            XCTAssertEqual(child.parentSessionID, parentID, testCase.label)
            XCTAssertEqual(child.worktreeBindings.count, 1, testCase.label)
            XCTAssertEqual(child.worktreeBindings.first?.worktreeID, explicitDescriptor.worktreeID, testCase.label)
            XCTAssertEqual(child.worktreeBindings.first?.worktreeRootPath, explicitDescriptor.path, testCase.label)
            XCTAssertFalse(child.worktreeBindings.contains { $0.worktreeID == parentBinding.worktreeID }, testCase.label)
        }

        await window.promptManager.createBlankComposeTab(createAgentSession: false)
        let exploreSourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let exploreParentID = UUID()
        installParentAgentSession(
            exploreParentID,
            binding: parentBinding,
            sourceTabID: exploreSourceTabID,
            in: window
        )
        let recorder = ExploreStartRecorder()
        let exploreService = makeAgentExploreStartService(
            window: window,
            sourceTabID: exploreSourceTabID,
            recorder: recorder
        )
        _ = try await exploreService.execute(args: [
            "op": .string("start"),
            "message": .string("inspect explicit worktree"),
            "worktree_id": .string(explicitDescriptor.worktreeID),
            "detach": .bool(true),
            "timeout": .int(0)
        ])
        let observation = try XCTUnwrap(recorder.observations.first)
        XCTAssertEqual(recorder.observations.count, 1)
        let binding = try XCTUnwrap(observation.bindings.first)
        XCTAssertEqual(observation.bindings.count, 1)
        XCTAssertEqual(binding.worktreeID, explicitDescriptor.worktreeID)
        XCTAssertEqual(binding.worktreeRootPath, explicitDescriptor.path)
        XCTAssertEqual(binding.source, "agent_explore.start")
        XCTAssertNotEqual(binding.worktreeID, parentBinding.worktreeID)
        let exploreChild = viewModel.session(for: observation.tabID)
        XCTAssertEqual(exploreChild.parentSessionID, exploreParentID)
        XCTAssertEqual(exploreChild.worktreeBindings, observation.bindings)
    }

    func testSharedStartWorktreeCoordinatorHonorsPreCancelledCreateWithoutMutation() async throws {
        let fixture = try makeGitFixture()
        let window = try await makeWindow(root: fixture.repo)
        let agentModeVM = window.agentModeViewModel
        let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: nil
        )
        let coordinator = AgentMCPStartWorktreeCoordinator(
            operationName: "agent_explore.start",
            vcsService: .shared,
            gitTargetResolver: .init()
        )
        let request = try coordinator.parseRequest(args: ["worktree_create": .bool(true)])
        let preparation = Task { @MainActor in
            try await coordinator.prepare(
                request: request,
                target: target,
                targetWindow: window
            )
        }
        preparation.cancel()

        do {
            try await preparation.value
            XCTFail("A pre-cancelled start must not create or bind a worktree.")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got: \(error)")
        }

        let descriptors = try await VCSService.shared.listGitWorktrees(at: fixture.repo)
        XCTAssertTrue(descriptors.allSatisfy(\.isMain), GitWorktreeTestSupport.descriptorDump(
            repo: fixture.repo,
            expectedPath: fixture.repo,
            descriptors: descriptors
        ))
        await agentModeVM.mcpDiscardSessionTarget(target)
    }

    func testAgentExploreBatchCreatePreparesDistinctWorktreesBeforeProviderStart() async throws {
        let fixture = try makeGitFixture()
        let window = try await makeWindow(root: fixture.repo)
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let parentID = UUID()
        let source = window.agentModeViewModel.session(for: sourceTabID)
        source.testInstallPersistentSessionBinding(sessionID: parentID)
        source.mcpControlContext = makeMCPControlContext(sessionID: parentID)
        let recorder = ExploreStartRecorder()
        let service = makeAgentExploreStartService(window: window, sourceTabID: sourceTabID, recorder: recorder)

        _ = try await service.execute(args: [
            "op": .string("start"),
            "messages": .array([.string("probe one"), .string("probe two")]),
            "worktree_create": .bool(true),
            "detach": .bool(true),
            "timeout": .int(0)
        ])

        XCTAssertEqual(recorder.observations.count, 2)
        XCTAssertEqual(Set(recorder.observations.map(\.sessionID)).count, 2)
        XCTAssertEqual(Set(recorder.observations.map(\.tabID)).count, 2)
        XCTAssertTrue(recorder.observations.allSatisfy { $0.taskLabelKind == .explore && $0.workflow == nil })
        let bindings = try recorder.observations.map { try XCTUnwrap($0.bindings.first) }
        XCTAssertTrue(bindings.allSatisfy { $0.source == "agent_explore.start" })
        XCTAssertEqual(Set(bindings.map(\.worktreeID)).count, 2)
        XCTAssertEqual(Set(bindings.map(\.worktreeRootPath)).count, 2)
        XCTAssertEqual(Set(bindings.compactMap(\.branch)).count, 2)
    }

    func testAgentExploreBatchFailureAndCancellationRetainOnlyStartedChildren() async throws {
        let failureCases: [(label: String, kind: ExploreStartFailureKind)] = [
            ("provider failure", .provider),
            ("cancellation", .cancellation)
        ]

        for testCase in failureCases {
            let fixture = try makeGitFixture()
            let window = try await makeWindow(root: fixture.repo)
            let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace, testCase.label)
            let sourceTabID = try XCTUnwrap(workspace.activeComposeTabID, testCase.label)
            let parentID = UUID()
            let source = window.agentModeViewModel.session(for: sourceTabID)
            source.testInstallPersistentSessionBinding(sessionID: parentID)
            source.mcpControlContext = makeMCPControlContext(sessionID: parentID)
            let initialTabCount = workspace.composeTabs.count
            let recorder = ExploreStartRecorder(
                failureAtObservationIndex: 1,
                failureKind: testCase.kind,
                activatesControlContext: true
            )
            let service = makeAgentExploreStartService(window: window, sourceTabID: sourceTabID, recorder: recorder)

            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "messages": .array([.string("first"), .string("second"), .string("third")]),
                    "worktree_create": .bool(true),
                    "detach": .bool(true),
                    "timeout": .int(0)
                ])
                XCTFail("Expected injected second-child \(testCase.label)")
            } catch {
                switch testCase.kind {
                case .provider:
                    let message = error.localizedDescription
                    let first = try XCTUnwrap(recorder.observations.first, testCase.label)
                    XCTAssertTrue(message.contains("failed after starting 1 of 3 explore sessions"), message)
                    XCTAssertTrue(
                        message.contains("Already-started session_ids: \(first.sessionID.uuidString)"),
                        message
                    )
                    XCTAssertTrue(message.contains("Failed index: 1"), message)
                    XCTAssertTrue(message.contains("The worktree was not removed"), message)
                case .cancellation:
                    XCTAssertTrue(error is CancellationError, "Expected CancellationError, got: \(error)")
                }
            }

            XCTAssertEqual(
                recorder.observations.count,
                2,
                "The third child must never reach provider startup: \(testCase.label)"
            )
            let first = recorder.observations[0]
            let failed = recorder.observations[1]
            let firstBinding = try XCTUnwrap(first.bindings.first, testCase.label)
            let failedBinding = try XCTUnwrap(failed.bindings.first, testCase.label)
            XCTAssertEqual(firstBinding.source, "agent_explore.start", testCase.label)
            XCTAssertEqual(failedBinding.source, "agent_explore.start", testCase.label)
            XCTAssertNotEqual(firstBinding.worktreeID, failedBinding.worktreeID, testCase.label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstBinding.worktreeRootPath), testCase.label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: failedBinding.worktreeRootPath), testCase.label)

            let currentWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace, testCase.label)
            XCTAssertEqual(currentWorkspace.composeTabs.count, initialTabCount + 1, testCase.label)
            XCTAssertTrue(currentWorkspace.composeTabs.contains { $0.id == first.tabID }, testCase.label)
            XCTAssertFalse(currentWorkspace.composeTabs.contains { $0.id == failed.tabID }, testCase.label)
            let retainedSession = try XCTUnwrap(
                try window.agentModeViewModel.authoritativeLiveSession(for: first.sessionID),
                testCase.label
            )
            XCTAssertEqual(retainedSession.worktreeBindings, first.bindings, testCase.label)
            XCTAssertNil(
                try window.agentModeViewModel.authoritativeLiveSession(for: failed.sessionID),
                testCase.label
            )
        }
    }

    func testAgentExploreBatchCreateRejectsSharedPathAndBranchBeforeTargetCreation() async throws {
        let root = try makeTemporaryDirectory(named: "explore-batch-validation")
        let window = try await makeWindow(root: root)
        let sourceTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let parentID = UUID()
        let source = window.agentModeViewModel.session(for: sourceTabID)
        source.testInstallPersistentSessionBinding(sessionID: parentID)
        source.mcpControlContext = makeMCPControlContext(sessionID: parentID)

        for (field, value) in [
            ("worktree_path", Value.string(root.appendingPathComponent("shared").path)),
            ("worktree_branch", Value.string("feature/shared"))
        ] {
            let recorder = ExploreStartRecorder()
            let service = makeAgentExploreStartService(window: window, sourceTabID: sourceTabID, recorder: recorder)
            let tabCount = try XCTUnwrap(window.workspaceManager.activeWorkspace).composeTabs.count
            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "messages": .array([.string("one"), .string("two")]),
                    "worktree_create": .bool(true),
                    field: value,
                    "detach": .bool(true)
                ])
                XCTFail("Expected shared \(field) to be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(field), error.localizedDescription)
            }
            XCTAssertTrue(recorder.observations.isEmpty)
            XCTAssertEqual(window.workspaceManager.activeWorkspace?.composeTabs.count, tabCount)
        }
    }

    func testAgentExplorePreservesRestrictedStartAndControlFields() async throws {
        let root = try makeTemporaryDirectory(named: "explore-restricted-fields")
        let window = try await makeWindow(root: root)
        let service = makeAgentExploreStartService(window: window, sourceTabID: nil, recorder: ExploreStartRecorder())

        for field in ["model_id", "workflow_id", "workflow_name", "session_name", "session_id"] {
            do {
                _ = try await service.execute(args: [
                    "op": .string("start"),
                    "message": .string("restricted contract"),
                    field: .string("not-allowed")
                ])
                XCTFail("Expected agent_explore.start to reject \(field)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(field), error.localizedDescription)
            }
        }

        let worktreeArguments: [(String, Value)] = [
            ("worktree", .string("@current")),
            ("worktree_id", .string("wt_test")),
            ("worktree_create", .bool(true)),
            ("worktree_repo_root", .string(root.path)),
            ("worktree_branch", .string("feature/test")),
            ("worktree_base_ref", .string("HEAD")),
            ("worktree_path", .string(root.appendingPathComponent("worktree").path)),
            ("worktree_label", .string("Test")),
            ("worktree_color", .string("#3366FF")),
            ("allow_external_worktree_path", .bool(true)),
            ("inherit_worktree", .bool(false))
        ]
        for op in ["poll", "wait", "cancel"] {
            for (field, value) in worktreeArguments {
                let recorder = ExploreStartRecorder()
                let service = makeAgentExploreStartService(window: window, sourceTabID: nil, recorder: recorder)
                let tabCount = try XCTUnwrap(window.workspaceManager.activeWorkspace).composeTabs.count
                do {
                    _ = try await service.execute(args: [
                        "op": .string(op),
                        "session_id": .string(UUID().uuidString),
                        field: value
                    ])
                    XCTFail("Expected agent_explore \(op) to reject \(field)")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains(field), error.localizedDescription)
                }
                XCTAssertTrue(recorder.observations.isEmpty)
                XCTAssertEqual(window.workspaceManager.activeWorkspace?.composeTabs.count, tabCount)
            }
        }
    }

    #if DEBUG
        @MainActor
        private final class BootstrapSocketNamespaceFixture {
            enum FixtureError: Error {
                case defaultSocketURLWasNotProduction
                case installedSocketURLDidNotResolve
                case trackedSessionMissing
                case ownedPathWasNotSocket
                case ownedSocketDidNotAppear
                case trackedAgentTaskWasNotCleared
                case managerWasNotStopped
                case previousEnabledStateMissing
                case enabledStateWasNotRestored
                case resolvedSocketURLChangedBeforeRestore
                case productionSocketURLWasNotRestored
            }

            let productionSocketURL: URL
            let directoryURL: URL
            let socketURL: URL
            private(set) var trackedTabID: UUID?
            private(set) var trackedSession: AgentModeViewModel.TabSession?
            private(set) var firstObservedAgentTask: Task<Void, Never>?
            private(set) var acceptedSubmit = false
            private(set) var ownedSocketObserved = false
            private(set) var installStarted = false
            private(set) var cleanupStarted = false
            private(set) var cleanupFinished = false
            private(set) var overrideInstalled = false
            private var previousEnabledState: Bool?

            static func make() throws -> BootstrapSocketNamespaceFixture {
                let productionSocketURL = MCPFilesystemConstants.bootstrapSocketURL().standardizedFileURL
                let directoryURL = URL(
                    fileURLWithPath: "/tmp/rpce-xctest-bs-\(getpid())-\(UUID().uuidString)",
                    isDirectory: true
                )
                let socketURL = directoryURL.appendingPathComponent("bootstrap.sock").standardizedFileURL
                let address = sockaddr_un()
                XCTAssertLessThanOrEqual(socketURL.path.utf8CString.count, MemoryLayout.size(ofValue: address.sun_path))
                XCTAssertNotEqual(socketURL, productionSocketURL)
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return .init(productionSocketURL: productionSocketURL, directoryURL: directoryURL, socketURL: socketURL)
            }

            init(productionSocketURL: URL, directoryURL: URL, socketURL: URL) {
                self.productionSocketURL = productionSocketURL
                self.directoryURL = directoryURL
                self.socketURL = socketURL
            }

            func install() async throws {
                let manager = ServerNetworkManager.shared
                guard await manager.debugResolvedBootstrapSocketURL() == productionSocketURL else {
                    throw FixtureError.defaultSocketURLWasNotProduction
                }
                previousEnabledState = await manager.debugIsEnabledForBootstrapSocketURLOverride()
                installStarted = true
                try await manager.debugInstallBootstrapSocketURLOverride(socketURL)
                overrideInstalled = true
                guard await manager.debugResolvedBootstrapSocketURL() == socketURL else {
                    throw FixtureError.installedSocketURLDidNotResolve
                }
            }

            func track(tabID: UUID, session: AgentModeViewModel.TabSession) {
                if let trackedTabID, let trackedSession {
                    XCTAssertEqual(trackedTabID, tabID)
                    XCTAssertTrue(trackedSession === session)
                    return
                }
                trackedTabID = tabID
                trackedSession = session
            }

            func acceptedSubmitAndAwaitOwnedSocket() async throws {
                acceptedSubmit = true
                guard trackedSession != nil else {
                    throw FixtureError.trackedSessionMissing
                }
                let deadline = ContinuousClock.now + .seconds(5)
                while ContinuousClock.now < deadline {
                    observeFirstAgentTaskIfNeeded()
                    if FileManager.default.fileExists(atPath: socketURL.path) {
                        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
                        guard attributes[.type] as? FileAttributeType == .typeSocket else {
                            throw FixtureError.ownedPathWasNotSocket
                        }
                        ownedSocketObserved = true
                        return
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw FixtureError.ownedSocketDidNotAppear
            }

            func cleanup(window: WindowState) async throws {
                guard !cleanupFinished else { return }
                cleanupStarted = true
                var failures: [String] = []

                if acceptedSubmit {
                    if let trackedTabID, let trackedSession {
                        observeFirstAgentTaskIfNeeded()
                        await window.agentModeViewModel.cancelAgentRun(
                            tabID: trackedTabID,
                            completion: .terminalTeardownCompleted
                        )
                        if let firstObservedAgentTask {
                            firstObservedAgentTask.cancel()
                            await firstObservedAgentTask.value
                        }
                        if trackedSession.agentTask != nil {
                            failures.append(String(describing: FixtureError.trackedAgentTaskWasNotCleared))
                        }
                    } else {
                        failures.append(String(describing: FixtureError.trackedSessionMissing))
                    }
                }

                let manager = ServerNetworkManager.shared
                if installStarted {
                    await window.mcpServer.stopServer()
                    ServiceRegistry.unregister(window.mcpServer.windowMCPToolCatalogService)
                    await window.mcpServer.shutdownListener()

                    if await manager.isRunning() {
                        failures.append(String(describing: FixtureError.managerWasNotStopped))
                    }

                    if overrideInstalled {
                        let resolvedSocketURL = await manager.debugResolvedBootstrapSocketURL()
                        if resolvedSocketURL == socketURL {
                            do {
                                try await manager.debugRestoreBootstrapSocketURLOverride(expected: socketURL)
                                overrideInstalled = false
                            } catch {
                                failures.append("restore bootstrap socket override: \(error.localizedDescription)")
                            }
                        } else if resolvedSocketURL == productionSocketURL {
                            overrideInstalled = false
                        } else {
                            failures.append(String(describing: FixtureError.resolvedSocketURLChangedBeforeRestore))
                        }
                    }

                    if let previousEnabledState {
                        await manager.setEnabled(previousEnabledState)
                        if await manager.debugIsEnabledForBootstrapSocketURLOverride() != previousEnabledState {
                            failures.append(String(describing: FixtureError.enabledStateWasNotRestored))
                        }
                    } else {
                        failures.append(String(describing: FixtureError.previousEnabledStateMissing))
                    }

                    if await manager.isRunning() {
                        failures.append(String(describing: FixtureError.managerWasNotStopped))
                    }
                    if await manager.debugResolvedBootstrapSocketURL() != productionSocketURL {
                        failures.append(String(describing: FixtureError.productionSocketURLWasNotRestored))
                    }
                }

                if !overrideInstalled {
                    removeOwnedDirectory()
                }
                if FileManager.default.fileExists(atPath: directoryURL.path) {
                    failures.append("bootstrap namespace directory still exists: \(directoryURL.path)")
                }

                if failures.isEmpty {
                    cleanupFinished = true
                    return
                }
                throw NSError(
                    domain: "AgentRunWorktreeStartTests.BootstrapSocketNamespaceFixture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]
                )
            }

            func removeOwnedDirectory() {
                try? FileManager.default.removeItem(at: directoryURL)
            }

            private func observeFirstAgentTaskIfNeeded() {
                if firstObservedAgentTask == nil {
                    firstObservedAgentTask = trackedSession?.agentTask
                }
            }
        }
    #endif

    @MainActor
    private final class LifecycleFixture {
        private final class WindowOwnership {
            let window: WindowState
            var isRegistered = false

            init(window: WindowState) {
                self.window = window
            }
        }

        private struct BootstrapOwnership {
            let namespace: BootstrapSocketNamespaceFixture
            let window: WindowState
        }

        private let seedRepository: AgentRunWorktreeStartGitSeedRepository
        private let originalMCPAutoStart: Bool
        private var windows: [WindowOwnership] = []
        private var temporaryRoots: [URL] = []
        private var gitFixtures: [GitFixture] = []
        private var bootstrapNamespaces: [BootstrapOwnership] = []
        private var didTearDown = false

        init(seedRepository: AgentRunWorktreeStartGitSeedRepository) {
            self.seedRepository = seedRepository
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        }

        func makeTemporaryDirectory(named name: String) throws -> URL {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentRunWorktreeStartTests-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL
            temporaryRoots.append(container)
            let directory = container.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.standardizedFileURL
        }

        func makeGitFixture() throws -> GitFixture {
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentRunWorktreeStartTests-\(suffix)", isDirectory: true)
                .standardizedFileURL
            let fixture = GitFixture(
                sandbox: sandbox,
                repo: sandbox.appendingPathComponent("repo", isDirectory: true).standardizedFileURL,
                suffix: String(suffix)
            )
            gitFixtures.append(fixture)

            try FileManager.default.createDirectory(at: fixture.sandbox, withIntermediateDirectories: true)
            try seedRepository.copyRepository(to: fixture.repo)
            return fixture
        }

        func makeWindow(root: URL) async throws -> WindowState {
            let window = WindowState()
            let ownership = WindowOwnership(window: window)
            windows.append(ownership)
            WindowStatesManager.shared.registerWindowState(window)
            ownership.isRegistered = true

            let workspace = window.workspaceManager.createWorkspace(
                name: "Agent Run Worktree Start \(UUID().uuidString.prefix(8))",
                repoPaths: [root.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentRunWorktreeStartTests"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
            _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
                in: window,
                path: root.path
            )
            return window
        }

        func makeBootstrapNamespace(window: WindowState) throws -> BootstrapSocketNamespaceFixture {
            let namespace = try BootstrapSocketNamespaceFixture.make()
            bootstrapNamespaces.append(.init(namespace: namespace, window: window))
            return namespace
        }

        func tearDown() async -> [String] {
            guard !didTearDown else { return [] }
            didTearDown = true
            var failures: [String] = []

            for ownership in bootstrapNamespaces.reversed() {
                do {
                    try await ownership.namespace.cleanup(window: ownership.window)
                } catch {
                    failures.append("bootstrap namespace \(ownership.namespace.directoryURL.path): \(error.localizedDescription)")
                }
            }

            for ownership in windows.reversed() {
                let viewModel = ownership.window.agentModeViewModel
                let activeTabIDs = viewModel.sessions.values
                    .filter { $0.agentTask != nil || $0.runState.isActive }
                    .map(\.tabID)
                    .sorted { $0.uuidString < $1.uuidString }
                for tabID in activeTabIDs {
                    await viewModel.cancelAgentRun(
                        tabID: tabID,
                        completion: .terminalTeardownCompleted
                    )
                }
            }

            for ownership in windows.reversed() {
                let window = ownership.window
                window.beginClose()
                await window.tearDown()
                if ownership.isRegistered {
                    WindowStatesManager.shared.unregisterWindowState(window)
                    ownership.isRegistered = false
                }
                if WindowStatesManager.shared.allWindows.contains(where: { $0 === window }) {
                    failures.append("window remained globally registered: \(window.windowID)")
                }
                let activeSessions = window.agentModeViewModel.sessions.values.filter {
                    $0.agentTask != nil || $0.runState.isActive
                }
                if !activeSessions.isEmpty {
                    failures.append("window \(window.windowID) retained \(activeSessions.count) active agent session(s)")
                }
            }

            for fixture in gitFixtures.reversed() {
                cleanupGitFixture(fixture, failures: &failures)
            }

            for root in temporaryRoots.reversed() {
                removeItemIfPresent(root, label: "temporary root", failures: &failures)
            }

            for ownership in bootstrapNamespaces.reversed()
                where FileManager.default.fileExists(atPath: ownership.namespace.directoryURL.path)
            {
                failures.append("bootstrap namespace directory leaked: \(ownership.namespace.directoryURL.path)")
            }

            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            if GlobalSettingsStore.shared.mcpAutoStart() != originalMCPAutoStart {
                failures.append("GlobalSettingsStore MCP auto-start setting was not restored")
            }

            return failures
        }

        private func cleanupGitFixture(_ fixture: GitFixture, failures: inout [String]) {
            var linkedWorktreePaths: [URL] = []
            if FileManager.default.fileExists(atPath: fixture.repo.path) {
                do {
                    let output = try GitWorktreeTestSupport.runGit(
                        ["worktree", "list", "--porcelain"],
                        cwd: fixture.repo
                    )
                    linkedWorktreePaths = output
                        .split(separator: "\n")
                        .compactMap { line -> URL? in
                            let prefix = "worktree "
                            guard line.hasPrefix(prefix) else { return nil }
                            return URL(fileURLWithPath: String(line.dropFirst(prefix.count))).standardizedFileURL
                        }
                        .filter { $0.path != fixture.repo.path }
                } catch {
                    failures.append("list Git worktrees in \(fixture.repo.path): \(error.localizedDescription)")
                }

                for worktree in linkedWorktreePaths.reversed() {
                    guard isDescendant(worktree, of: fixture.sandbox) else {
                        failures.append("refused to remove linked worktree outside fixture sandbox: \(worktree.path)")
                        continue
                    }
                    do {
                        _ = try GitWorktreeTestSupport.runGit(
                            ["worktree", "remove", "--force", worktree.path],
                            cwd: fixture.repo
                        )
                    } catch {
                        failures.append("remove linked worktree \(worktree.path): \(error.localizedDescription)")
                    }
                }

                do {
                    _ = try GitWorktreeTestSupport.runGit(["worktree", "prune"], cwd: fixture.repo)
                } catch {
                    failures.append("prune Git worktrees in \(fixture.repo.path): \(error.localizedDescription)")
                }
            }

            removeItemIfPresent(fixture.sandbox, label: "Git fixture sandbox", failures: &failures)
            for worktree in linkedWorktreePaths where isDescendant(worktree, of: fixture.sandbox) {
                if FileManager.default.fileExists(atPath: worktree.path) {
                    failures.append("linked worktree path leaked: \(worktree.path)")
                }
            }
        }

        private func removeItemIfPresent(_ url: URL, label: String, failures: inout [String]) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append("remove \(label) \(url.path): \(error.localizedDescription)")
            }
            if FileManager.default.fileExists(atPath: url.path) {
                failures.append("\(label) leaked: \(url.path)")
            }
        }

        private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
            let candidatePath = candidate.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
        }
    }

    private func withIsolatedBootstrapSocketNamespace(
        window: WindowState,
        operation: (BootstrapSocketNamespaceFixture) async throws -> Void
    ) async throws {
        #if DEBUG
            let namespace = try lifecycleFixture.makeBootstrapNamespace(window: window)
            do {
                try await namespace.install()
                try await operation(namespace)
            } catch {
                let operationError = error
                do {
                    try await namespace.cleanup(window: window)
                } catch {
                    XCTFail("Failed to contain isolated Agent Run bootstrap socket namespace: \(error)")
                }
                throw operationError
            }
            try await namespace.cleanup(window: window)
        #else
            throw XCTSkip("Bootstrap socket URL override seam is DEBUG-only")
        #endif
    }

    private enum ExploreStartFailureKind {
        case provider
        case cancellation
    }

    private final class ExploreStartRecorder {
        struct Observation {
            let sessionID: UUID
            let tabID: UUID
            let message: String
            let taskLabelKind: AgentModelCatalog.TaskLabelKind?
            let workflow: AgentWorkflowDefinition?
            let bindings: [AgentSessionWorktreeBinding]
        }

        let failureAtObservationIndex: Int?
        let failureKind: ExploreStartFailureKind
        let activatesControlContext: Bool
        var observations: [Observation] = []

        init(
            failureAtObservationIndex: Int? = nil,
            failureKind: ExploreStartFailureKind = .provider,
            activatesControlContext: Bool = false
        ) {
            self.failureAtObservationIndex = failureAtObservationIndex
            self.failureKind = failureKind
            self.activatesControlContext = activatesControlContext
        }
    }

    private func makeAgentExploreStartService(
        window: WindowState,
        sourceTabID: UUID?,
        recorder: ExploreStartRecorder
    ) -> AgentExploreMCPToolService {
        AgentExploreMCPToolService(
            toolName: MCPWindowToolName.agentExplore,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: nil,
                    clientName: "agent-explore-worktree-start",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in sourceTabID },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, message, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, taskLabelKind, workflow, _, _ in
                guard let sessionID = target.sessionID else {
                    throw MCPError.internalError("Test explore target did not resolve a session ID.")
                }
                let bindings = agentModeVM.worktreeBindings(forAgentSessionID: sessionID, tabID: target.tabID)
                let session = agentModeVM.session(for: target.tabID)
                if recorder.activatesControlContext {
                    try await agentModeVM.mcpActivateControlContext(
                        forTabID: target.tabID,
                        sessionID: sessionID,
                        originatingConnectionID: nil,
                        taskLabelKind: taskLabelKind,
                        startPending: true
                    )
                }
                let observationIndex = recorder.observations.count
                recorder.observations.append(
                    .init(
                        sessionID: sessionID,
                        tabID: target.tabID,
                        message: message,
                        taskLabelKind: taskLabelKind,
                        workflow: workflow,
                        bindings: bindings
                    )
                )
                if recorder.failureAtObservationIndex == observationIndex {
                    if recorder.activatesControlContext {
                        await agentModeVM.mcpDeactivateControlContext(
                            sessionID: sessionID,
                            cleanupSessionStore: true
                        )
                    }
                    switch recorder.failureKind {
                    case .provider:
                        throw MCPError.internalError("Injected explore provider start failure at index \(observationIndex).")
                    case .cancellation:
                        throw CancellationError()
                    }
                }
                let snapshot = AgentRunMCPSnapshot(
                    sessionID: sessionID,
                    tabID: target.tabID,
                    sessionName: "Explore Worktree Start Test",
                    agentRaw: agentRaw,
                    agentDisplayName: agentRaw.flatMap { AgentProviderKind(rawValue: $0)?.displayName },
                    modelRaw: modelRaw,
                    reasoningEffortRaw: reasoningEffortRaw,
                    status: .running,
                    statusText: "Test harness running",
                    latestAssistantPreview: nil,
                    interaction: nil,
                    transcriptItemCount: 0,
                    updatedAt: Date(),
                    parentSessionID: session.parentSessionID,
                    failureReason: nil,
                    worktreeBindings: bindings.map { AgentRunMCPSnapshot.WorktreeBinding(binding: $0) },
                    activeWorktreeMerges: []
                )
                return AgentExternalMCPRunStarter.StartOutcome(snapshot: snapshot, delivery: .startedRun)
            }
        )
    }

    private func makeAgentRunStartService(window: WindowState, sourceTabID: UUID?) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: "agent-run-worktree-start", windowID: window.windowID)
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in sourceTabID },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, _, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, _, _, _, _ in
                guard let sessionID = target.sessionID else {
                    throw MCPError.internalError("Test start target did not resolve a session ID.")
                }
                let bindings = agentModeVM.worktreeBindings(forAgentSessionID: sessionID, tabID: target.tabID)
                let session = agentModeVM.session(for: target.tabID)
                let snapshot = AgentRunMCPSnapshot(
                    sessionID: sessionID,
                    tabID: target.tabID,
                    sessionName: "Worktree Start Test",
                    agentRaw: agentRaw,
                    agentDisplayName: agentRaw.flatMap { AgentProviderKind(rawValue: $0)?.displayName },
                    modelRaw: modelRaw,
                    reasoningEffortRaw: reasoningEffortRaw,
                    status: .running,
                    statusText: "Test harness running",
                    latestAssistantPreview: nil,
                    interaction: nil,
                    transcriptItemCount: 0,
                    updatedAt: Date(),
                    parentSessionID: session.parentSessionID,
                    failureReason: nil,
                    worktreeBindings: bindings.map { AgentRunMCPSnapshot.WorktreeBinding(binding: $0) },
                    activeWorktreeMerges: []
                )
                return AgentExternalMCPRunStarter.StartOutcome(snapshot: snapshot, delivery: .startedRun)
            }
        )
        service.resolveOracleReviewLaunchSource = { _, targetWindow in
            let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
            let packagingTabID = try XCTUnwrap(sourceTabID ?? workspace.activeComposeTabID)
            let sourceSessionID = targetWindow.agentModeViewModel
                .session(for: packagingTabID)
                .activeAgentSessionID
            let snapshot = AgentRunOracleReviewLaunchSnapshot(
                route: sourceTabID == nil ? .windowOnlyActiveCompose : .runScoped,
                windowID: targetWindow.windowID,
                workspaceID: workspace.id,
                tabID: packagingTabID,
                selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                    workspaceID: workspace.id,
                    tabID: packagingTabID
                ),
                promptText: "",
                selection: StoredSelection(),
                sourceAgentSessionID: sourceSessionID,
                routedRunID: nil
            )
            return ResolvedAgentRunOracleReviewLaunchSource(
                snapshot: snapshot,
                source: .unavailable(.init(
                    delegationID: UUID(),
                    sourceTabID: packagingTabID,
                    workspaceID: workspace.id,
                    sourceAgentSessionID: sourceSessionID,
                    sourceAgentRunID: nil,
                    reason: .sourceCaptureFailed("Synthetic start-service fixture")
                ))
            )
        }
        service.resolveSpawnParentSessionIDFromSourceTabID = { (sourceTabID: UUID, window: WindowState) async -> UUID? in
            window.agentModeViewModel.mcpSpawnParentSessionID(sourceTabID: sourceTabID)
        }
        return service
    }

    private func installParentAgentSession(
        _ parentID: UUID,
        binding: AgentSessionWorktreeBinding,
        sourceTabID: UUID,
        in window: WindowState
    ) {
        let source = window.agentModeViewModel.session(for: sourceTabID)
        source.testInstallPersistentSessionBinding(sessionID: parentID)
        source.mcpControlContext = makeMCPControlContext(sessionID: parentID)
        source.worktreeBindings = [binding]
    }

    private func makeMCPControlContext(
        sessionID: UUID,
        taskLabelKind: AgentModelCatalog.TaskLabelKind = .pair
    ) -> AgentModeViewModel.AgentMCPControlContext {
        AgentModeViewModel.AgentMCPControlContext(
            sessionID: sessionID,
            activationID: UUID(),
            registration: .init(sessionID: sessionID, generation: 0),
            currentEpoch: nil,
            preparedEpoch: nil,
            pendingEpochTransition: nil,
            originatingConnectionID: nil,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
            suppressUserNotifications: false,
            forceAutoEditEnabled: false,
            autoEditEnabledBeforeOverride: true,
            taskLabelKind: taskLabelKind
        )
    }

    private struct GitFixture {
        let sandbox: URL
        let repo: URL
        let suffix: String
    }

    private func makeGitFixture() throws -> GitFixture {
        try lifecycleFixture.makeGitFixture()
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: cwd,
            environment: environment
        )
        guard result.terminationStatus == 0 else {
            throw NSError(
                domain: "AgentRunWorktreeStartTests.git",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.outputText)"]
            )
        }
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    private func waitForCodemapSnapshot(
        store: WorkspaceFileContextStore,
        fileID: UUID,
        timeout: Duration = .seconds(6)
    ) async throws -> WorkspaceCodemapSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let snapshot = await store.codemapSnapshot(fileID: fileID) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for codemap snapshot")
        throw NSError(domain: "AgentRunWorktreeStartTests", code: 1)
    }

    private func makeWindow(root: URL) async throws -> WindowState {
        try await lifecycleFixture.makeWindow(root: root)
    }

    private func makeViewModel(workspacePath: String) -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspacePath: workspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in WorktreeStartFakeCodexController() }
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        try lifecycleFixture.makeTemporaryDirectory(named: name)
    }

    private func makeBinding(
        logicalRoot: String,
        worktreeRoot: String,
        worktreeID: String = "wt_test",
        label: String? = nil
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(UUID().uuidString)",
            repositoryID: "gitrepo_test",
            repoKey: "test",
            logicalRootPath: logicalRoot,
            logicalRootName: "root",
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRoot,
            worktreeName: "worktree",
            branch: "feature/test",
            visualLabel: label,
            visualColorHex: "#3366FF",
            source: "test"
        )
    }
}

private class WorktreeStartFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "fake", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "fake",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}

private final class LiveSwitchWorktreeStartFakeCodexController: WorktreeStartFakeCodexController {
    private var eventContinuations: [AsyncStream<CodexNativeSessionController.Event>.Continuation] = []
    private(set) var shutdownCount = 0

    override var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in
            eventContinuations.append(continuation)
        }
    }

    override func shutdown() async {
        shutdownCount += 1
        eventContinuations.forEach { $0.finish() }
        eventContinuations.removeAll()
    }
}
