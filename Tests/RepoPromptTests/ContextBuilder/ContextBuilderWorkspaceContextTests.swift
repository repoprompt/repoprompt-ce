import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class ContextBuilderWorkspaceContextTests: XCTestCase {
    func testResolveFreezesWorktreeProjectionProviderCWDAndNestedSnapshot() async throws {
        let logicalRoot = try makeTemporaryDirectory(name: "ContextBuilderLogical")
        let worktreeRoot = try makeTemporaryDirectory(name: "ContextBuilderWorktree")
        defer {
            try? FileManager.default.removeItem(at: logicalRoot)
            try? FileManager.default.removeItem(at: worktreeRoot)
        }

        try write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))
        try write("let origin = \"worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/App.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)

        let sessionID = UUID()
        let parentRunID = UUID()
        let tabID = UUID()
        let workspaceID = UUID()
        let storedPromptID = UUID()
        let contextBuilderPromptID = UUID()
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)
        let selection = StoredSelection(
            selectedPaths: [logicalRoot.appendingPathComponent("Sources/App.swift").path],
            codemapAutoEnabled: false
        )
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: tabID,
            windowID: 41,
            workspaceID: workspaceID,
            promptText: "Inspect the branch implementation",
            selection: selection,
            selectedMetaPromptIDs: [storedPromptID],
            selectedContextBuilderPromptIDs: [contextBuilderPromptID],
            tabName: "Agent tab",
            runID: parentRunID,
            activeAgentSessionID: sessionID,
            worktreeBindings: [binding],
            explicitlyBound: true,
            readFileAutoSelectionGeneration: 7
        )

        let context = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot,
            workspaceRepoPaths: [logicalRoot.path],
            workspaceDirectoryPath: logicalRoot.path,
            store: store
        )

        XCTAssertEqual(context.parentAgentSessionID, sessionID)
        XCTAssertEqual(context.tabID, tabID)
        XCTAssertEqual(context.providerWorkspacePath, worktreeRoot.standardizedFileURL.path)
        XCTAssertEqual(
            context.lookupContext.translateInputPath(logicalRoot.appendingPathComponent("Sources/App.swift").path),
            worktreeRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path
        )

        let nestedRunID = UUID()
        let nested = context.nestedDiscoveryTabContext(runID: nestedRunID)
        XCTAssertEqual(nested.runID, nestedRunID)
        XCTAssertEqual(nested.activeAgentSessionID, sessionID)
        XCTAssertEqual(nested.worktreeBindings, [binding])
        XCTAssertEqual(nested.promptText, snapshot.promptText)
        XCTAssertEqual(nested.selection, snapshot.selection)
        XCTAssertEqual(nested.selectedMetaPromptIDs, [storedPromptID])
        XCTAssertEqual(nested.selectedContextBuilderPromptIDs, [contextBuilderPromptID])
        XCTAssertEqual(nested.frozenLookupContext, context.lookupContext)
        XCTAssertTrue(nested.explicitlyBound)
        XCTAssertEqual(nested.readFileAutoSelectionGeneration, 7)
    }

    func testResolveElectsWorktreeOnlyTargetAndRejectsCanonicalRescueAfterLifetimeLoss() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "ContextBuilderWorktreeOnlyElection")
        defer { fixture.cleanup() }
        let canonical = try fixture.makeRepository(
            named: "canonical",
            files: ["Sources/Shared.swift": "let source = \"canonical\"\n"]
        )
        let worktree = try fixture.makeLinkedWorktree(
            from: canonical,
            named: "worktree",
            branch: "feature/context-builder-worktree-only"
        )
        let branchOnly = worktree.appendingPathComponent("Sources/BranchOnly.swift")
        try write("let source = \"worktree only\"\n", to: branchOnly)
        let logicalBranchOnly = canonical.appendingPathComponent("Sources/BranchOnly.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logicalBranchOnly.path))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: canonical.path, kind: .primaryWorkspace)
        let sessionID = UUID()
        let binding = try makeGitBinding(
            logicalRoot: canonical,
            worktreeRoot: worktree,
            branch: "feature/context-builder-worktree-only"
        )
        let recorder = ContextBuilderReviewDiagnosticRecorder()
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 47,
            workspaceID: UUID(),
            promptText: "Review the worktree-only file",
            selection: StoredSelection(
                selectedPaths: [logicalBranchOnly.path],
                codemapAutoEnabled: false
            ),
            selectionRevision: 11,
            selectedMetaPromptIDs: [],
            tabName: "Worktree only",
            runID: UUID(),
            activeAgentSessionID: sessionID,
            worktreeBindings: [binding],
            explicitlyBound: false
        )

        let context = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot,
            workspaceRepoPaths: [canonical.path],
            workspaceDirectoryPath: fixture.sandbox.path,
            store: store,
            reviewDiagnosticSink: recorder.append
        )
        let target = try XCTUnwrap(context.reviewTargetResolution.availableTarget)
        XCTAssertEqual(target.primaryCheckout.checkoutRootPath, worktree.standardizedFileURL.path)
        XCTAssertEqual(target.initialOrdinarySelectionIdentities, [branchOnly.standardizedFileURL.path])
        XCTAssertNotNil(target.primaryCheckout.sessionRootAuthorization)
        XCTAssertEqual(
            context.lookupContext.displayPath(
                forPhysicalPath: branchOnly.path,
                display: .full
            ),
            logicalBranchOnly.standardizedFileURL.path
        )
        let event = try XCTUnwrap(recorder.snapshot().last)
        XCTAssertEqual(event.phase, .initialElection)
        XCTAssertEqual(event.outcome, .resolved)
        XCTAssertEqual(event.sessionID, sessionID)
        XCTAssertEqual(event.rootID, target.primaryCheckout.physicalWorkspaceRoot.id)
        XCTAssertEqual(event.candidateCount, 1)
        XCTAssertEqual(event.resolvedCount, 1)
        XCTAssertEqual(event.unresolvedCount, 0)

        await store.releaseSessionWorktreeOwnership(ownerID: sessionID)
        do {
            _ = try await context.authorizeFinalReviewSelection(
                StoredSelection(
                    selectedPaths: [canonical.appendingPathComponent("Sources/Shared.swift").path],
                    codemapAutoEnabled: false
                ),
                workspaceID: target.workspaceID,
                tabID: target.tabID,
                selectionRevision: 12,
                store: store
            )
            XCTFail("Expected released worktree authority to reject canonical same-path rescue")
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            XCTAssertEqual(reason, .staleWorkspaceRoot)
        }
    }

    func testDeferredEmptySelectionFinalizesWorktreeOnlySelectionAndRejectsEmptyOrArtifactFinals() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "ContextBuilderDeferredWorktreeElection")
        defer { fixture.cleanup() }
        let canonical = try fixture.makeRepository(
            named: "canonical",
            files: ["Sources/Shared.swift": "let source = \"canonical\"\n"]
        )
        let worktree = try fixture.makeLinkedWorktree(
            from: canonical,
            named: "worktree",
            branch: "feature/context-builder-deferred"
        )
        let branchOnly = worktree.appendingPathComponent("Sources/DeferredOnly.swift")
        let logicalBranchOnly = canonical.appendingPathComponent("Sources/DeferredOnly.swift")
        try write("let source = \"deferred worktree\"\n", to: branchOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logicalBranchOnly.path))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: canonical.path, kind: .primaryWorkspace)
        let sessionID = UUID()
        let binding = try makeGitBinding(
            logicalRoot: canonical,
            worktreeRoot: worktree,
            branch: "feature/context-builder-deferred"
        )
        let recorder = ContextBuilderReviewDiagnosticRecorder()
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 48,
            workspaceID: UUID(),
            promptText: "Discover then review",
            selection: StoredSelection(codemapAutoEnabled: false),
            selectionRevision: 50,
            selectedMetaPromptIDs: [],
            tabName: "Deferred review",
            runID: UUID(),
            activeAgentSessionID: sessionID,
            worktreeBindings: [binding],
            explicitlyBound: false
        )

        let context = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot,
            workspaceRepoPaths: [canonical.path],
            workspaceDirectoryPath: fixture.sandbox.path,
            store: store,
            reviewDiagnosticSink: recorder.append
        )
        guard case .deferred = context.reviewTargetResolution else {
            return XCTFail("Expected empty initial selection to defer")
        }

        let finalSelection = StoredSelection(
            selectedPaths: [logicalBranchOnly.path],
            codemapAutoEnabled: false
        )
        let authorization = try await context.authorizeFinalReviewSelection(
            finalSelection,
            workspaceID: XCTUnwrap(snapshot.workspaceID),
            tabID: snapshot.tabID,
            selectionRevision: 51,
            store: store
        )

        XCTAssertEqual(authorization.electionOrigin, .deferred)
        XCTAssertEqual(authorization.committedSelectionRevision, 51)
        XCTAssertEqual(authorization.committedSelection, finalSelection)
        XCTAssertEqual(authorization.lookupContext, context.lookupContext)
        XCTAssertEqual(
            authorization.target.primaryCheckout.checkoutRootPath,
            worktree.standardizedFileURL.path
        )
        XCTAssertEqual(authorization.checkoutAuthorizations.count, 1)
        XCTAssertEqual(
            authorization.checkoutAuthorizations[0].ordinaryPhysicalPaths,
            [branchOnly.standardizedFileURL.path]
        )
        XCTAssertTrue(authorization.selectedArtifactAuthorizations.isEmpty)
        XCTAssertTrue(recorder.snapshot().contains {
            $0.phase == .finalElection && $0.outcome == .resolved
        })

        do {
            _ = try await context.authorizeFinalReviewSelection(
                StoredSelection(codemapAutoEnabled: false),
                workspaceID: authorization.workspaceID,
                tabID: authorization.tabID,
                selectionRevision: 52,
                store: store
            )
            XCTFail("Expected empty final selection to remain terminal")
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            XCTAssertEqual(reason, .emptySelection)
        }

        do {
            _ = try await context.authorizeFinalReviewSelection(
                StoredSelection(
                    selectedPaths: ["_git_data/repos/fake/diff/all.patch"],
                    codemapAutoEnabled: true
                ),
                workspaceID: authorization.workspaceID,
                tabID: authorization.tabID,
                selectionRevision: 53,
                store: store
            )
            XCTFail("Expected deferred final artifact selection to remain terminal")
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            XCTAssertEqual(reason, .deferredArtifactSelection(count: 1))
        }
    }

    func testNonemptyUnresolvedAndArtifactShapedInitialSelectionsNeverDefer() async throws {
        let root = try makeTemporaryDirectory(name: "ContextBuilderTerminalInitialSelection")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path, kind: .primaryWorkspace)

        func snapshot(selection: StoredSelection) -> MCPServerViewModel.TabContextSnapshot {
            MCPServerViewModel.TabContextSnapshot(
                tabID: UUID(),
                windowID: 49,
                workspaceID: UUID(),
                promptText: "Terminal initial selection",
                selection: selection,
                selectionRevision: 60,
                selectedMetaPromptIDs: [],
                tabName: "Terminal initial",
                runID: UUID(),
                activeAgentSessionID: UUID(),
                worktreeBindings: [],
                explicitlyBound: false
            )
        }

        let unresolvedContext = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot(selection: StoredSelection(
                selectedPaths: [root.appendingPathComponent("Missing.swift").path],
                codemapAutoEnabled: false
            )),
            workspaceRepoPaths: [root.path],
            workspaceDirectoryPath: root.path,
            store: store
        )
        XCTAssertEqual(
            unresolvedContext.reviewTargetResolution,
            .unavailable(.unresolvedSelection(count: 1))
        )

        let artifactContext = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot(selection: StoredSelection(
                selectedPaths: ["_git_data/repos/fake/diff/all.patch"],
                codemapAutoEnabled: true
            )),
            workspaceRepoPaths: [root.path],
            workspaceDirectoryPath: root.path,
            store: store
        )
        XCTAssertEqual(
            artifactContext.reviewTargetResolution,
            .unavailable(.unauthorizedSelectedArtifact(count: 1))
        )
    }

    func testDeferredFinalSelectionRetainsMultiCheckoutPolicy() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "ContextBuilderDeferredMultiCheckout")
        defer { fixture.cleanup() }
        let first = try fixture.makeRepository(
            named: "first",
            files: ["Sources/First.swift": "let first = true\n"]
        )
        let second = try fixture.makeRepository(
            named: "second",
            files: ["Sources/Second.swift": "let second = true\n"]
        )
        let firstFile = first.appendingPathComponent("Sources/First.swift")
        let secondFile = second.appendingPathComponent("Sources/Second.swift")
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: first.path, kind: .primaryWorkspace)
        _ = try await store.loadRoot(path: second.path, kind: .primaryWorkspace)

        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 50,
            workspaceID: UUID(),
            promptText: "Discover two repositories",
            selection: StoredSelection(codemapAutoEnabled: false),
            selectionRevision: 70,
            selectedMetaPromptIDs: [],
            tabName: "Deferred multi checkout",
            runID: UUID(),
            activeAgentSessionID: UUID(),
            worktreeBindings: [],
            explicitlyBound: false
        )
        let context = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot,
            workspaceRepoPaths: [first.path, second.path],
            workspaceDirectoryPath: fixture.sandbox.path,
            store: store
        )
        guard case .deferred = context.reviewTargetResolution else {
            return XCTFail("Expected empty multi-root selection to defer")
        }

        let selection = StoredSelection(
            selectedPaths: [firstFile.path, secondFile.path],
            codemapAutoEnabled: false
        )
        let authorization = try await context.authorizeFinalReviewSelection(
            selection,
            workspaceID: XCTUnwrap(snapshot.workspaceID),
            tabID: snapshot.tabID,
            selectionRevision: 71,
            store: store
        )
        XCTAssertEqual(authorization.electionOrigin, .deferred)
        XCTAssertEqual(authorization.target.checkouts.count, 2)
        XCTAssertEqual(
            Set(authorization.checkoutAuthorizations.flatMap(\.ordinaryPhysicalPaths)),
            Set([firstFile.standardizedFileURL.path, secondFile.standardizedFileURL.path])
        )
    }

    func testResolveWithoutBindingsFreezesCanonicalWorkspaceLookup() async throws {
        let logicalRoot = try makeTemporaryDirectory(name: "ContextBuilderUnbound")
        let otherWorkspaceRoot = try makeTemporaryDirectory(name: "ContextBuilderOtherWorkspace")
        defer {
            try? FileManager.default.removeItem(at: logicalRoot)
            try? FileManager.default.removeItem(at: otherWorkspaceRoot)
        }
        try write("let value = true\n", to: logicalRoot.appendingPathComponent("App.swift"))
        try write("let other = true\n", to: otherWorkspaceRoot.appendingPathComponent("Other.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 42,
            workspaceID: UUID(),
            promptText: "Question",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            tabName: "Unbound",
            runID: UUID(),
            activeAgentSessionID: UUID(),
            worktreeBindings: [],
            explicitlyBound: false
        )

        let context = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot,
            workspaceRepoPaths: [logicalRoot.path],
            workspaceDirectoryPath: logicalRoot.path,
            store: store
        )

        XCTAssertEqual(context.providerWorkspacePath, logicalRoot.standardizedFileURL.path)
        XCTAssertNil(context.lookupContext.bindingProjection)
        guard case let .deferred(authority) = context.reviewTargetResolution else {
            return XCTFail("Expected genuinely empty initial selection to defer review election")
        }
        XCTAssertEqual(authority.workspaceID, snapshot.workspaceID)
        XCTAssertEqual(authority.tabID, snapshot.tabID)
        XCTAssertEqual(authority.initialSelectionRevision, snapshot.selectionRevision)
        XCTAssertEqual(authority.lookupContext, context.lookupContext)
        XCTAssertEqual(authority.reviewGitContext, context.reviewGitContext)

        _ = try await store.loadRoot(path: otherWorkspaceRoot.path)
        let frozenRoots = await store.rootRefs(scope: context.lookupContext.rootScope)
        XCTAssertEqual(Set(frozenRoots.map(\.standardizedFullPath)), Set([logicalRoot.standardizedFileURL.path]))

        let nested = context.nestedDiscoveryTabContext(runID: UUID())
        XCTAssertEqual(nested.frozenLookupContext, context.lookupContext)
        let nestedLookupContext = try XCTUnwrap(nested.frozenLookupContext)
        let nestedRoots = await store.rootRefs(scope: nestedLookupContext.rootScope)
        XCTAssertEqual(Set(nestedRoots.map(\.standardizedFullPath)), Set([logicalRoot.standardizedFileURL.path]))
    }

    func testTwoRootUnboundSliceElectsSelectedRepositoryAndIgnoresCrossRootAutoCodemap() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "ContextBuilderTwoRootElection")
        defer { fixture.cleanup() }
        let classic = try fixture.makeRepository(
            named: "classic",
            files: ["Sources/Classic.swift": "let classic = true\n"]
        )
        let selected = try fixture.makeRepository(
            named: "ce",
            files: ["Sources/Selected.swift": "let selected = true\n"]
        )
        let classicFile = classic.appendingPathComponent("Sources/Classic.swift")
        let selectedFile = selected.appendingPathComponent("Sources/Selected.swift")
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: classic.path, kind: .primaryWorkspace)
        _ = try await store.loadRoot(path: selected.path, kind: .primaryWorkspace)

        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 46,
            workspaceID: UUID(),
            promptText: "Review selected CE file",
            selection: StoredSelection(
                selectedPaths: [],

                slices: [selectedFile.path: [LineRange(start: 1, end: 1)]],
                codemapAutoEnabled: true
            ),
            selectionRevision: 37,
            selectedMetaPromptIDs: [],
            tabName: "Two root",
            runID: UUID(),
            activeAgentSessionID: UUID(),
            worktreeBindings: [],
            explicitlyBound: false
        )

        let context = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot,
            workspaceRepoPaths: [classic.path, selected.path],
            workspaceDirectoryPath: fixture.sandbox.path,
            store: store
        )

        let target = try XCTUnwrap(context.reviewTargetResolution.availableTarget)
        XCTAssertEqual(target.checkouts.count, 1)
        XCTAssertEqual(
            target.primaryCheckout.checkoutRootPath,
            GitRepoRootAuthorization.canonicalPath(selected.path)
        )
        XCTAssertEqual(context.providerWorkspacePath, selected.standardizedFileURL.path)
        XCTAssertFalse(target.initialOrdinarySelectionIdentities.contains(classicFile.path))
        let nested = context.nestedDiscoveryTabContext(runID: UUID())
        XCTAssertEqual(nested.selectionRevision, 37)
        XCTAssertEqual(nested.contextBuilderReviewTargetResolution, context.reviewTargetResolution)

        _ = try await context.authorizeFinalReviewSelection(
            StoredSelection(selectedPaths: [selectedFile.path], codemapAutoEnabled: false),
            workspaceID: target.workspaceID,
            tabID: target.tabID,
            selectionRevision: 38,
            store: store
        )

        do {
            _ = try await context.authorizeFinalReviewSelection(
                StoredSelection(selectedPaths: [selectedFile.path], codemapAutoEnabled: false),
                workspaceID: UUID(),
                tabID: target.tabID,
                selectionRevision: 39,
                store: store
            )
            XCTFail("Expected final selection workspace provenance mismatch to fail")
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            XCTAssertEqual(reason, .workspaceOrTabMismatch)
        }

        do {
            _ = try await context.authorizeFinalReviewSelection(
                StoredSelection(selectedPaths: [classicFile.path], codemapAutoEnabled: false),
                workspaceID: target.workspaceID,
                tabID: target.tabID,
                selectionRevision: 40,
                store: store
            )
            XCTFail("Expected final selection ownership outside the frozen CE target to fail")
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            XCTAssertEqual(reason, .selectionOwnershipChanged)
        }

        await store.unloadRoot(id: target.primaryCheckout.physicalWorkspaceRoot.id)
        let staleReason = await ContextBuilderReviewTargetResolver().revalidate(target, store: store)
        XCTAssertEqual(staleReason, .staleWorkspaceRoot)
    }

    func testResolveWithoutBindingsFreezesVisibleLinkedCheckoutAuthority() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "ContextBuilderVisibleLinked")
        defer { fixture.cleanup() }

        let canonical = try fixture.makeRepository(named: "canonical")
        let linked = try fixture.makeLinkedWorktree(
            from: canonical,
            named: "linked",
            branch: "feature/context-builder-visible"
        )
        let workspaceDirectory = fixture.sandbox.appendingPathComponent(
            "workspace",
            isDirectory: true
        )
        let gitDataRoot = workspaceDirectory.appendingPathComponent("_git_data", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDataRoot, withIntermediateDirectories: true)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: linked.path, kind: .primaryWorkspace)
        _ = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 45,
            workspaceID: UUID(),
            promptText: "Review visible linked checkout",
            selection: StoredSelection(codemapAutoEnabled: false),
            selectedMetaPromptIDs: [],
            tabName: "Visible linked",
            runID: UUID(),
            activeAgentSessionID: UUID(),
            worktreeBindings: [],
            explicitlyBound: false
        )

        let context = try await ContextBuilderWorkspaceContext.resolve(
            from: snapshot,
            workspaceRepoPaths: [linked.path],
            workspaceDirectoryPath: workspaceDirectory.path,
            store: store
        )

        let capability = try XCTUnwrap(context.reviewGitContext.artifactCapability)
        XCTAssertTrue(capability.boundCheckouts.isEmpty)
        XCTAssertEqual(capability.visibleRootCheckouts.count, 1)
        XCTAssertEqual(capability.visibleRootCheckouts.first?.kind, .linkedWorktree)
        XCTAssertEqual(
            capability.visibleRootCheckouts.first?.visibleRootPath,
            GitRepoRootAuthorization.canonicalPath(linked.path)
        )
        XCTAssertEqual(context.providerWorkspacePath, linked.standardizedFileURL.path)
        XCTAssertNil(context.lookupContext.bindingProjection)
    }

    func testResolveFailsClosedWhenWorktreeBindingStateIsUnhydrated() async throws {
        let logicalRoot = try makeTemporaryDirectory(name: "ContextBuilderUnhydrated")
        defer { try? FileManager.default.removeItem(at: logicalRoot) }
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 44,
            workspaceID: UUID(),
            promptText: "Question",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            tabName: "Unhydrated",
            runID: UUID(),
            activeAgentSessionID: UUID(),
            worktreeBindingState: .unhydrated,
            explicitlyBound: false
        )

        do {
            _ = try await ContextBuilderWorkspaceContext.resolve(
                from: snapshot,
                workspaceRepoPaths: [logicalRoot.path],
                workspaceDirectoryPath: logicalRoot.path,
                store: store
            )
            XCTFail("Expected unhydrated binding state to fail closed")
        } catch let error as ContextBuilderWorkspaceContextError {
            XCTAssertEqual(error, .unavailableWorktreeBindingState)
        }
    }

    func testAuthoritativeLookupContextFailsClosedInsteadOfAdmittingCanonicalRoots() async throws {
        let logicalRoot = try makeTemporaryDirectory(name: "ContextBuilderFailClosedLookup")
        defer { try? FileManager.default.removeItem(at: logicalRoot) }
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)

        let lookupContext = await AgentWorkspaceLookupContextResolver.authoritativeLookupContextOrFailClosed(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: UUID(),
                worktreeBindingState: .unhydrated
            ),
            store: store
        )

        let roots = await store.rootRefs(scope: lookupContext.rootScope)
        XCTAssertTrue(roots.isEmpty)
        XCTAssertNil(lookupContext.bindingProjection)
    }

    func testResolveFailsClosedWhenInheritedWorktreeIsUnavailable() async throws {
        let logicalRoot = try makeTemporaryDirectory(name: "ContextBuilderMissingLogical")
        defer { try? FileManager.default.removeItem(at: logicalRoot) }
        let missingWorktree = logicalRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Missing-\(UUID().uuidString)")

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: missingWorktree)
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 43,
            workspaceID: UUID(),
            promptText: "Question",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            tabName: "Missing worktree",
            runID: UUID(),
            activeAgentSessionID: UUID(),
            worktreeBindings: [binding],
            explicitlyBound: false
        )

        do {
            _ = try await ContextBuilderWorkspaceContext.resolve(
                from: snapshot,
                workspaceRepoPaths: [logicalRoot.path],
                workspaceDirectoryPath: logicalRoot.path,
                store: store
            )
            XCTFail("Expected unavailable inherited worktree to fail closed")
        } catch let error as ContextBuilderWorkspaceContextError {
            XCTAssertEqual(error, .unavailableWorktreeProjection)
            XCTAssertFalse(error.localizedDescription.contains(missingWorktree.path))
        }
    }

    func testRequiredLookupRejectsBindingOutsideVisibleWorkspace() async throws {
        let visibleRoot = try makeTemporaryDirectory(name: "VisibleWorkspace")
        let otherLogicalRoot = try makeTemporaryDirectory(name: "OtherLogicalWorkspace")
        let otherWorktreeRoot = try makeTemporaryDirectory(name: "OtherWorktree")
        defer {
            try? FileManager.default.removeItem(at: visibleRoot)
            try? FileManager.default.removeItem(at: otherLogicalRoot)
            try? FileManager.default.removeItem(at: otherWorktreeRoot)
        }

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: visibleRoot.path)
        let binding = makeBinding(logicalRoot: otherLogicalRoot, worktreeRoot: otherWorktreeRoot)

        do {
            _ = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                source: AgentWorkspaceLookupContextSource(
                    activeAgentSessionID: UUID(),
                    worktreeBindings: [binding]
                ),
                store: store
            )
            XCTFail("Expected a binding outside the visible workspace to fail closed")
        } catch let error as AgentWorkspaceLookupContextResolutionError {
            XCTAssertEqual(error.localizedDescription, AgentWorkspaceLookupContextResolutionError.unavailableProjection.localizedDescription)
        }
    }

    private func makeTemporaryDirectory(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeGitBinding(
        logicalRoot: URL,
        worktreeRoot: URL,
        branch: String
    ) throws -> AgentSessionWorktreeBinding {
        let layout = try XCTUnwrap(
            GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: worktreeRoot)
        )
        let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
            commonGitDir: layout.commonDir,
            mainWorktreeRoot: layout.knownMainWorktreeRoot
        )
        let worktreeID = GitWorktreeIdentity.worktreeID(
            repositoryID: repositoryIdentity.repositoryID,
            gitDir: layout.gitDir,
            isMain: false,
            path: layout.workTreeRoot
        )
        return AgentSessionWorktreeBinding(
            id: UUID().uuidString,
            repositoryID: repositoryIdentity.repositoryID,
            repoKey: logicalRoot.path,
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: branch,
            source: "test"
        )
    }

    private func makeBinding(logicalRoot: URL, worktreeRoot: URL) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: UUID().uuidString,
            repositoryID: "repo-id",
            repoKey: logicalRoot.path,
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: UUID().uuidString,
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "feature/context-builder",
            head: "deadbeef",
            source: "test"
        )
    }
}

private final class ContextBuilderReviewDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ContextBuilderReviewDiagnosticEvent] = []

    func append(_ event: ContextBuilderReviewDiagnosticEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [ContextBuilderReviewDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
