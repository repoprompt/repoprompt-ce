import CoreServices
import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class WorktreeAPISmokeHarnessTests: XCTestCase {
    func testManageWorktreeAndAgentRunAPISmokeFlow() async throws {
        let fixture = try Self.makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        let window = try await Self.makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)

        let graphList = try await manageWorktree([
            "op": .string("list"),
            "include_graph": .bool(true),
            "graph_limit": .int(8),
            "persist_visuals": .bool(true)
        ])
        try assertManageWorktreeGraphListContract(graphList)

        let createValue = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/item12-create-\(fixture.suffix)"),
            "base_ref": .string("HEAD"),
            "label": .string("Item 12 Create"),
            "color": .string("#2563EB"),
            "include_status": .bool(true)
        ])
        let createdWorktree = try Self.worktreeObject(createValue, key: "created_worktree")
        let createdWorktreeID = try XCTUnwrap(createdWorktree["worktree_id"]?.stringValue)
        let createdWorktreePath = try XCTUnwrap(createdWorktree["path"]?.stringValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdWorktreePath), createdWorktreePath)

        let bindSessionID = UUID()
        let bindTabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let bindSession = window.agentModeViewModel.session(for: bindTabID)
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: bindSessionID,
            on: bindSession,
            updateWorkspaceMetadata: true
        )
        XCTAssertEqual(window.workspaceManager.activeAgentSessionID(forTabID: bindTabID), bindSessionID)

        let bindValue = try await manageWorktree([
            "op": .string("bind"),
            "worktree_id": .string(createdWorktreeID),
            "session_id": .string(bindSessionID.uuidString),
            "label": .string("Bound Item 12"),
            "color": .string("#7C3AED")
        ])
        let binding = try Self.object(bindValue, key: "binding")
        XCTAssertEqual(binding["worktree_id"]?.stringValue, createdWorktreeID)
        XCTAssertEqual(binding["worktree_root_path"]?.stringValue, createdWorktreePath)
        XCTAssertEqual(binding["logical_root_path"]?.stringValue, fixture.repo.path)
        XCTAssertEqual(binding["visual_label"]?.stringValue, "Bound Item 12")

        try await assertDiscoveryToolsReportWorktreeScope(
            window: window,
            logicalRootPath: fixture.repo.path,
            effectiveRootPath: createdWorktreePath,
            worktreeID: createdWorktreeID
        )

        let existingStartTab = try await Self.createBackgroundTab(in: window, name: "Item 12 Existing Start")
        let existingStart = try await Self.makeAgentRunService(window: window, targetTabID: existingStartTab.id).execute(args: [
            "op": .string("start"),
            "message": .string("Smoke existing worktree binding"),
            "detach": .bool(true),
            "timeout": .int(0),
            "worktree_id": .string(createdWorktreeID),
            "worktree_label": .string("Agent Existing WT"),
            "worktree_color": .string("#0EA5E9")
        ])
        let existingStartBinding = try Self.firstWorktreeBinding(existingStart)
        XCTAssertEqual(existingStartBinding["worktree_id"]?.stringValue, createdWorktreeID)
        XCTAssertEqual(existingStartBinding["worktree_root_path"]?.stringValue, createdWorktreePath)
        try await assertBoundSessionReadAndApplyUseWorktree(
            value: existingStart,
            window: window,
            logicalRoot: fixture.repo,
            originalTrackedFile: fixture.trackedFile
        )

        let createStartTab = try await Self.createBackgroundTab(in: window, name: "Item 12 Create Start")
        let createStart = try await Self.makeAgentRunService(window: window, targetTabID: createStartTab.id).execute(args: [
            "op": .string("start"),
            "message": .string("Smoke created worktree binding"),
            "detach": .bool(true),
            "timeout": .int(0),
            "worktree_create": .bool(true),
            "worktree_branch": .string("feature/item12-agent-\(fixture.suffix)"),
            "worktree_base_ref": .string("HEAD"),
            "worktree_label": .string("Agent Created WT"),
            "worktree_color": .string("#16A34A")
        ])
        let createStartBinding = try Self.firstWorktreeBinding(createStart)
        XCTAssertNotNil(createStartBinding["worktree_id"]?.stringValue)
        XCTAssertEqual(createStartBinding["visual_label"]?.stringValue, "Agent Created WT")
        let createStartPath = try XCTUnwrap(createStartBinding["worktree_root_path"]?.stringValue)
        XCTAssertNotEqual(createStartPath, fixture.repo.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createStartPath), createStartPath)

        let formattedList = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: ["op": .string("list")], value: graphList))
        XCTAssertTrue(formattedList.contains("## Manage Worktree List"), formattedList)
        XCTAssertTrue(formattedList.contains("### Commit / Worktree Graph"), formattedList)
        XCTAssertTrue(formattedList.contains("bounded to 8 lines"), formattedList)

        let formattedStart = try Self.onlyText(ToolOutputFormatter.formatAgentRun(args: ["op": .string("start")], value: createStart))
        XCTAssertTrue(formattedStart.contains("Worktree:"), formattedStart)
        XCTAssertTrue(formattedStart.contains("Agent Created WT"), formattedStart)
    }

    func testManageWorktreeRetirementPublicPrepareApplyAndEvidenceReadback() async throws {
        let fixture = try Self.makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        let authority = GitWorktreeRetirementAuthority(
            persistenceURL: fixture.sandbox.appendingPathComponent("retirement-authority/state.json")
        )
        GitWorktreeRetirementAuthority.setOperationalAuthorityForTesting(authority)
        GitWorktreeRetirementActivation.setEnabledForTesting(false)
        defer {
            GitWorktreeRetirementActivation.setEnabledForTesting(false)
            GitWorktreeRetirementAuthority.setOperationalAuthorityForTesting(nil)
        }

        let window = try await Self.makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)
        let createValue = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/retire-\(fixture.suffix)"),
            "base_ref": .string("HEAD")
        ])
        let created = try Self.worktreeObject(createValue, key: "created_worktree")
        let worktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
        let path = try XCTUnwrap(created["path"]?.stringValue)

        do {
            _ = try await manageWorktree([
                "op": .string("retire"),
                "worktree_id": .string(worktreeID)
            ])
            XCTFail("Retirement must be default-off")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("activation"), error.localizedDescription)
        }

        GitWorktreeRetirementActivation.setEnabledForTesting(true)
        let ancestorAlias = fixture.sandbox.appendingPathComponent("symlink-spelled-ancestor", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: ancestorAlias,
            withDestinationURL: fixture.sandbox
        )
        let ancestorRoot = try await window.workspaceFileContextStore.loadRoot(path: ancestorAlias.path)
        XCTAssertNotEqual(
            ancestorRoot.standardizedFullPath,
            GitWorktreeRetirementAuthority.canonicalWorkspacePath(ancestorRoot.standardizedFullPath)
        )
        XCTAssertEqual(
            GitWorktreeRetirementAuthority.canonicalWorkspacePath(ancestorRoot.standardizedFullPath),
            GitWorktreeRetirementAuthority.canonicalWorkspacePath(fixture.sandbox.path)
        )
        let nestedRoot = try await window.workspaceFileContextStore.loadRoot(
            path: URL(fileURLWithPath: path).appendingPathComponent("Nested", isDirectory: true).path
        )
        let preparedValue = try await manageWorktree([
            "op": .string("retire"),
            "worktree_id": .string(worktreeID)
        ])
        let prepared = try Self.object(preparedValue, key: "retirement")
        XCTAssertEqual(prepared["state"]?.stringValue, "authorized")
        XCTAssertEqual(prepared["worktree_id"]?.stringValue, worktreeID)
        let rootsAfterPrepare = await window.workspaceFileContextStore.rootRefs(scope: .allLoaded)
        XCTAssertFalse(rootsAfterPrepare.contains { $0.id == ancestorRoot.id })
        XCTAssertFalse(rootsAfterPrepare.contains { $0.id == nestedRoot.id })
        let token = try XCTUnwrap(prepared["authorization_token"]?.stringValue)

        do {
            _ = try await manageWorktree([
                "op": .string("retire"),
                "authorization_token": .string("retire_wrong")
            ])
            XCTFail("Wrong token must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("authorization"))
        }
        do {
            _ = try await manageWorktree([
                "op": .string("retire"),
                "authorization_token": .string(token),
                "worktree_id": .string("wt_wrong")
            ])
            XCTFail("Wrong worktree selector must not consume authorization")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sealed retirement target"))
        }
        do {
            _ = try await manageWorktree([
                "op": .string("retire"),
                "authorization_token": .string(token),
                "repo_root": .string(fixture.sandbox.path)
            ])
            XCTFail("Wrong repository selector must not consume authorization")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("repository sealed"))
        }

        let appliedValue = try await manageWorktree([
            "op": .string("retire"),
            "authorization_token": .string(token),
            "worktree_id": .string(worktreeID)
        ])
        let applied = try Self.object(appliedValue, key: "retirement")
        XCTAssertEqual(applied["state"]?.stringValue, "retired")
        XCTAssertEqual(applied["git_absent"]?.boolValue, true)
        XCTAssertEqual(applied["path_absent"]?.boolValue, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let evidence = try XCTUnwrap(applied["evidence"]?.objectValue)
        XCTAssertNotNil(evidence["evidence_id"]?.stringValue)
        XCTAssertEqual(evidence["state"]?.stringValue, "retired")
        XCTAssertEqual(evidence["operation_version"]?.intValue, 4)

        let readbackValue = try await manageWorktree([
            "op": .string("retire"),
            "authorization_token": .string(token),
            "worktree_id": .string(worktreeID)
        ])
        let readback = try Self.object(readbackValue, key: "retirement")
        XCTAssertEqual(readback["state"]?.stringValue, "retired")
        XCTAssertEqual(
            readback["evidence"]?.objectValue?["evidence_id"]?.stringValue,
            evidence["evidence_id"]?.stringValue
        )
    }

    func testManageWorktreeRetirementDrainTimeoutReopensAdmissionForCleanRetry() async throws {
        #if DEBUG
            let fixture = try Self.makeGitFixture()
            defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
            let authority = GitWorktreeRetirementAuthority(
                persistenceURL: fixture.sandbox.appendingPathComponent("retirement-authority/state.json")
            )
            GitWorktreeRetirementAuthority.setOperationalAuthorityForTesting(authority)
            GitWorktreeRetirementActivation.setEnabledForTesting(true)
            defer {
                GitWorktreeRetirementActivation.setEnabledForTesting(false)
                GitWorktreeRetirementAuthority.setOperationalAuthorityForTesting(nil)
            }

            let window = try await Self.makeWindow(root: fixture.repo)
            defer {
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)
            let createValue = try await manageWorktree([
                "op": .string("create"),
                "branch": .string("feature/drain-retry-\(fixture.suffix)"),
                "base_ref": .string("HEAD")
            ])
            let created = try Self.worktreeObject(createValue, key: "created_worktree")
            let worktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
            let worktreePath = try XCTUnwrap(created["path"]?.stringValue)
            let nestedPath = URL(fileURLWithPath: worktreePath)
                .appendingPathComponent("Nested", isDirectory: true).path
            let publicationGate = WorktreeRetirementAsyncGate()
            await window.workspaceFileContextStore.setRootLoadWillPublishHandler { path in
                guard GitWorktreeRetirementAuthority.workspacePathsIntersect(path, worktreePath) else {
                    return
                }
                await publicationGate.enterAndWait()
            }
            await window.workspaceFileContextStore
                .setWorktreeRetirementWorkspaceDrainTimeoutForTesting(.milliseconds(50))
            addTeardownBlock {
                await publicationGate.release()
                await window.workspaceFileContextStore.setRootLoadWillPublishHandler(nil)
                await window.workspaceFileContextStore
                    .setWorktreeRetirementWorkspaceDrainTimeoutForTesting(nil)
            }

            let loadTask = Task {
                try await window.workspaceFileContextStore.loadRoot(path: nestedPath)
            }
            await publicationGate.waitUntilEntered()

            do {
                _ = try await manageWorktree([
                    "op": .string("retire"),
                    "worktree_id": .string(worktreeID)
                ])
                XCTFail("Paused prepublication flight must force a bounded retryable timeout.")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("safely reopened without permanent residue"),
                    error.localizedDescription
                )
            }
            XCTAssertNil(try authority.evidence(worktreeID: worktreeID))

            await publicationGate.release()
            do {
                _ = try await loadTask.value
                XCTFail("Timed-out drain must leave the cancelled flight unable to publish.")
            } catch is CancellationError {
                // Expected.
            }
            await window.workspaceFileContextStore.setRootLoadWillPublishHandler(nil)
            await window.workspaceFileContextStore
                .setWorktreeRetirementWorkspaceDrainTimeoutForTesting(nil)

            let retriedValue = try await manageWorktree([
                "op": .string("retire"),
                "worktree_id": .string(worktreeID)
            ])
            let retried = try Self.object(retriedValue, key: "retirement")
            XCTAssertEqual(retried["state"]?.stringValue, "authorized")
            let token = try XCTUnwrap(retried["authorization_token"]?.stringValue)
            let appliedValue = try await manageWorktree([
                "op": .string("retire"),
                "authorization_token": .string(token),
                "worktree_id": .string(worktreeID)
            ])
            XCTAssertEqual(
                try Self.object(appliedValue, key: "retirement")["state"]?.stringValue,
                "retired"
            )
        #else
            throw XCTSkip("Retirement drain timeout injection is DEBUG-only.")
        #endif
    }

    func testManageWorktreeHostCleanupAuthorizationCompletesIntoRetirement() async throws {
        let fixture = try Self.makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        let stateURL = fixture.sandbox.appendingPathComponent("retirement-authority/state.json")
        let authority = GitWorktreeRetirementAuthority(persistenceURL: stateURL)
        GitWorktreeRetirementAuthority.setOperationalAuthorityForTesting(authority)
        GitWorktreeRetirementActivation.setEnabledForTesting(true)
        defer {
            GitWorktreeRetirementActivation.setEnabledForTesting(false)
            GitWorktreeRetirementAuthority.setOperationalAuthorityForTesting(nil)
        }

        try "*.cleanup-cache\n".write(
            to: fixture.repo.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try Self.runGit(["add", ".gitignore"], cwd: fixture.repo)
        try Self.runGit(["commit", "-m", "Ignore host cleanup cache"], cwd: fixture.repo)

        let window = try await Self.makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)
        let createValue = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/cleanup-auth-\(fixture.suffix)"),
            "base_ref": .string("HEAD")
        ])
        let created = try Self.worktreeObject(createValue, key: "created_worktree")
        let worktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
        let path = try XCTUnwrap(created["path"]?.stringValue)
        let ignored = URL(fileURLWithPath: path).appendingPathComponent("bulk.cleanup-cache")
        try "ignored\n".write(to: ignored, atomically: true, encoding: .utf8)

        let preparedValue = try await manageWorktree([
            "op": .string("retire"),
            "retirement_action": .string("prepare_cleanup"),
            "cleanup_manifest_digest": .string(String(repeating: "c", count: 64)),
            "worktree_id": .string(worktreeID)
        ])
        let prepared = try Self.object(preparedValue, key: "retirement")
        XCTAssertEqual(prepared["state"]?.stringValue, "cleanup_authorized")
        let cleanupToken = try XCTUnwrap(prepared["cleanup_authorization_token"]?.stringValue)
        XCTAssertThrowsError(try authority.acquireMutationLease(paths: [path]))

        let state = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        XCTAssertEqual(state["schemaLineage"] as? String, "repoprompt.git-worktree-retirement")
        let records = try XCTUnwrap(state["recordsByWorktreeID"] as? [String: Any])
        let record = try XCTUnwrap(records[worktreeID] as? [String: Any])
        let cleanupCase = try XCTUnwrap(record["cleanupAuthorized"] as? [String: Any])
        let receipt = try XCTUnwrap(cleanupCase["_0"] as? [String: Any])
        XCTAssertEqual(
            receipt["tokenDigest"] as? String,
            GitWorktreeRetirementTarget.digest(cleanupToken)
        )
        XCTAssertEqual(receipt["cleanupManifestDigest"] as? String, String(repeating: "c", count: 64))
        let target = try XCTUnwrap(receipt["target"] as? [String: Any])
        let candidate = try XCTUnwrap(target["candidate"] as? [String: Any])
        XCTAssertEqual(candidate["worktreeID"] as? String, worktreeID)
        XCTAssertEqual(candidate["registeredPath"] as? String, path)

        try FileManager.default.removeItem(at: ignored)
        let completedValue = try await manageWorktree([
            "op": .string("retire"),
            "retirement_action": .string("complete_cleanup"),
            "cleanup_authorization_token": .string(cleanupToken),
            "cleanup_manifest_digest": .string(String(repeating: "c", count: 64)),
            "worktree_id": .string(worktreeID)
        ])
        let completed = try Self.object(completedValue, key: "retirement")
        XCTAssertEqual(completed["state"]?.stringValue, "authorized")
        XCTAssertEqual(completed["authorization_token"]?.stringValue, cleanupToken)
        do {
            _ = try await manageWorktree([
                "op": .string("retire"),
                "retirement_action": .string("complete_cleanup"),
                "cleanup_authorization_token": .string(cleanupToken),
                "cleanup_manifest_digest": .string(String(repeating: "d", count: 64)),
                "worktree_id": .string(worktreeID)
            ])
            XCTFail("A completed cleanup authorization must reject readback with a different manifest digest.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not match"), error.localizedDescription)
        }

        let appliedValue = try await manageWorktree([
            "op": .string("retire"),
            "authorization_token": .string(cleanupToken),
            "worktree_id": .string(worktreeID)
        ])
        let applied = try Self.object(appliedValue, key: "retirement")
        XCTAssertEqual(applied["state"]?.stringValue, "retired")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testManageWorktreeRetirementReturnsBlockedEvidenceBeforeTokenAndAfterApplyRace() async throws {
        let fixture = try Self.makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        let authority = GitWorktreeRetirementAuthority(
            persistenceURL: fixture.sandbox.appendingPathComponent("retirement-authority/state.json")
        )
        GitWorktreeRetirementAuthority.setOperationalAuthorityForTesting(authority)
        GitWorktreeRetirementActivation.setEnabledForTesting(true)
        defer {
            GitWorktreeRetirementActivation.setEnabledForTesting(false)
            GitWorktreeRetirementAuthority.setOperationalAuthorityForTesting(nil)
        }

        let window = try await Self.makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)

        let blockedCreate = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/pretoken-residue-\(fixture.suffix)"),
            "base_ref": .string("HEAD")
        ])
        let blockedWorktree = try Self.worktreeObject(blockedCreate, key: "created_worktree")
        let blockedID = try XCTUnwrap(blockedWorktree["worktree_id"]?.stringValue)
        let git = GitService()
        let descriptors = try await git.listWorktrees(at: fixture.repo)
        let blockedDescriptor = try XCTUnwrap(descriptors.first { $0.worktreeID == blockedID })
        let blockedTarget = try await git.inspectRetirementTarget(descriptor: blockedDescriptor, generation: 0)
        let preparation = try authority.begin(blockedTarget.candidate)
        let blockedEvidence = try authority.blockPreparation(
            preparation,
            reason: "injected preparation residue"
        )
        XCTAssertEqual(blockedEvidence.state, .blockedResidue)

        let preTokenReadbackValue = try await manageWorktree([
            "op": .string("retire"),
            "worktree_id": .string(blockedID)
        ])
        let preTokenReadback = try Self.object(preTokenReadbackValue, key: "retirement")
        XCTAssertEqual(preTokenReadback["state"]?.stringValue, "blocked_residue")
        XCTAssertNil(preTokenReadback["authorization_token"])
        XCTAssertEqual(
            preTokenReadback["evidence"]?.objectValue?["evidence_id"]?.stringValue,
            blockedEvidence.evidenceID
        )

        let racedCreate = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/apply-race-\(fixture.suffix)"),
            "base_ref": .string("HEAD")
        ])
        let racedWorktree = try Self.worktreeObject(racedCreate, key: "created_worktree")
        let racedID = try XCTUnwrap(racedWorktree["worktree_id"]?.stringValue)
        let racedPath = try XCTUnwrap(racedWorktree["path"]?.stringValue)
        let preparedValue = try await manageWorktree([
            "op": .string("retire"),
            "worktree_id": .string(racedID)
        ])
        let token = try XCTUnwrap(
            Self.object(preparedValue, key: "retirement")["authorization_token"]?.stringValue
        )
        try "race\n".write(
            to: URL(fileURLWithPath: racedPath).appendingPathComponent("race.txt"),
            atomically: true,
            encoding: .utf8
        )
        let racedApplyValue = try await manageWorktree([
            "op": .string("retire"),
            "authorization_token": .string(token),
            "worktree_id": .string(racedID)
        ])
        let racedApply = try Self.object(racedApplyValue, key: "retirement")
        XCTAssertEqual(racedApply["state"]?.stringValue, "blocked_residue")
        XCTAssertNotNil(racedApply["evidence"]?.objectValue?["reason"]?.stringValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: racedPath))
    }

    func testPromptExportLeaseDrainsBeforeRetirementCanProceed() async throws {
        #if DEBUG
            let fixture = try Self.makeGitFixture()
            defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
            let authority = GitWorktreeRetirementAuthority(
                persistenceURL: fixture.sandbox.appendingPathComponent("retirement-authority/state.json")
            )
            GitWorktreeRetirementAuthority.setOperationalAuthorityForTesting(authority)
            defer { GitWorktreeRetirementAuthority.setOperationalAuthorityForTesting(nil) }

            let window = try await Self.makeWindow(root: fixture.repo)
            defer {
                window.mcpServer.setPromptExportRetirementLeaseAcquiredForTesting(nil)
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)
            let prompt = try await Self.windowTool(named: MCPWindowToolName.prompt, in: window)
            let createValue = try await manageWorktree([
                "op": .string("create"),
                "branch": .string("feature/export-drain-\(fixture.suffix)"),
                "base_ref": .string("HEAD")
            ])
            let created = try Self.worktreeObject(createValue, key: "created_worktree")
            let worktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
            let worktreePath = try XCTUnwrap(created["path"]?.stringValue)
            let exportPath = URL(fileURLWithPath: worktreePath).appendingPathComponent("retirement-export.md").path

            let git = GitService()
            let descriptors = try await git.listWorktrees(at: fixture.repo)
            let descriptor = try XCTUnwrap(descriptors.first { $0.worktreeID == worktreeID })
            let target = try await git.inspectRetirementTarget(descriptor: descriptor, generation: 0)
            let gate = WorktreeRetirementAsyncGate()
            window.mcpServer.setPromptExportRetirementLeaseAcquiredForTesting {
                await gate.enterAndWait()
            }

            let exportTask = Task {
                try await prompt([
                    "op": .string("export"),
                    "path": .string(exportPath)
                ])
            }
            await gate.waitUntilEntered()

            let preparation = try authority.begin(target.candidate)
            XCTAssertGreaterThanOrEqual(
                try authority.activeAdmissionCount(for: preparation),
                1
            )
            XCTAssertThrowsError(
                try authority.acquireMutationLease(paths: [exportPath])
            )

            await gate.release()
            _ = try await exportTask.value
            try await authority.awaitZeroAdmissions(for: preparation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: exportPath))
            _ = try authority.blockPreparation(
                preparation,
                reason: "test completed without physical retirement"
            )
        #else
            throw XCTSkip("Prompt export retirement hook is DEBUG-only.")
        #endif
    }

    func testManageWorktreeListExcludesStalePrunableWorktrees() async throws {
        let fixture = try Self.makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        let window = try await Self.makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)

        // Create a real linked worktree, then delete its checkout directory. Git keeps the admin
        // record under .git/worktrees/<name> but now reports the worktree prunable ("gitdir file
        // points to a non-existent location"). The tool must not list a stale worktree, otherwise
        // a model could select it and bind a session to an empty/partial tree.
        let createValue = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/stale-\(fixture.suffix)"),
            "base_ref": .string("HEAD")
        ])
        let createdWorktree = try Self.worktreeObject(createValue, key: "created_worktree")
        let stalePath = try XCTUnwrap(createdWorktree["path"]?.stringValue)
        let staleID = try XCTUnwrap(createdWorktree["worktree_id"]?.stringValue)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: stalePath))

        let listValue = try await manageWorktree(["op": .string("list")])
        let listObject = try XCTUnwrap(listValue.objectValue)
        let listed = listObject["worktrees"]?.arrayValue ?? []
        let listedIDs = listed.compactMap { $0.objectValue?["worktree_id"]?.stringValue }
        let listedPaths = listed.compactMap { $0.objectValue?["path"]?.stringValue }

        XCTAssertFalse(listedIDs.contains(staleID), "stale worktree id should be omitted: \(listedIDs)")
        XCTAssertFalse(listedPaths.contains(stalePath), "stale worktree path should be omitted: \(listedPaths)")
        XCTAssertFalse(listed.isEmpty, "the main worktree should still be listed")

        let warning = listObject["warning"]?.stringValue ?? ""
        XCTAssertTrue(
            warning.lowercased().contains("prunable") || warning.lowercased().contains("stale"),
            "expected an omitted-prunable warning, got: \(warning)"
        )
    }

    func testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections() async throws {
        let fixture = try Self.makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        let window = try await Self.makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)
        let manageSelection = try await Self.windowTool(named: MCPWindowToolName.manageSelection, in: window)
        let readFile = try await Self.windowTool(named: MCPWindowToolName.readFile, in: window)
        let fileSearch = try await Self.windowTool(named: MCPWindowToolName.search, in: window)
        let createValue = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/selection-\(fixture.suffix)"),
            "base_ref": .string("HEAD")
        ])
        let created = try Self.worktreeObject(createValue, key: "created_worktree")
        let worktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
        let worktreePath = try XCTUnwrap(created["path"]?.stringValue)
        let worktreeOnlyFile = URL(fileURLWithPath: worktreePath)
            .appendingPathComponent("WorktreeOnly.swift")
        try SwiftFixtureSource.emptyStruct("WorktreeOnly").write(to: worktreeOnlyFile, atomically: true, encoding: .utf8)

        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
        let sessionID = UUID()
        let session = window.agentModeViewModel.session(for: tabID)
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            updateWorkspaceMetadata: true
        )
        _ = try await manageWorktree([
            "op": .string("bind"),
            "worktree_id": .string(worktreeID),
            "session_id": .string(sessionID.uuidString)
        ])
        addTeardownBlock {
            await window.workspaceFileContextStore.releaseSessionWorktreeOwnership(ownerID: sessionID)
        }

        let maybeProjection = await window.mcpServer.materializeWorkspaceBindingProjection(
            sessionID: sessionID,
            bindings: window.agentModeViewModel.worktreeBindings(forAgentSessionID: sessionID)
        )
        let projection = try XCTUnwrap(maybeProjection)
        let physicalRootID = try XCTUnwrap(projection.physicalRootRefs.first?.id)
        let searchCreatedFile = URL(fileURLWithPath: worktreePath).appendingPathComponent("SearchCreated.swift")
        let searchNeedle = "SEARCH_CREATED_CONTEXT_NEEDLE_\(fixture.suffix)"
        try [
            "line 1", "line 2", "line 3", "line 4", searchNeedle,
            "line 6", "line 7", "line 8", "line 9"
        ].joined(separator: "\n").appending("\n").write(
            to: searchCreatedFile,
            atomically: false,
            encoding: .utf8
        )
        let acceptedCreate = try await window.workspaceFileContextStore.acceptWatcherPayloadForTesting(
            rootID: physicalRootID,
            events: [(
                absolutePath: searchCreatedFile.path,
                flags: FSEventStreamEventFlags(
                    kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
                ),
                eventId: 9_000_000_000_000_000_000
            )]
        )
        XCTAssertNotNil(acceptedCreate)
        _ = await window.workspaceFileContextStore.awaitAppliedIngress(rootScope: projection.lookupRootScope)
        let createdLookup = await window.workspaceFileContextStore.lookupPath(
            searchCreatedFile.path,
            profile: .mcpRead,
            rootScope: projection.lookupRootScope
        )
        XCTAssertNotNil(createdLookup)

        let searchConnectionID = UUID()
        let searchRunID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: searchConnectionID,
            clientName: AgentProviderKind.codexMCPClientID,
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID,
            runID: searchRunID,
            explicitlyBound: false
        )
        await ServerNetworkManager.shared.setRunPurpose(.agentModeRun, for: searchConnectionID)
        defer {
            window.mcpServer.removeTabContext(
                forConnectionID: searchConnectionID,
                clientName: AgentProviderKind.codexMCPClientID,
                windowID: window.windowID,
                runID: searchRunID
            )
            Task { await ServerNetworkManager.shared.setRunPurpose(.unknown, for: searchConnectionID) }
        }
        _ = try await ServerNetworkManager.withConnectionID(searchConnectionID) {
            try await manageSelection(["op": .string("clear")])
        }
        let searchValue = try await ServerNetworkManager.withConnectionID(searchConnectionID) {
            try await fileSearch([
                "pattern": .string(searchNeedle),
                "mode": .string("content"),
                "regex": .bool(false),
                "context_lines": .int(2),
                "filter": .object(["paths": .array([.string("SearchCreated.swift")])])
            ])
        }
        let formattedSearch = try Self.onlyText(ToolOutputFormatter.formatSearch(value: searchValue))
        XCTAssertTrue(formattedSearch.contains(searchNeedle), formattedSearch)
        XCTAssertTrue(formattedSearch.contains("SearchCreated.swift"), formattedSearch)

        let staleConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: staleConnectionID,
            clientName: "stale-one-shot-selection-client",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )

        let setterConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: setterConnectionID,
            clientName: "setter-one-shot-selection-client",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )
        #if DEBUG
            let staleSelectionRevision = try XCTUnwrap(
                window.mcpServer.debugSelectionRevisionForBoundConnection(staleConnectionID)
            )
        #endif
        let setValue = try await ServerNetworkManager.withConnectionID(setterConnectionID) {
            try await manageSelection([
                "op": .string("set"),
                "paths": .array([.string("WorktreeOnly.swift")]),
                "mode": .string("full"),
                "view": .string("files"),
                "path_display": .string("full"),
                "strict": .bool(true)
            ])
        }

        let logicalPath = fixture.repo.appendingPathComponent("WorktreeOnly.swift").path
        let outputPath = "\(fixture.repo.lastPathComponent)/WorktreeOnly.swift"
        XCTAssertEqual(try Self.selectionPaths(setValue), [outputPath])
        let canonicalSelectionRevision = window.workspaceManager.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: tabID
        )
        #if DEBUG
            XCTAssertGreaterThan(canonicalSelectionRevision, staleSelectionRevision)
            XCTAssertEqual(
                window.mcpServer.debugSelectionRevisionForBoundConnection(setterConnectionID),
                canonicalSelectionRevision
            )
            XCTAssertEqual(
                window.mcpServer.debugSelectionRevisionForBoundConnection(staleConnectionID),
                staleSelectionRevision
            )
        #endif
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.selection.selectedPaths,
            [logicalPath]
        )
        XCTAssertTrue(window.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logicalPath))

        // Reproduce the app-only race absent from direct provider tests: a debounced file-tree
        // publisher captured the empty logical-base UI before MCP persistence and fires later.
        window.workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true, touchModified: false)
        let staleUIPublishSelectionRevision = await Self.drainMainActorAndReadSelectionRevision(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID
        )
        XCTAssertEqual(staleUIPublishSelectionRevision, canonicalSelectionRevision)
        #if DEBUG
            XCTAssertEqual(
                window.mcpServer.debugSelectionRevisionForBoundConnection(setterConnectionID),
                canonicalSelectionRevision
            )
            XCTAssertEqual(
                window.mcpServer.debugSelectionRevisionForBoundConnection(staleConnectionID),
                staleSelectionRevision
            )
        #endif
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.selection.selectedPaths,
            [logicalPath]
        )

        // Exec-mode CLI disconnect is asynchronous. Exercise the stale cleanup ordering where
        // an older bound snapshot commits after the setter has persisted newer canonical state.
        let selectionRevisionBeforeStaleCleanup = window.workspaceManager.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: tabID
        )
        let staleCleanup = Task { @MainActor in
            await window.mcpServer.commitAndClearTabContext(connectionID: staleConnectionID)
        }
        let staleCommitSucceeded = await staleCleanup.value
        XCTAssertTrue(staleCommitSucceeded)
        XCTAssertEqual(
            window.workspaceManager.selectionRevisionForMCP(workspaceID: workspaceID, tabID: tabID),
            selectionRevisionBeforeStaleCleanup
        )
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertTrue(window.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty)
        window.mcpServer.removeTabContext(
            forConnectionID: setterConnectionID,
            clientName: "setter-one-shot-selection-client",
            windowID: window.windowID
        )

        let getterConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: getterConnectionID,
            clientName: "getter-one-shot-selection-client",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )
        let getValue = try await ServerNetworkManager.withConnectionID(getterConnectionID) {
            try await manageSelection([
                "op": .string("get"),
                "view": .string("files"),
                "path_display": .string("full")
            ])
        }
        XCTAssertEqual(try Self.selectionPaths(getValue), [outputPath])
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertTrue(window.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty)
        window.mcpServer.removeTabContext(
            forConnectionID: getterConnectionID,
            clientName: "getter-one-shot-selection-client",
            windowID: window.windowID
        )

        // A worktree-bound Agent Mode read auto-selects canonically without attempting to
        // project a physical-only file into the logical base file tree.
        let readConnectionID = UUID()
        let readRunID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: readConnectionID,
            clientName: "read-one-shot-selection-client",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID,
            runID: readRunID,
            explicitlyBound: false
        )
        await ServerNetworkManager.shared.setRunPurpose(.agentModeRun, for: readConnectionID)
        _ = try await ServerNetworkManager.withConnectionID(readConnectionID) {
            try await manageSelection(["op": .string("clear")])
        }
        _ = try await ServerNetworkManager.withConnectionID(readConnectionID) {
            try await readFile(["path": .string("WorktreeOnly.swift")])
        }
        let readSelection = try await ServerNetworkManager.withConnectionID(readConnectionID) {
            try await manageSelection([
                "op": .string("get"),
                "view": .string("files"),
                "path_display": .string("full")
            ])
        }
        XCTAssertEqual(try Self.selectionPaths(readSelection), [outputPath])
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.selection.selectedPaths,
            [logicalPath]
        )
        XCTAssertTrue(window.workspaceFilesViewModel.snapshotSelection().selectedPaths.isEmpty)
        window.mcpServer.removeTabContext(
            forConnectionID: readConnectionID,
            clientName: "read-one-shot-selection-client",
            windowID: window.windowID,
            runID: readRunID
        )
        await ServerNetworkManager.shared.setRunPurpose(.unknown, for: readConnectionID)

        let selectionRevisionBeforeFinalStalePublish = window.workspaceManager.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: tabID
        )
        window.workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true, touchModified: false)
        let selectionRevisionAfterFinalStalePublish = await Self.drainMainActorAndReadSelectionRevision(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID
        )
        XCTAssertEqual(selectionRevisionAfterFinalStalePublish, selectionRevisionBeforeFinalStalePublish)

        let finalConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: finalConnectionID,
            clientName: "final-one-shot-selection-client",
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )
        defer {
            window.mcpServer.removeTabContext(
                forConnectionID: finalConnectionID,
                clientName: "final-one-shot-selection-client",
                windowID: window.windowID
            )
        }
        let finalSelection = try await ServerNetworkManager.withConnectionID(finalConnectionID) {
            try await manageSelection([
                "op": .string("get"),
                "view": .string("files"),
                "path_display": .string("full")
            ])
        }
        XCTAssertEqual(try Self.selectionPaths(finalSelection), [outputPath])
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection.selectedPaths, [logicalPath])
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.selection.selectedPaths,
            [logicalPath]
        )

        // A genuinely newer manual UI mutation advances the live-owner revision and supersedes
        // the worktree fence rather than leaving canonical selection permanently pinned.
        let manualUISelection = StoredSelection(
            selectedPaths: [fixture.trackedFile.path],
            codemapAutoEnabled: false
        )
        let selectionRevisionBeforeManualUIPublish = window.workspaceManager.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: tabID
        )
        await window.workspaceFilesViewModel.applyStoredSelection(manualUISelection)
        window.workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true, touchModified: false)
        let selectionRevisionAfterManualUIPublish = await Self.drainMainActorAndReadSelectionRevision(
            window: window,
            workspaceID: workspaceID,
            tabID: tabID
        )
        XCTAssertGreaterThan(selectionRevisionAfterManualUIPublish, selectionRevisionBeforeManualUIPublish)
        XCTAssertEqual(window.workspaceManager.composeTab(with: tabID)?.selection, manualUISelection)
        XCTAssertEqual(
            window.promptManager.currentComposeTabs.first(where: { $0.id == tabID })?.selection,
            manualUISelection
        )
    }

    func testContextBuilderExportUsesResolvedWorktreeContextAndIsReadableFromFreshConnection() async throws {
        #if DEBUG
            let fixture = try Self.makeGitFixture()
            defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

            let provider = WorktreeContextBuilderImmediateCompletionProvider()
            let window = try await Self.makeWindow(
                root: fixture.repo,
                contextBuilderProviderFactory: { _, _, _ in provider }
            )
            defer { WindowStatesManager.shared.unregisterWindowState(window) }
            let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)
            let contextBuilder = try await Self.windowTool(named: MCPWindowToolName.contextBuilder, in: window)
            let readFile = try await Self.windowTool(named: MCPWindowToolName.readFile, in: window)

            var targetTab = try await Self.createBackgroundTab(in: window, name: "Bound Export Target")
            let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id)
            ContextBuilderTestReadinessSupport.seedCanonicalProviderReadiness(
                apiSettingsViewModel: window.apiSettingsViewModel,
                workspaceID: workspaceID
            )
            XCTAssertNotEqual(window.workspaceManager.activeWorkspace?.activeComposeTabID, targetTab.id)
            targetTab.promptText = "Generate the deterministic worktree export."
            window.workspaceManager.updateComposeTab(targetTab, markDirty: false)
            let sessionID = UUID()
            let session = window.agentModeViewModel.session(for: targetTab.id)
            _ = window.agentModeViewModel.test_installPersistentSessionBinding(
                sessionID: sessionID,
                on: session,
                updateWorkspaceMetadata: true
            )

            let createValue = try await manageWorktree([
                "op": .string("create"),
                "branch": .string("feature/export-\(fixture.suffix)"),
                "base_ref": .string("HEAD")
            ])
            let created = try Self.worktreeObject(createValue, key: "created_worktree")
            let worktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
            let worktreePath = try XCTUnwrap(created["path"]?.stringValue)
            _ = try await manageWorktree([
                "op": .string("bind"),
                "worktree_id": .string(worktreeID),
                "session_id": .string(sessionID.uuidString)
            ])

            window.contextBuilderAgentViewModel.installRunTestHooks(
                ContextBuilderAgentViewModel.RunTestHooks(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    allowSyntheticRoutingWithoutFinalContext: true,
                    runMCPFollowUp: { mode, _, _ in
                        let chatID = UUID()
                        return ChatSendReply(
                            chatId: chatID,
                            shortId: String(chatID.uuidString.prefix(8)).lowercased(),
                            mode: mode.mcpModeName,
                            response: "deterministic worktree export response",
                            errors: nil
                        )
                    }
                )
            )
            defer { window.contextBuilderAgentViewModel.installRunTestHooks(nil) }

            let exportConnectionID = UUID()
            let exportValue = try await ServerNetworkManager.withConnectionID(exportConnectionID) {
                // Exercise the provider's explicit context_id resolution without an ambient
                // TaskLocal hint; the active tab intentionally points at the base checkout.
                try await contextBuilder([
                    "instructions": .string("Inspect the worktree-bound target."),
                    "response_type": .string("plan"),
                    "context_id": .string(targetTab.id.uuidString),
                    "export_response": .bool(true)
                ])
            }
            let exportObject = try XCTUnwrap(exportValue.objectValue)
            XCTAssertNotNil(exportObject["plan"]?.objectValue, String(describing: exportObject))
            let exportPath = try XCTUnwrap(exportObject["oracle_export_path"]?.stringValue)
            let exportInstruction = try XCTUnwrap(exportObject["oracle_export_instruction"]?.stringValue)
            let standardizedLogicalPath = fixture.repo.standardizedFileURL.path
            XCTAssertTrue(
                exportPath.hasPrefix(standardizedLogicalPath + "/prompt-exports/"),
                exportPath
            )
            let exportPathLiteral = try XCTUnwrap(
                String(data: JSONEncoder().encode(exportPath), encoding: .utf8)
            )
            XCTAssertTrue(
                exportInstruction.contains("{\"path\": \(exportPathLiteral)}"),
                exportInstruction
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: exportPath), exportPath)

            let relativeExportPath = String(exportPath.dropFirst(standardizedLogicalPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let physicalExportPath = URL(fileURLWithPath: worktreePath)
                .appendingPathComponent(relativeExportPath)
                .path
            XCTAssertTrue(FileManager.default.fileExists(atPath: physicalExportPath), physicalExportPath)

            let readConnectionID = UUID()
            let contextHint = MCPServerViewModel.TabContextHint(
                tabID: targetTab.id,
                workspaceID: workspaceID,
                windowID: window.windowID
            )
            let readValue = try await ServerNetworkManager.withConnectionID(readConnectionID) {
                try await ServerNetworkManager.$currentTabContextHint.withValue(contextHint) {
                    try await readFile(["path": .string(exportPath)])
                }
            }
            let readReply = try XCTUnwrap(readValue.decode(ToolResultDTOs.ReadFileReply.self))
            XCTAssertTrue(readReply.content.contains("deterministic worktree export response"), readReply.content)
            XCTAssertNotNil(readReply.worktreeScope)
        #else
            throw XCTSkip("Context Builder provider injection is DEBUG-only.")
        #endif
    }

    func testManageWorktreeMergePreviewCleanApplyRawAndFormattedContract() async throws {
        let fixture = try Self.makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        let window = try await Self.makeWindow(root: fixture.repo)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let manageWorktree = try await Self.windowTool(named: MCPWindowToolName.manageWorktree, in: window)
        let sessionID = UUID()
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let session = window.agentModeViewModel.session(for: tabID)
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(
            sessionID: sessionID,
            on: session,
            updateWorkspaceMetadata: true
        )

        let createValue = try await manageWorktree([
            "op": .string("create"),
            "branch": .string("feature/merge-smoke-\(fixture.suffix)"),
            "base_ref": .string("HEAD")
        ])
        let created = try Self.worktreeObject(createValue, key: "created_worktree")
        let sourceWorktreeID = try XCTUnwrap(created["worktree_id"]?.stringValue)
        let sourcePath = try XCTUnwrap(created["path"]?.stringValue)
        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        try "feature\n".write(to: sourceURL.appendingPathComponent("Feature.txt"), atomically: true, encoding: .utf8)
        try Self.runGit(["add", "Feature.txt"], cwd: sourceURL)
        try Self.runGit(["commit", "-m", "Feature commit"], cwd: sourceURL)

        _ = try await manageWorktree([
            "op": .string("bind"),
            "worktree_id": .string(sourceWorktreeID),
            "session_id": .string(sessionID.uuidString)
        ])

        let previewValue = try await manageWorktree([
            "op": .string("preview"),
            "session_id": .string(sessionID.uuidString),
            "target": .string("@main"),
            "include_graph": .bool(true),
            "graph_limit": .int(12)
        ])
        let previewObject = try XCTUnwrap(previewValue.objectValue)
        XCTAssertEqual(previewObject["op"]?.stringValue, "preview")
        XCTAssertNil(previewObject["operation_id"])
        let previewMerge = try XCTUnwrap(previewObject["merge"]?.objectValue)
        XCTAssertEqual(previewMerge["status"]?.stringValue, "preview")
        let operationID = try XCTUnwrap(previewMerge["operation_id"]?.stringValue)
        XCTAssertEqual(previewMerge["visualization"]?.objectValue?["source"]?.stringValue, "manage_worktree.preview")
        XCTAssertTrue(previewMerge["next_actions"]?.arrayValue?.contains { $0.stringValue?.contains("manage_worktree") == true } == true)

        let formattedPreview = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: ["op": .string("preview")], value: previewValue))
        XCTAssertTrue(formattedPreview.contains("## Manage Worktree Preview"), formattedPreview)
        XCTAssertTrue(formattedPreview.contains("### ASCII Visualization"), formattedPreview)

        let applyValue = try await manageWorktree([
            "op": .string("apply"),
            "session_id": .string(sessionID.uuidString),
            "operation_id": .string(operationID),
            "confirm_preview": .bool(true),
            "include_graph": .bool(true)
        ])
        let applyObject = try XCTUnwrap(applyValue.objectValue)
        XCTAssertEqual(applyObject["op"]?.stringValue, "apply")
        let applyMerge = try XCTUnwrap(applyObject["merge"]?.objectValue)
        XCTAssertEqual(applyMerge["status"]?.stringValue, "completed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("Feature.txt").path))

        let formattedApply = try Self.onlyText(ToolOutputFormatter.formatManageWorktree(args: ["op": .string("apply")], value: applyValue))
        XCTAssertTrue(formattedApply.contains("## Manage Worktree Apply"), formattedApply)
        XCTAssertTrue(formattedApply.contains("Validate from target cwd"), formattedApply)
    }

    private func assertManageWorktreeGraphListContract(_ value: Value) throws {
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["op"]?.stringValue, "list")
        let worktrees = try XCTUnwrap(object["worktrees"]?.arrayValue)
        XCTAssertFalse(worktrees.isEmpty)
        let first = try XCTUnwrap(worktrees.first?.objectValue)
        XCTAssertNotNil(first["worktree_id"]?.stringValue)
        XCTAssertNotNil(first["specifier"]?.stringValue)
        XCTAssertNotNil(first["visual"]?.objectValue?["color_hex"]?.stringValue)

        let graph = try XCTUnwrap(object["graph"]?.objectValue)
        XCTAssertEqual(graph["requested"]?.boolValue, true)
        XCTAssertEqual(graph["limit"]?.intValue, 8)
        XCTAssertNotNil(graph["line_count"]?.intValue)
        XCTAssertFalse(graph["lines"]?.arrayValue?.isEmpty ?? true)
        XCTAssertTrue(graph["source"]?.stringValue?.contains("git log --graph") ?? false)
    }

    private func assertDiscoveryToolsReportWorktreeScope(
        window: WindowState,
        logicalRootPath: String,
        effectiveRootPath: String,
        worktreeID: String
    ) async throws {
        let getFileTree = try await Self.windowTool(named: MCPWindowToolName.getFileTree, in: window)
        let readFile = try await Self.windowTool(named: MCPWindowToolName.readFile, in: window)
        let fileSearch = try await Self.windowTool(named: MCPWindowToolName.search, in: window)

        let treeValue = try await getFileTree(["type": .string("files"), "max_depth": .int(1)])
        try Self.assertWorktreeScope(
            in: treeValue,
            logicalRootPath: logicalRootPath,
            effectiveRootPath: effectiveRootPath,
            worktreeID: worktreeID
        )
        let formattedTree = try Self.onlyText(ToolOutputFormatter.formatFileTree(value: treeValue))
        XCTAssertFalse(formattedTree.contains(logicalRootPath), formattedTree)
        XCTAssertFalse(formattedTree.contains(effectiveRootPath), formattedTree)
        XCTAssertTrue(formattedTree.contains("session-bound worktree"), formattedTree)

        let readValue = try await readFile(["path": .string("Tracked.txt")])
        try Self.assertWorktreeScope(
            in: readValue,
            logicalRootPath: logicalRootPath,
            effectiveRootPath: effectiveRootPath,
            worktreeID: worktreeID
        )
        let formattedRead = try Self.onlyText(ToolOutputFormatter.formatReadFile(args: ["path": .string("Tracked.txt")], value: readValue))
        XCTAssertFalse(formattedRead.contains(logicalRootPath), formattedRead)
        XCTAssertFalse(formattedRead.contains(effectiveRootPath), formattedRead)
        XCTAssertTrue(formattedRead.contains("session-bound worktree"), formattedRead)

        let searchValue = try await fileSearch(["pattern": .string("original"), "mode": .string("content"), "max_results": .int(5)])
        try Self.assertWorktreeScope(
            in: searchValue,
            logicalRootPath: logicalRootPath,
            effectiveRootPath: effectiveRootPath,
            worktreeID: worktreeID
        )
        let formattedSearch = try Self.onlyText(ToolOutputFormatter.formatSearch(value: searchValue))
        XCTAssertFalse(formattedSearch.contains(logicalRootPath), formattedSearch)
        XCTAssertFalse(formattedSearch.contains(effectiveRootPath), formattedSearch)
        XCTAssertTrue(formattedSearch.contains("session-bound worktree"), formattedSearch)
    }

    private func assertBoundSessionReadAndApplyUseWorktree(
        value: Value,
        window: WindowState,
        logicalRoot: URL,
        originalTrackedFile: URL
    ) async throws {
        let sessionID = try Self.sessionID(value)
        let bindings = window.agentModeViewModel.worktreeBindings(forAgentSessionID: sessionID)
        XCTAssertFalse(bindings.isEmpty)
        let materializedProjection = await window.mcpServer.materializeWorkspaceBindingProjection(sessionID: sessionID, bindings: bindings)
        let projection = try XCTUnwrap(materializedProjection)
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let store = window.workspaceFileContextStore

        let readPath = lookupContext.translateInputPath("Tracked.txt")
        XCTAssertFalse(readPath.hasPrefix(logicalRoot.path + "/"), readPath)
        let lookupResult = await store.lookupPath(readPath, profile: .mcpRead, rootScope: lookupContext.rootScope)
        let readRecord = try XCTUnwrap(lookupResult?.file)
        let readContent = try await store.readContent(rootID: readRecord.rootID, relativePath: readRecord.standardizedRelativePath)
        XCTAssertEqual(readContent, "original\n")

        let host = WorkspaceFileEditHost(
            store: store,
            lookupRootScope: lookupContext.rootScope,
            createPathResolutionPolicy: .canonicalAliasFirst,
            selectCreatedFiles: false
        )
        let service = ApplyEditsService(engine: .default, host: host)
        let result = try await service.run(ApplyEditsRequest(
            path: lookupContext.translateInputPath("Tracked.txt"),
            mode: .single(search: "original", replace: "worktree-edited", replaceAll: false),
            verbose: true
        ))
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(try String(contentsOf: originalTrackedFile, encoding: .utf8), "original\n")
        XCTAssertEqual(try String(contentsOfFile: readPath, encoding: .utf8), "worktree-edited\n")
    }

    private static func drainMainActorAndReadSelectionRevision(
        window: WindowState,
        workspaceID: UUID,
        tabID: UUID
    ) async -> UInt64 {
        for _ in 0 ..< 3 {
            await Task.yield()
        }
        return window.workspaceManager.selectionRevisionForMCP(workspaceID: workspaceID, tabID: tabID)
    }

    private static func makeAgentRunService(window: WindowState, targetTabID: UUID) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(connectionID: nil, clientName: "worktree-api-smoke", windowID: window.windowID)
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in targetTabID },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, _, _, agentModeVM, agentRaw, modelRaw, reasoningEffortRaw, _, _, _, _ in
                guard let sessionID = target.sessionID else {
                    throw MCPError.internalError("Smoke start target did not resolve a session ID.")
                }
                let bindings = agentModeVM.worktreeBindings(forAgentSessionID: sessionID, tabID: target.tabID)
                let snapshot = AgentRunMCPSnapshot(
                    sessionID: sessionID,
                    tabID: target.tabID,
                    sessionName: "Worktree API Smoke",
                    agentRaw: agentRaw,
                    agentDisplayName: agentRaw.flatMap { AgentProviderKind(rawValue: $0)?.displayName },
                    modelRaw: modelRaw,
                    reasoningEffortRaw: reasoningEffortRaw,
                    status: .running,
                    statusText: "Smoke harness running",
                    latestAssistantPreview: nil,
                    interaction: nil,
                    transcriptItemCount: 0,
                    updatedAt: Date(),
                    parentSessionID: nil,
                    failureReason: nil,
                    worktreeBindings: bindings.map { AgentRunMCPSnapshot.WorktreeBinding(binding: $0) },
                    activeWorktreeMerges: []
                )
                return AgentExternalMCPRunStarter.StartOutcome(snapshot: snapshot, delivery: .startedRun)
            }
        )
        service.resolveOracleReviewLaunchSource = { _, targetWindow in
            let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
            let snapshot = AgentRunOracleReviewLaunchSnapshot(
                route: .explicitTabContext,
                windowID: targetWindow.windowID,
                workspaceID: workspace.id,
                tabID: targetTabID,
                selectionRevision: targetWindow.workspaceManager.selectionRevisionForMCP(
                    workspaceID: workspace.id,
                    tabID: targetTabID
                ),
                promptText: "",
                selection: StoredSelection(),
                sourceAgentSessionID: nil,
                routedRunID: nil
            )
            return ResolvedAgentRunOracleReviewLaunchSource(
                snapshot: snapshot,
                source: .unavailable(.init(
                    delegationID: UUID(),
                    sourceTabID: targetTabID,
                    workspaceID: workspace.id,
                    sourceAgentSessionID: nil,
                    sourceAgentRunID: nil,
                    reason: .sourceCaptureFailed("Synthetic smoke-service fixture")
                ))
            )
        }
        return service
    }

    private static func makeWindow(
        root: URL,
        contextBuilderProviderFactory: ContextBuilderAgentViewModel.ProviderFactory? = nil
    ) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window: WindowState
        #if DEBUG
            if let contextBuilderProviderFactory {
                window = WindowState(contextBuilderProviderFactory: contextBuilderProviderFactory)
            } else {
                window = WindowState()
            }
        #else
            _ = contextBuilderProviderFactory
            window = WindowState()
        #endif
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Worktree API Smoke \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "worktreeAPISmokeHarness")
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(in: window, path: root.path)
        return window
    }

    private static func createBackgroundTab(in window: WindowState, name: String) async throws -> ComposeTabState {
        let tab = await window.promptManager.createBackgroundComposeTab(
            strategy: .blank,
            name: name,
            capacityPolicy: .mcpBackgroundAgent
        )
        return try XCTUnwrap(tab)
    }

    private static func windowTool(named name: String, in window: WindowState) async throws -> RepoPromptApp.Tool {
        let tools = await window.mcpServer.windowMCPTools
        return try XCTUnwrap(tools.first { $0.name == name })
    }

    private struct GitFixture {
        let sandbox: URL
        let repo: URL
        let trackedFile: URL
        let suffix: String
    }

    private static func makeGitFixture() throws -> GitFixture {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let sandbox = URL(
            fileURLWithPath: FileManager.default.temporaryDirectory.path.hasPrefix("/var/")
                ? "/private\(FileManager.default.temporaryDirectory.path)"
                : FileManager.default.temporaryDirectory.path,
            isDirectory: true
        )
        .appendingPathComponent("WorktreeAPISmokeHarnessTests-\(suffix)", isDirectory: true)
        let repo = sandbox.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"], cwd: repo)
        try runGit(["config", "user.name", "RepoPrompt Test"], cwd: repo)
        try runGit(["config", "user.email", "repoprompt@example.test"], cwd: repo)
        try runGit(["config", "commit.gpgSign", "false"], cwd: repo)
        try runGit(["checkout", "-b", "main"], cwd: repo)
        let trackedFile = repo.appendingPathComponent("Tracked.txt")
        try "original\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        let nestedFile = repo.appendingPathComponent("Nested/Nested.txt")
        try FileManager.default.createDirectory(
            at: nestedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "nested\n".write(to: nestedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "Tracked.txt", "Nested/Nested.txt"], cwd: repo)
        try runGit(["commit", "-m", "Initial commit"], cwd: repo)
        return GitFixture(sandbox: sandbox, repo: repo.standardizedFileURL, trackedFile: trackedFile.standardizedFileURL, suffix: String(suffix))
    }

    private static func runGit(_ arguments: [String], cwd: URL) throws {
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
                domain: "WorktreeAPISmokeHarnessTests.git",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.outputText)"]
            )
        }
    }

    private static func worktreeObject(_ value: Value, key: String) throws -> [String: Value] {
        try object(value, key: key)
    }

    private static func object(_ value: Value, key: String) throws -> [String: Value] {
        let root = try XCTUnwrap(value.objectValue)
        return try XCTUnwrap(root[key]?.objectValue)
    }

    private static func assertWorktreeScope(
        in value: Value,
        logicalRootPath: String,
        effectiveRootPath: String,
        worktreeID: String
    ) throws {
        let object = try XCTUnwrap(value.objectValue)
        let scope = try XCTUnwrap(object["worktree_scope"]?.objectValue)
        let mappings = try XCTUnwrap(scope["root_mappings"]?.arrayValue)
        let first = try XCTUnwrap(mappings.first?.objectValue)
        XCTAssertEqual(
            first["logical_root_path"]?.stringValue,
            URL(fileURLWithPath: logicalRootPath).lastPathComponent
        )
        XCTAssertEqual(first["effective_root_path"]?.stringValue, "session-bound")
        XCTAssertNotEqual(first["logical_root_path"]?.stringValue, effectiveRootPath)
        XCTAssertEqual(first["worktree_id"]?.stringValue, worktreeID)
    }

    private static func sessionID(_ value: Value) throws -> UUID {
        let object = try XCTUnwrap(value.objectValue)
        let raw = try XCTUnwrap(object["session_id"]?.stringValue)
        return try XCTUnwrap(UUID(uuidString: raw))
    }

    private static func firstWorktreeBinding(_ value: Value) throws -> [String: Value] {
        let object = try XCTUnwrap(value.objectValue)
        let bindings = try XCTUnwrap(object["worktree_bindings"]?.arrayValue)
        let first = try XCTUnwrap(bindings.first)
        return try XCTUnwrap(first.objectValue)
    }

    private static func selectionPaths(_ value: Value) throws -> [String] {
        let object = try XCTUnwrap(value.objectValue)
        let files = try XCTUnwrap(object["files"]?.arrayValue)
        return try files.map { file in
            try XCTUnwrap(file.objectValue?["path"]?.stringValue)
        }
    }

    private static func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}

private actor WorktreeRetirementAsyncGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

#if DEBUG
    private final class WorktreeContextBuilderImmediateCompletionProvider: HeadlessAgentProvider {
        func streamAgentMessage(
            _ message: AgentMessage,
            runID: UUID?
        ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
            _ = message
            let stream = AsyncThrowingStream<AIStreamResult, Error> { continuation in
                continuation.yield(AIStreamResult(type: "content", text: "Discovery complete"))
                continuation.finish()
            }
            if let runID {
                await MCPRoutingWaiter.notifyRouted(runID: runID)
            }
            return stream
        }

        func dispose() async {}
    }
#endif
