import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class PromptCanonicalCodemapPackagingTests: XCTestCase {
    func testRegularChatPackagingOmitsIncompleteAutomaticCodemapWithoutLegacyFallback() async throws {
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer {
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        defer { repositoryFixture.cleanup() }
        let root = try repositoryFixture.makeRepository(
            named: "regular-canonical",
            files: [
                "Selected.swift": "protocol SelectedContext { func selectedFullContentSentinel() -> TargetType }\n",
                "Target.swift": "struct TargetType { func targetFullContentSentinel() {} }\n"
            ]
        )
        let selectedURL = root.appendingPathComponent("Selected.swift")

        let store = WorkspaceFileContextStore(
            codemapGitEligibilityProbe: .init { _ in
                .transientUnavailable(.repositoryChanging)
            },
            codemapProjectionPreloadLaunchPolicyForTesting: .disabled
        )
        _ = try await store.loadRoot(path: root.path)
        let prompt = makePrompt(store: store, windowID: -9801)
        let config = makeAutoConfig()
        let conversation = [ConversationEntry(role: .user, content: "Inspect the canonical context.")]

        let withoutCanonicalCodemap = await prompt.packagePrompt(
            conversation: conversation,
            overridePromptConfig: config,
            overrideMode: .chat,
            selectionOverride: StoredSelection(
                selectedPaths: [selectedURL.path],

                codemapAutoEnabled: false
            ),
            lookupContextOverride: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        )
        XCTAssertFalse(withoutCanonicalCodemap.fileTree.contains("targetFullContentSentinel"))
        XCTAssertFalse(withoutCanonicalCodemap.fileTree.contains("<Referenced APIs>"))

        let canonicalMessage = await prompt.packagePrompt(
            conversation: conversation,
            overridePromptConfig: config,
            overrideMode: .chat,
            selectionOverride: StoredSelection(
                selectedPaths: [selectedURL.path],

                codemapAutoEnabled: true
            ),
            lookupContextOverride: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        )
        let packagedContents = canonicalMessage.fileBlocks.joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "targetFullContentSentinel", in: canonicalMessage.fileTree), 0)
        XCTAssertFalse(canonicalMessage.fileTree.contains("<Referenced APIs>"))
        XCTAssertFalse(packagedContents.contains("targetFullContentSentinel"), packagedContents)
        XCTAssertEqual(occurrences(of: "selectedFullContentSentinel", in: packagedContents), 1)
        XCTAssertFalse(packagedContents.contains("targetFullContentSentinel"), packagedContents)
    }

    func testCopyPackagingOmitsIncompleteAutomaticCodemapWithoutLegacyFallback() async throws {
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer {
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        defer { repositoryFixture.cleanup() }
        let root = try repositoryFixture.makeRepository(
            named: "copy-canonical",
            files: [
                "Selected.swift": "protocol SelectedCopyContext { func selectedCopyContentSentinel() -> TargetType }\n",
                "Target.swift": "struct TargetType { func targetCopyAPI() { let targetCopyBodySentinel = true } }\n"
            ]
        )
        let selectedURL = root.appendingPathComponent("Selected.swift")

        let tabID = UUID()
        let emptyCanonicalSelection = StoredSelection(
            selectedPaths: [selectedURL.path],

            codemapAutoEnabled: false
        )
        let (window, _) = await makeWindow(
            root: root,
            tabID: tabID,
            selection: emptyCanonicalSelection
        )
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )

        _ = await window.selectionCoordinator.persistActiveSelection(
            emptyCanonicalSelection,
            mirrorToUI: false
        )
        await window.selectionCoordinator.mirrorSelectionToActiveUI(
            emptyCanonicalSelection,
            forTabID: tabID
        )
        let withoutCanonicalCodemap = await window.promptManager.buildClipboard(
            for: makeAutoConfig(),
            promptTextOverride: ""
        )
        XCTAssertFalse(withoutCanonicalCodemap.contains("targetCopyAPI"))
        XCTAssertFalse(withoutCanonicalCodemap.contains("<Referenced APIs>"))

        let canonicalSelection = StoredSelection(
            selectedPaths: [selectedURL.path],

            codemapAutoEnabled: true
        )
        _ = await window.selectionCoordinator.persistActiveSelection(
            canonicalSelection,
            mirrorToUI: false
        )
        await window.selectionCoordinator.mirrorSelectionToActiveUI(
            canonicalSelection,
            forTabID: tabID
        )
        let capturedSelection = window.selectionCoordinator.activeSelectionSnapshot(
            flushPendingUI: true
        ).selection
        let preAssembly = await window.promptManager.preAssemblePromptContext(
            cfg: makeAutoConfig(),
            selection: capturedSelection,
            lookupContext: window.promptManager.allLoadedWorkspaceLookupContext()
        )
        XCTAssertTrue(preAssembly.entries.filter(\.isCodemap).isEmpty)
        switch preAssembly.codemapPresentation.coverage {
        case .complete, .partial:
            XCTFail("Cold automatic codemap coverage must remain honestly incomplete")
        case .pending, .unavailable:
            break
        }
        let canonicalClipboard = await window.promptManager.buildClipboard(
            for: makeAutoConfig(),
            promptTextOverride: ""
        )

        XCTAssertEqual(occurrences(of: "targetCopyAPI", in: canonicalClipboard), 0, canonicalClipboard)
        XCTAssertEqual(occurrences(of: "selectedCopyContentSentinel", in: canonicalClipboard), 1)
        XCTAssertFalse(canonicalClipboard.contains("targetCopyBodySentinel"), canonicalClipboard)
        XCTAssertFalse(canonicalClipboard.contains("<Referenced APIs>"), canonicalClipboard)
    }

    func testHeadlessPackagingPreservesSlicesWhenAutomaticCodemapIsIncomplete() async throws {
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer {
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        let repositoryFixture = try ReviewGitRepositoryFixture(name: #function)
        defer { repositoryFixture.cleanup() }
        let logicalRoot = try repositoryFixture.makeRepository(
            named: "headless-logical",
            files: [
                "Sources/Selected.swift": "let canonicalFullContentSentinel = true\n",
                "Sources/Target.swift": "struct CanonicalTarget {}\n"
            ]
        )
        let worktreeRoot = try repositoryFixture.makeRepository(
            named: "headless-worktree",
            files: [
                "Sources/Selected.swift": "let excludedBeforeSlice = true\nfunc selectedWorktreeSlice() -> TargetType { TargetType() }\nlet excludedAfterSlice = true\n",
                "Sources/Target.swift": "struct TargetType { func targetFullContentSentinel() {} }\n"
            ]
        )
        let logicalSelectedURL = logicalRoot.appendingPathComponent("Sources/Selected.swift")

        let store = WorkspaceFileContextStore(
            codemapGitEligibilityProbe: .init { _ in
                .transientUnavailable(.repositoryChanging)
            },
            codemapProjectionPreloadLaunchPolicyForTesting: .disabled
        )
        let logicalRecord = try await store.loadRoot(path: logicalRoot.path)
        let worktreeRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)

        let logicalRootRef = WorkspaceRootRef(
            id: logicalRecord.id,
            name: logicalRecord.name,
            fullPath: logicalRecord.standardizedFullPath
        )
        let worktreeRootRef = WorkspaceRootRef(
            id: worktreeRecord.id,
            name: logicalRecord.name,
            fullPath: worktreeRecord.standardizedFullPath
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRootRef,
                    physicalRoot: worktreeRootRef,
                    binding: AgentSessionWorktreeBinding(
                        id: "headless-canonical-binding",
                        repositoryID: "headless-canonical-repository",
                        repoKey: "headless-canonical-repo",
                        logicalRootPath: logicalRoot.path,
                        logicalRootName: logicalRecord.name,
                        worktreeID: "headless-canonical-worktree",
                        worktreeRootPath: worktreeRoot.path,
                        source: "test"
                    )
                )
            ],
            visibleLogicalRoots: [logicalRootRef]
        )
        let lookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let prompt = makePrompt(store: store, windowID: -9802)
        let message = try await prompt.buildHeadlessAIMessage(
            from: HeadlessContextSnapshot(
                tabID: UUID(),
                promptText: "Inspect the frozen worktree context.",
                selection: StoredSelection(
                    selectedPaths: [logicalSelectedURL.path],

                    slices: [logicalSelectedURL.path: [LineRange(start: 2, end: 2)]],
                    codemapAutoEnabled: true
                ),
                lookupContext: lookupContext,
                reviewGitContext: .automaticOnly()
            ),
            model: prompt.preferredAIModel,
            mode: .plan
        )
        let packagedContents = message.fileBlocks.joined(separator: "\n")

        XCTAssertEqual(message.fileBlocks.count, 1)
        XCTAssertTrue(packagedContents.contains("(lines 2)"), packagedContents)
        XCTAssertTrue(packagedContents.contains("selectedWorktreeSlice"), packagedContents)
        XCTAssertFalse(packagedContents.contains("excludedBeforeSlice"), packagedContents)
        XCTAssertFalse(packagedContents.contains("excludedAfterSlice"), packagedContents)
        XCTAssertFalse(packagedContents.contains("canonicalFullContentSentinel"), packagedContents)
        XCTAssertFalse(packagedContents.contains(worktreeRoot.standardizedFileURL.path), packagedContents)
        XCTAssertEqual(occurrences(of: "targetFullContentSentinel", in: message.fileTree), 0)
        XCTAssertFalse(message.fileTree.contains("<Referenced APIs>"), message.fileTree)
        XCTAssertFalse(message.fileTree.contains(worktreeRoot.standardizedFileURL.path), message.fileTree)
        XCTAssertFalse(packagedContents.contains("targetFullContentSentinel"), packagedContents)
        XCTAssertFalse(packagedContents.contains("targetFullContentSentinel"), packagedContents)
    }

    private func makeWindow(
        root: URL,
        tabID: UUID,
        selection: StoredSelection
    ) async -> (window: WindowState, workspaceID: UUID) {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState(
            workspaceFileContextStore: WorkspaceFileContextStore(
                codemapGitEligibilityProbe: .init { _ in
                    .transientUnavailable(.repositoryChanging)
                },
                codemapProjectionPreloadLaunchPolicyForTesting: .disabled
            )
        )
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = WorkspaceModel(
            name: "Copy Canonical Codemap \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: "Copy", selection: selection)],
            activeComposeTabID: tabID
        )
        window.workspaceManager.workspaces = [workspace]
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "promptCanonicalCodemapPackagingTests"
        )
        window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
        return (window, workspace.id)
    }

    private func makePrompt(store: WorkspaceFileContextStore, windowID: Int) -> PromptViewModel {
        let secureService = SecureKeysService(secureStorage: TestSecureStorageBackend())
        let keyManager = KeyManager(secureService: secureService)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        return PromptViewModel(
            fileManager: WorkspaceFilesViewModel(workspaceFileContextStore: store),
            apiSettingsViewModel: apiSettings,
            windowID: windowID,
            settingsManager: WindowSettingsManager(windowID: windowID)
        )
    }

    private func makeAutoConfig() -> PromptContextResolved {
        PromptContextResolved(
            includeFiles: true,
            includeUserPrompt: true,
            includeMetaPrompts: false,
            includeFileTree: true,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: .none,
            storedPromptIds: []
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
