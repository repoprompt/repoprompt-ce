import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class PromptCanonicalCodemapPackagingTests: XCTestCase {
    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testRegularChatPackagingRendersOnlyCanonicalCodemapsExactlyOnce() async throws {
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer {
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        let root = try temporaryRoots.makeRoot(suiteName: "RegularCanonicalCodemap")
        let selectedURL = root.appendingPathComponent("Selected.swift")
        let targetURL = root.appendingPathComponent("Target.swift")
        try FileSystemTestSupport.write(
            "let selectedFullContentSentinel = TargetType()\n",
            to: selectedURL
        )
        try FileSystemTestSupport.write(
            "struct TargetType { func targetFullContentSentinel() {} }\n",
            to: targetURL
        )

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: selectedURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: selectedURL.path,
                    symbolName: "selectedCodemapSymbol",
                    referencedTypes: ["TargetType"]
                )
            ),
            WorkspaceObservedCodemapResult(
                fullPath: targetURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: targetURL.path,
                    symbolName: "targetCodemapSymbol",
                    className: "TargetType"
                )
            )
        ])
        let prompt = makePrompt(store: store, windowID: -9801)
        let config = makeAutoConfig()
        let conversation = [ConversationEntry(role: .user, content: "Inspect the canonical context.")]

        let withoutCanonicalCodemap = await prompt.packagePrompt(
            conversation: conversation,
            overridePromptConfig: config,
            overrideMode: .chat,
            selectionOverride: StoredSelection(
                selectedPaths: [selectedURL.path],
                autoCodemapPaths: [],
                codemapAutoEnabled: false
            ),
            lookupContextOverride: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        )
        XCTAssertFalse(withoutCanonicalCodemap.fileTree.contains("targetCodemapSymbol"))
        XCTAssertFalse(withoutCanonicalCodemap.fileTree.contains("<Referenced APIs>"))

        let canonicalMessage = await prompt.packagePrompt(
            conversation: conversation,
            overridePromptConfig: config,
            overrideMode: .chat,
            selectionOverride: StoredSelection(
                selectedPaths: [selectedURL.path],
                autoCodemapPaths: [targetURL.path],
                codemapAutoEnabled: true
            ),
            lookupContextOverride: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        )
        let packagedContents = canonicalMessage.fileBlocks.joined(separator: "\n")

        XCTAssertEqual(occurrences(of: "targetCodemapSymbol", in: canonicalMessage.fileTree), 1)
        XCTAssertFalse(canonicalMessage.fileTree.contains("<Referenced APIs>"))
        XCTAssertFalse(packagedContents.contains("targetCodemapSymbol"), packagedContents)
        XCTAssertEqual(occurrences(of: "selectedFullContentSentinel", in: packagedContents), 1)
        XCTAssertFalse(packagedContents.contains("targetFullContentSentinel"), packagedContents)
    }

    func testCopyPackagingReadsCanonicalCodemapsFromActiveComposeTabExactlyOnce() async throws {
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer {
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        let root = try temporaryRoots.makeRoot(suiteName: "CopyCanonicalCodemap")
        let selectedURL = root.appendingPathComponent("Selected.swift")
        let targetURL = root.appendingPathComponent("Target.swift")
        try FileSystemTestSupport.write(
            "let selectedCopyContentSentinel = TargetType()\n",
            to: selectedURL
        )
        try FileSystemTestSupport.write(
            "struct TargetType { func targetCopyAPI() { let targetCopyBodySentinel = true } }\n",
            to: targetURL
        )

        let tabID = UUID()
        let emptyCanonicalSelection = StoredSelection(
            selectedPaths: [selectedURL.path],
            autoCodemapPaths: [],
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
        await window.workspaceFileContextStore.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: selectedURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: selectedURL.path,
                    symbolName: "selectedCopyCodemapSymbol",
                    referencedTypes: ["TargetType"]
                )
            ),
            WorkspaceObservedCodemapResult(
                fullPath: targetURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: targetURL.path,
                    symbolName: "targetCopyAPI",
                    className: "TargetType"
                )
            )
        ])

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
            autoCodemapPaths: [targetURL.path],
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
        XCTAssertEqual(capturedSelection.autoCodemapPaths, [targetURL.standardizedFileURL.path])
        let preAssembly = await window.promptManager.preAssemblePromptContext(
            cfg: makeAutoConfig(),
            selection: capturedSelection,
            lookupContext: window.promptManager.allLoadedWorkspaceLookupContext()
        )
        XCTAssertEqual(preAssembly.entries.filter(\.isCodemap).map(\.file.standardizedFullPath), [targetURL.standardizedFileURL.path])
        let canonicalClipboard = await window.promptManager.buildClipboard(
            for: makeAutoConfig(),
            promptTextOverride: ""
        )

        XCTAssertEqual(occurrences(of: "targetCopyAPI", in: canonicalClipboard), 1, canonicalClipboard)
        XCTAssertEqual(occurrences(of: "selectedCopyContentSentinel", in: canonicalClipboard), 1)
        XCTAssertFalse(canonicalClipboard.contains("targetCopyBodySentinel"), canonicalClipboard)
        XCTAssertFalse(canonicalClipboard.contains("<Referenced APIs>"), canonicalClipboard)
    }

    func testFrozenHeadlessPackagingPreservesSlicesAndWorktreeProjectionWithCanonicalCodemap() async throws {
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        defer {
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        let logicalRoot = try temporaryRoots.makeRoot(suiteName: "HeadlessCanonicalLogical")
        let worktreeRoot = try temporaryRoots.makeRoot(suiteName: "HeadlessCanonicalWorktree")
        let logicalSelectedURL = logicalRoot.appendingPathComponent("Sources/Selected.swift")
        let logicalTargetURL = logicalRoot.appendingPathComponent("Sources/Target.swift")
        let worktreeSelectedURL = worktreeRoot.appendingPathComponent("Sources/Selected.swift")
        let worktreeTargetURL = worktreeRoot.appendingPathComponent("Sources/Target.swift")
        try FileSystemTestSupport.write(
            "let canonicalFullContentSentinel = true\n",
            to: logicalSelectedURL
        )
        try FileSystemTestSupport.write(
            "struct CanonicalTarget {}\n",
            to: logicalTargetURL
        )
        try FileSystemTestSupport.write(
            "let excludedBeforeSlice = true\nlet selectedWorktreeSlice = TargetType()\nlet excludedAfterSlice = true\n",
            to: worktreeSelectedURL
        )
        try FileSystemTestSupport.write(
            "struct TargetType { func targetFullContentSentinel() {} }\n",
            to: worktreeTargetURL
        )

        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: logicalRoot.path)
        let worktreeRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: worktreeTargetURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: worktreeTargetURL.path,
                    symbolName: "worktreeTargetCodemapSymbol",
                    className: "TargetType"
                )
            )
        ])

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
        let message = await prompt.buildHeadlessAIMessage(
            from: HeadlessContextSnapshot(
                tabID: UUID(),
                promptText: "Inspect the frozen worktree context.",
                selection: StoredSelection(
                    selectedPaths: [logicalSelectedURL.path],
                    autoCodemapPaths: [logicalTargetURL.path],
                    slices: [logicalSelectedURL.path: [LineRange(start: 2, end: 2)]],
                    codemapAutoEnabled: true
                ),
                lookupContext: lookupContext
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
        XCTAssertEqual(occurrences(of: "worktreeTargetCodemapSymbol", in: message.fileTree), 1)
        XCTAssertFalse(message.fileTree.contains("<Referenced APIs>"), message.fileTree)
        XCTAssertFalse(message.fileTree.contains(worktreeRoot.standardizedFileURL.path), message.fileTree)
        XCTAssertFalse(packagedContents.contains("worktreeTargetCodemapSymbol"), packagedContents)
        XCTAssertFalse(packagedContents.contains("targetFullContentSentinel"), packagedContents)
    }

    private func makeWindow(
        root: URL,
        tabID: UUID,
        selection: StoredSelection
    ) async -> (window: WindowState, workspaceID: UUID) {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
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

    private func makeFileAPI(
        path: String,
        symbolName: String,
        className: String? = nil,
        referencedTypes: [String] = []
    ) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: className.map { [ClassInfo(name: $0, methods: [], properties: [])] } ?? [],
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: referencedTypes
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
