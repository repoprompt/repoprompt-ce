import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceOpenFolderOrchestrationTests: XCTestCase {
        private var originalMCPAutoStart = false
        private var originalStoragePath: String?
        private var storageRoot: URL!
        private var managers: [WorkspaceManagerViewModel] = []
        private var domainBridges: [DomainWorkspacePresentationBridge] = []
        private var domainRuntimes: [MCPDomainRuntime] = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("WorkspaceOpenFolderOrchestrationTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
        }

        override func tearDown() async throws {
            domainBridges.forEach { $0.stop() }
            domainBridges.removeAll()
            managers.forEach { $0.prepareForWindowClose() }
            managers.removeAll()
            for runtime in domainRuntimes {
                _ = await runtime.shutdown()
            }
            domainRuntimes.removeAll()
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.removeAllForTesting()
            try? FileManager.default.removeItem(at: storageRoot)
            if let originalStoragePath {
                UserDefaults.standard.set(originalStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testNoMatchCreatesAndActivatesPersistentWorkspace() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "NewProject")
            let countBeforeOpen = manager.workspaces.count

            try await manager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )

            let activeWorkspace = try XCTUnwrap(manager.activeWorkspace)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen + 1)
            XCTAssertEqual(activeWorkspace.repoPaths, [folder.path])
            XCTAssertFalse(activeWorkspace.isEphemeral)
        }

        func testReopeningExistingWorkspacePreservesStateAndInventory() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "ExistingProject")
            let selectedFile = folder.appendingPathComponent("README.md").path
            let preservedTab = ComposeTabState(
                name: "Review",
                selection: StoredSelection(selectedPaths: [selectedFile]),
                promptText: "Preserve this prompt"
            )
            let secondaryTab = ComposeTabState(name: "Follow-up", promptText: "Second tab")
            let preset = WorkspacePreset(
                name: "Review preset",
                selectedFilePaths: [selectedFile]
            )
            let copyPresetID = UUID()
            let existing = WorkspaceModel(
                name: "Existing Project",
                repoPaths: [folder.path],
                presets: [preset],
                activePresetID: preset.id,
                currentPromptText: preservedTab.promptText,
                copyPresetId: copyPresetID,
                composeTabs: [preservedTab, secondaryTab],
                activeComposeTabID: preservedTab.id
            )
            let workspaceFile = try manager.saveWorkspaceToFile(existing)
            await WorkspaceManagerViewModel.WorkspaceDiskWriter.shared.flush(url: workspaceFile)
            manager.workspaces.append(WorkspaceModel(
                id: existing.id,
                dateModified: existing.dateModified,
                name: existing.name,
                repoPaths: existing.repoPaths
            ))
            XCTAssertNotEqual(manager.activeWorkspaceID, existing.id)
            let countBeforeOpen = manager.workspaces.count
            let normalizedVariant = URL(
                fileURLWithPath: folder.path + "/../ExistingProject/"
            )

            try await manager.openWorkspace(
                fromFolderURL: normalizedVariant,
                behavior: .createNewWorkspace
            )

            let reopened = try XCTUnwrap(manager.activeWorkspace)
            XCTAssertEqual(reopened.id, existing.id)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertEqual(reopened.composeTabs, [preservedTab, secondaryTab])
            XCTAssertEqual(reopened.activeComposeTabID, preservedTab.id)
            XCTAssertEqual(reopened.composeTabs.first?.selection.selectedPaths, [selectedFile])
            XCTAssertEqual(reopened.composeTabs.first?.promptText, "Preserve this prompt")
            XCTAssertEqual(reopened.currentPromptText, "Preserve this prompt")
            XCTAssertEqual(reopened.presets, [preset])
            XCTAssertEqual(reopened.activePresetID, preset.id)
            XCTAssertEqual(reopened.copyPresetId, copyPresetID)
        }

        func testReopeningExistingWorkspacePreservesStateThroughDomainAuthority() async throws {
            let runtime = try await makeDomainRuntime()
            let manager = makeManager(domainRuntime: runtime)
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "DomainExistingProject")
            let selectedFile = folder.appendingPathComponent("README.md").path
            let preservedTab = ComposeTabState(
                name: "Review",
                selection: StoredSelection(selectedPaths: [selectedFile]),
                promptText: "Preserve this prompt"
            )
            let secondaryTab = ComposeTabState(name: "Follow-up", promptText: "Second tab")
            let preset = WorkspacePreset(
                name: "Review preset",
                selectedFilePaths: [selectedFile]
            )
            let copyPresetID = UUID()
            let existing = WorkspaceModel(
                name: "Domain Existing Project",
                repoPaths: [folder.path],
                presets: [preset],
                activePresetID: preset.id,
                currentPromptText: preservedTab.promptText,
                copyPresetId: copyPresetID,
                composeTabs: [preservedTab, secondaryTab],
                activeComposeTabID: preservedTab.id
            )

            _ = try await manager.saveWorkspaceToFileAsync(existing)
            try await waitUntil {
                manager.workspace(withID: existing.id)?.composeTabs == [preservedTab, secondaryTab]
            }
            XCTAssertNotEqual(manager.activeWorkspaceID, existing.id)
            let countBeforeOpen = manager.workspaces.count

            try await manager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )

            let reopened = try XCTUnwrap(manager.activeWorkspace)
            XCTAssertEqual(reopened.id, existing.id)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertEqual(reopened.composeTabs, [preservedTab, secondaryTab])
            XCTAssertEqual(reopened.activeComposeTabID, preservedTab.id)
            XCTAssertEqual(reopened.composeTabs.first?.selection.selectedPaths, [selectedFile])
            XCTAssertEqual(reopened.composeTabs.first?.promptText, "Preserve this prompt")
            XCTAssertEqual(reopened.currentPromptText, "Preserve this prompt")
            XCTAssertEqual(reopened.presets, [preset])
            XCTAssertEqual(reopened.activePresetID, preset.id)
            XCTAssertEqual(reopened.copyPresetId, copyPresetID)
        }

        func testActiveMatchedWorkspaceIsSilentNoOp() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "ActiveProject")
            let existing = manager.createWorkspace(
                name: "Active Project",
                repoPaths: [folder.path]
            )
            let initialSwitch = await manager.switchWorkspace(
                to: existing,
                saveState: false,
                reason: "openFolderActiveFixture"
            )
            XCTAssertEqual(initialSwitch, .switched)
            let countBeforeOpen = manager.workspaces.count

            try await manager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )

            XCTAssertEqual(manager.activeWorkspaceID, existing.id)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice)
        }

        func testCancelledMatchedSwitchDoesNotCreateReplacement() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "CancelledProject")
            _ = manager.createWorkspace(
                name: "Cancelled Project",
                repoPaths: [folder.path]
            )
            let activeIDBeforeOpen = manager.activeWorkspaceID
            let countBeforeOpen = manager.workspaces.count
            let sessionProvider = OpenFolderWorkspaceSwitchSessionProvider()
            manager.registerSwitchSessionProvider(sessionProvider)

            let openTask = Task {
                try await manager.openWorkspace(
                    fromFolderURL: folder,
                    behavior: .createNewWorkspace
                )
            }
            let confirmation = try await waitForPendingSwitchConfirmation(in: manager)
            manager.resolveSwitchConfirmation(id: confirmation.id, allow: false)
            try await openTask.value

            XCTAssertEqual(manager.activeWorkspaceID, activeIDBeforeOpen)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertNil(manager.pendingSwitchConfirmation)
            XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice)
        }

        func testBlockedMatchedSwitchDoesNotCreateReplacement() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "BlockedProject")
            _ = manager.createWorkspace(
                name: "Blocked Project",
                repoPaths: [folder.path]
            )
            let activeIDBeforeOpen = manager.activeWorkspaceID
            let countBeforeOpen = manager.workspaces.count
            manager.isRefreshing = true
            defer { manager.isRefreshing = false }

            try await manager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )

            XCTAssertEqual(manager.activeWorkspaceID, activeIDBeforeOpen)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
            XCTAssertEqual(
                manager.pendingWorkspaceSwitchBlockedNotice?.message,
                "Cannot switch workspaces while refresh is in progress."
            )
        }

        func testRankedDuplicateMatchIsActivatedWithoutCreation() async throws {
            let manager = makeManager()
            await manager.awaitInitialized()
            let folder = try makeFolder(named: "RankedProject")
            let older = try WorkspaceModel(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                dateModified: Date(timeIntervalSince1970: 10),
                name: "Older Match",
                repoPaths: [folder.path]
            )
            let newest = try WorkspaceModel(
                id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
                dateModified: Date(timeIntervalSince1970: 20),
                name: "Newest Match",
                repoPaths: [folder.path]
            )
            manager.workspaces.append(contentsOf: [older, newest])
            let countBeforeOpen = manager.workspaces.count

            try await manager.openWorkspace(
                fromFolderURL: folder,
                behavior: .createNewWorkspace
            )

            XCTAssertEqual(manager.activeWorkspaceID, newest.id)
            XCTAssertEqual(manager.workspaces.count, countBeforeOpen)
        }

        private func waitForPendingSwitchConfirmation(
            in manager: WorkspaceManagerViewModel
        ) async throws -> WorkspaceSwitchConfirmation {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while clock.now < deadline {
                if let confirmation = manager.pendingSwitchConfirmation {
                    return confirmation
                }
                try await clock.sleep(for: .milliseconds(10))
            }
            throw WorkspaceOpenFolderOrchestrationTestError.confirmationTimedOut
        }

        private func waitUntil(
            timeout: Duration = .seconds(2),
            condition: @escaping @MainActor () -> Bool
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if condition() {
                    return
                }
                try await clock.sleep(for: .milliseconds(10))
            }
            throw WorkspaceOpenFolderOrchestrationTestError.conditionTimedOut
        }

        private func makeFolder(named name: String) throws -> URL {
            let folder = storageRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        private func makeDomainRuntime() async throws -> MCPDomainRuntime {
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "workspace-open-folder-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            domainRuntimes.append(runtime)
            return runtime
        }

        private func makeManager(domainRuntime: MCPDomainRuntime? = nil) -> WorkspaceManagerViewModel {
            let composition = WindowStateCompositionFactory.make(
                windowID: -1300 - Int.random(in: 1 ... 99),
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                domainRuntime: domainRuntime
            )
            managers.append(composition.workspaceManager)
            if let domainWorkspacePresentationBridge = composition.domainWorkspacePresentationBridge {
                domainBridges.append(domainWorkspacePresentationBridge)
            }
            return composition.workspaceManager
        }
    }

    @MainActor
    private final class OpenFolderWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
        func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
            [WorkspaceSwitchSessionItem(
                id: "open-folder-orchestration",
                count: 1,
                singularLabel: "active session",
                pluralLabel: "active sessions"
            )]
        }

        func cancelSwitchSessions() async {}
    }

    private enum WorkspaceOpenFolderOrchestrationTestError: Error {
        case confirmationTimedOut
        case conditionTimedOut
    }
#endif
