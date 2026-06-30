@testable import RepoPrompt
import XCTest

final class AgentFileTagWorktreeResolutionTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    @MainActor
    func testExpandedBoundWorktreeSuggestionUsesLogicalPathAndSubtitle() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: true)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let configuration = FileMentionPickerConfiguration.expanded
        let service = AgentFileTagSuggestionService(
            store: fixture.store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { lookupContext },
            maxResults: configuration.maxResults,
            showsFileSubtitles: configuration.showsFileSubtitles
        )

        let suggestions = await service.suggestions(for: "BranchOnly")
        let suggestion = try XCTUnwrap(suggestions.first { $0.relativePath == "Sources/BranchOnly.swift" })

        XCTAssertEqual(suggestion.subtitle, "Sources")
        XCTAssertEqual(suggestion.commitDisplayText, suggestion.relativePath)
        XCTAssertFalse(suggestions.contains { $0.relativePath.contains(".worktrees") }, String(describing: suggestions))
        XCTAssertFalse(suggestions.contains { $0.relativePath.contains(fixture.worktreeRoot.path) }, String(describing: suggestions))
    }

    @MainActor
    func testUnboundSuggestionDoesNotReadHiddenSessionWorktreeRoots() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: true)
        _ = await makeLookupContext(fixture: fixture) // Materializes the hidden session worktree root in the store.
        let service = AgentFileTagSuggestionService(
            store: fixture.store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: 5
        )

        let suggestions = await service.suggestions(for: "BranchOnly")

        XCTAssertTrue(suggestions.isEmpty, String(describing: suggestions))
    }

    func testProviderTaggedFileContentReadsWorktreeButDisplaysLogicalPathAndDedupes() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let physicalWorktreePath = fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").path

        let resolvedXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            ["Sources/App.swift", physicalWorktreePath],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: lookupContext
        )
        let xml = try XCTUnwrap(resolvedXML)

        XCTAssertTrue(xml.contains("File: Sources/App.swift"), xml)
        XCTAssertTrue(xml.contains("let origin = \"worktree\""), xml)
        XCTAssertFalse(xml.contains("let origin = \"base\""), xml)
        XCTAssertFalse(xml.contains(fixture.worktreeRoot.path), xml)
        XCTAssertEqual(xml.components(separatedBy: "let origin = \"worktree\"").count - 1, 1, xml)
    }

    func testPromotionLogicalizesStalePhysicalSelectionAndDedupesByEffectivePhysicalPath() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let physicalPath = fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").path
        let logicalPath = fixture.logicalRoot.appendingPathComponent("Sources/App.swift").path
        let staleSelection = StoredSelection(
            selectedPaths: [physicalPath],

            slices: [physicalPath: [LineRange(start: 1, end: 1)]],
            codemapAutoEnabled: false
        )

        let updated = AgentModeViewModel.selectionByPromotingPathsToFullSelection(
            staleSelection,
            paths: [logicalPath],
            lookupContext: lookupContext
        )

        XCTAssertEqual(updated.selectedPaths, [logicalPath])
        XCTAssertTrue(updated.slices.isEmpty)
        XCTAssertFalse(updated.selectedPaths.contains { $0.contains(fixture.worktreeRoot.path) })
    }

    @MainActor
    func testExpandedAgentFileTagsReturnMoreThanCompactCapWithParentSubtitles() async throws {
        let root = try makeTemporaryRoot(name: "AgentFileTagExpanded")
        let matchingFileCount = 80
        for index in 0 ..< matchingFileCount {
            let name = String(format: "Match%02d.swift", index)
            try write("let match\(index) = true\n", to: root.appendingPathComponent("Sources/\(name)"))
        }
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let config = FileMentionPickerConfiguration.expanded
        let service = AgentFileTagSuggestionService(
            store: store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: config.maxResults,
            showsFileSubtitles: config.showsFileSubtitles
        )

        let suggestions = await service.suggestions(for: "Match")

        XCTAssertEqual(suggestions.count, matchingFileCount, String(describing: suggestions))
        XCTAssertTrue(suggestions.count > FileMentionPickerConfiguration.compact.maxResults)
        XCTAssertTrue(suggestions.count > 64)
        XCTAssertTrue(suggestions.allSatisfy { $0.kind == .file })
        XCTAssertEqual(Set(suggestions.compactMap(\.subtitle)), ["Sources"])
        XCTAssertTrue(suggestions.allSatisfy { $0.commitDisplayText == $0.relativePath })
        XCTAssertTrue(suggestions.allSatisfy { $0.commitDisplayText?.hasPrefix("Sources/Match") == true })
    }

    @MainActor
    func testCompactAgentFileTagsPreserveDuplicateDisambiguationSubtitles() async throws {
        let firstRoot = try makeTemporaryRoot(name: "AgentFileTagDuplicateA")
        let secondRoot = try makeTemporaryRoot(name: "AgentFileTagDuplicateB")
        try write("let duplicate = \"a\"\n", to: firstRoot.appendingPathComponent("Sources/Shared.swift"))
        try write("let duplicate = \"b\"\n", to: secondRoot.appendingPathComponent("Sources/Shared.swift"))
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: firstRoot.path)
        _ = try await store.loadRoot(path: secondRoot.path)
        let service = AgentFileTagSuggestionService(
            store: store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: FileMentionPickerConfiguration.compact.maxResults,
            showsFileSubtitles: FileMentionPickerConfiguration.compact.showsFileSubtitles
        )

        let suggestions = await service.suggestions(for: "Shared")

        XCTAssertEqual(suggestions.count, 2, String(describing: suggestions))
        XCTAssertEqual(
            Set(suggestions.compactMap(\.subtitle)),
            [firstRoot.lastPathComponent, secondRoot.lastPathComponent]
        )
        XCTAssertTrue(suggestions.allSatisfy { $0.commitDisplayText == $0.relativePath })
        XCTAssertTrue(suggestions.allSatisfy { $0.commitDisplayText?.hasSuffix("Sources/Shared.swift") == true })
        XCTAssertFalse(suggestions.contains { $0.commitDisplayText?.hasPrefix("/") == true })
        XCTAssertFalse(suggestions.contains { $0.commitDisplayText?.contains(firstRoot.path) == true })
        XCTAssertFalse(suggestions.contains { $0.commitDisplayText?.contains(secondRoot.path) == true })
    }

    @MainActor
    func testSameNamedVisibleRootsUseNonAbsoluteResolvableFileTagPaths() async throws {
        let fixture = try makeSameNamedRootFixture()
        let selectedFile = fixture.secondRoot.appendingPathComponent("Sources/Target.swift")
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: fixture.firstRoot.path)
        _ = try await store.loadRoot(path: fixture.secondRoot.path)
        let host = FileTagSelectionHost(selection: StoredSelection(selectedPaths: [selectedFile.path]))
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: host, store: store)
        let service = AgentFileTagSuggestionService(
            store: store,
            searchService: nil,
            selectionCoordinator: coordinator,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: 5
        )

        let searchSuggestions = await service.suggestions(for: "Target")
        let searchTokenPaths = Set(searchSuggestions.map(\.relativePath))
        let fallbackSuggestions = await service.suggestions(for: "")
        let fallbackSuggestion = try XCTUnwrap(fallbackSuggestions.first)
        let expectedSecondToken = "B/SharedRoot/Sources/Target.swift"

        XCTAssertEqual(
            searchTokenPaths,
            ["A/SharedRoot/Sources/Target.swift", expectedSecondToken],
            String(describing: searchSuggestions)
        )
        XCTAssertEqual(fallbackSuggestion.relativePath, expectedSecondToken)
        XCTAssertEqual(fallbackSuggestion.commitDisplayText, expectedSecondToken)
        XCTAssertEqual(
            FileTagMentionHelper.committedReplacementText(for: fallbackSuggestion),
            "@B/SharedRoot/Sources/Target.swift "
        )
        XCTAssertEqual(AgentFileMentionText.attachmentDisplayName(for: fallbackSuggestion), expectedSecondToken)

        let allTokenText = searchSuggestions.flatMap { [$0.relativePath, $0.commitDisplayText ?? ""] } + [fallbackSuggestion.relativePath, fallbackSuggestion.commitDisplayText ?? ""]
        XCTAssertFalse(allTokenText.contains { $0.hasPrefix("/") }, allTokenText.joined(separator: "\n"))
        XCTAssertFalse(allTokenText.contains { $0.contains(fixture.base.path) }, allTokenText.joined(separator: "\n"))

        let resolvedXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            [expectedSecondToken],
            tokenBudget: 10000,
            maxFiles: 10,
            store: store
        )
        let xml = try XCTUnwrap(resolvedXML)

        XCTAssertTrue(xml.contains("File: \(expectedSecondToken)"), xml)
        XCTAssertTrue(xml.contains("let target = \"b\""), xml)
        XCTAssertFalse(xml.contains(fixture.base.path), xml)
    }

    func testSameNamedRootGeneratedAliasTakesPrecedenceOverShadowingRootAlias() async throws {
        let fixture = try makeSameNamedRootFixture()
        let shadowRoot = fixture.base.appendingPathComponent("Shadow/B", isDirectory: true)
        try write("let target = \"shadow\"\n", to: shadowRoot.appendingPathComponent("SharedRoot/Sources/Target.swift"))
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: fixture.firstRoot.path)
        _ = try await store.loadRoot(path: fixture.secondRoot.path)
        _ = try await store.loadRoot(path: shadowRoot.path)
        let generatedToken = "B/SharedRoot/Sources/Target.swift"

        let resolvedXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            [generatedToken],
            tokenBudget: 10000,
            maxFiles: 10,
            store: store
        )
        let xml = try XCTUnwrap(resolvedXML)

        XCTAssertTrue(xml.contains("File: \(generatedToken)"), xml)
        XCTAssertTrue(xml.contains("let target = \"b\""), xml)
        XCTAssertFalse(xml.contains("let target = \"shadow\""), xml)
        XCTAssertFalse(xml.contains(fixture.base.path), xml)
    }

    @MainActor
    func testSelectedFileFallbackCommitsPathfulSameBasenameFile() async throws {
        let root = try makeTemporaryRoot(name: "AgentFileTagSelectedFallback")
        try write("# first\n", to: root.appendingPathComponent("skills/writing/SKILL.md"))
        let selectedFile = root.appendingPathComponent("skills/engineering/tidy-first/SKILL.md")
        try write("# selected\n", to: selectedFile)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let host = FileTagSelectionHost(selection: StoredSelection(selectedPaths: [selectedFile.path]))
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: host, store: store)
        let service = AgentFileTagSuggestionService(
            store: store,
            searchService: nil,
            selectionCoordinator: coordinator,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: 5
        )

        let suggestions = await service.suggestions(for: "")
        let suggestion = try XCTUnwrap(suggestions.first)

        XCTAssertEqual(suggestions.count, 1, String(describing: suggestions))
        XCTAssertEqual(suggestion.displayName, "SKILL.md")
        XCTAssertEqual(suggestion.relativePath, "skills/engineering/tidy-first/SKILL.md")
        XCTAssertEqual(suggestion.commitDisplayText, suggestion.relativePath)
    }

    func testAgentFileMentionDisplayNamePrefersRelativePathOverBasenameDisplay() {
        let suggestion = MentionSuggestion(
            displayName: "SKILL.md",
            relativePath: "aAtila/skills/engineering/tidy-first/SKILL.md",
            kind: .file,
            commitDisplayText: "SKILL.md"
        )

        XCTAssertEqual(
            AgentFileMentionText.attachmentDisplayName(for: suggestion),
            "aAtila/skills/engineering/tidy-first/SKILL.md"
        )
    }

    func testAgentFileMentionRemovalRemovesPathfulInlineMention() {
        let path = "aAtila/skills/engineering/tidy-first/SKILL.md"
        let text = "Review @\(path) before continuing"

        let reduced = AgentFileMentionText.removingTaggedMention(
            displayName: path,
            relativePath: path,
            from: text
        )

        XCTAssertEqual(reduced, "Review before continuing")
    }

    @MainActor
    func testPartiallyBoundWorkspaceKeepsUnboundRootSuggestionDisplayRelative() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let unboundRoot = try makeTemporaryRoot(name: "AgentFileTagUnbound")
        try write("let unbound = true\n", to: unboundRoot.appendingPathComponent("Sources/Other.swift"))
        _ = try await fixture.store.loadRoot(path: unboundRoot.path)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let service = AgentFileTagSuggestionService(
            store: fixture.store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { lookupContext },
            maxResults: 5
        )

        let suggestions = await service.suggestions(for: "Other")
        let suggestion = try XCTUnwrap(suggestions.first { $0.relativePath.contains("Other.swift") })
        let logicalRootQualifiedSuggestions = await service.suggestions(for: "\(fixture.logicalRoot.lastPathComponent)/Sources/App")

        XCTAssertEqual(suggestion.commitDisplayText, suggestion.relativePath)
        XCTAssertFalse(suggestion.relativePath.hasPrefix("/"), String(describing: suggestions))
        XCTAssertFalse(suggestion.relativePath.contains(unboundRoot.path), String(describing: suggestions))
        XCTAssertFalse(suggestion.commitDisplayText?.contains(unboundRoot.path) == true, String(describing: suggestions))
        XCTAssertTrue(
            logicalRootQualifiedSuggestions.contains { $0.relativePath.contains("Sources/App.swift") },
            String(describing: logicalRootQualifiedSuggestions)
        )
        XCTAssertFalse(
            logicalRootQualifiedSuggestions.contains { $0.relativePath.contains(fixture.worktreeRoot.path) },
            String(describing: logicalRootQualifiedSuggestions)
        )
    }

    func testPartiallyBoundWorkspaceKeepsUnboundRootProviderDisplayRelative() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let unboundRoot = try makeTemporaryRoot(name: "AgentFileTagProviderUnbound")
        let unboundFile = unboundRoot.appendingPathComponent("Sources/Other.swift")
        try write("let unbound = true\n", to: unboundFile)
        _ = try await fixture.store.loadRoot(path: unboundRoot.path)
        let lookupContext = await makeLookupContext(fixture: fixture)

        let resolvedXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            [unboundFile.path],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: lookupContext
        )
        let xml = try XCTUnwrap(resolvedXML)

        XCTAssertTrue(xml.contains("let unbound = true"), xml)
        XCTAssertFalse(xml.contains(unboundRoot.path), xml)
    }

    func testNonWorktreeProviderTaggedFileContentPreservesVisibleWorkspaceBehavior() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: true)
        _ = await makeLookupContext(fixture: fixture) // Keep hidden worktree loaded; visible lookups must still ignore it.

        let resolvedVisibleXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            ["Sources/App.swift"],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: .visibleWorkspace
        )
        let visibleXML = try XCTUnwrap(resolvedVisibleXML)
        let hiddenXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            ["Sources/BranchOnly.swift"],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: .visibleWorkspace
        )

        XCTAssertTrue(visibleXML.contains("let origin = \"base\""), visibleXML)
        XCTAssertFalse(visibleXML.contains("let origin = \"worktree\""), visibleXML)
        XCTAssertNil(hiddenXML)
    }

    private func makeBoundFixture(includeBranchOnly: Bool) async throws -> (
        logicalRoot: URL,
        worktreeRoot: URL,
        store: WorkspaceFileContextStore,
        sessionID: UUID,
        binding: AgentSessionWorktreeBinding
    ) {
        let logicalRoot = try makeTemporaryRoot(name: "AgentFileTagLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "AgentFileTagWorktree")
        try write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))
        try write("let origin = \"worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/App.swift"))
        if includeBranchOnly {
            try write("let branchOnly = true\n", to: worktreeRoot.appendingPathComponent("Sources/BranchOnly.swift"))
        }

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let sessionID = UUID()
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)
        return (logicalRoot, worktreeRoot, store, sessionID, binding)
    }

    private func makeLookupContext(
        fixture: (
            logicalRoot: URL,
            worktreeRoot: URL,
            store: WorkspaceFileContextStore,
            sessionID: UUID,
            binding: AgentSessionWorktreeBinding
        )
    ) async -> WorkspaceLookupContext {
        await AgentWorkspaceLookupContextResolver.lookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: fixture.sessionID,
                worktreeBindings: [fixture.binding]
            ),
            store: fixture.store
        )
    }

    private func makeBinding(logicalRoot: URL, worktreeRoot: URL) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "bind_test",
            repositoryID: "repo_test",
            repoKey: "repo",
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: "worktree_test",
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "feature/test",
            head: "abcdef",
            visualLabel: "test",
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123),
            source: "test"
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func makeSameNamedRootFixture() throws -> (base: URL, firstRoot: URL, secondRoot: URL) {
        let base = try makeTemporaryRoot(name: "AgentFileTagSameNamedRoots")
        let firstRoot = base.appendingPathComponent("A/SharedRoot", isDirectory: true)
        let secondRoot = base.appendingPathComponent("B/SharedRoot", isDirectory: true)
        try write("let target = \"a\"\n", to: firstRoot.appendingPathComponent("Sources/Target.swift"))
        try write("let target = \"b\"\n", to: secondRoot.appendingPathComponent("Sources/Target.swift"))
        return (base, firstRoot, secondRoot)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

@MainActor
private final class FileTagSelectionHost: WorkspaceSelectionHost {
    var activeWorkspace: WorkspaceModel?
    var selectionMirrorContextRevision: UInt64 = 0

    init(selection: StoredSelection) {
        let tabID = UUID()
        let tab = ComposeTabState(id: tabID, name: "Agent", selection: selection)
        activeWorkspace = WorkspaceModel(
            id: UUID(),
            name: "Agent File Tags",
            repoPaths: [],
            composeTabs: [tab],
            activeComposeTabID: tabID
        )
    }

    func composeTab(with id: UUID) -> ComposeTabState? {
        activeWorkspace?.composeTabs.first { $0.id == id }
    }

    func composeTab(for identity: WorkspaceSelectionIdentity) -> ComposeTabState? {
        guard activeWorkspace?.id == identity.workspaceID else { return nil }
        return activeWorkspace?.composeTabs.first { $0.id == identity.tabID }
    }

    func publishActiveComposeTabSnapshot(commitToMemory _: Bool, touchModified _: Bool) {}

    @discardableResult
    func updateComposeTabStoredOnly(_ tab: ComposeTabState, inWorkspaceID workspaceID: UUID) -> Bool {
        guard var workspace = activeWorkspace, workspace.id == workspaceID,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        workspace.composeTabs[index] = tab
        activeWorkspace = workspace
        return true
    }

    func applySelectionMirrorAttempt(_: StoredSelection, forTabID _: UUID, workspaceID _: UUID) async {}
}
