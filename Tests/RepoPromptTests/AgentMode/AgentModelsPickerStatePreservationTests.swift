import AppKit
import Combine
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import SwiftUI
import XCTest

@MainActor
final class AgentModelsPickerStatePreservationTests: XCTestCase {
    func testPickerActionPreservesDirtyOverlaysAndPersistsOnlyModelSelection() async throws {
        let store = try makeStore()
        let workspaceID = UUID()
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile(.gpt56SolLow))
        let window = makeWindow(store: store, workspaceID: workspaceID)
        await finishNotificationDelivery()
        let persistedCopy = try encoded(store.copySettings(for: workspaceID))
        let persistedChat = store.chatSettings(for: workspaceID)
        let dirty = try dirtyOverlays(window, workspaceID: workspaceID)

        var broadEvents = 0
        var scopedEvents = 0
        let broad = NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter { $0.userInfo?[AgentModelsSettingsNotification.sourceWorkspaceIDKey] as? UUID == workspaceID }
            .sink { _ in broadEvents += 1 }
        let scoped = NotificationCenter.default.publisher(for: .agentModelsSettingsDidChange)
            .filter { ($0.object as? GlobalSettingsStore) === store }
            .filter { $0.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID == workspaceID }
            .sink { _ in scopedEvents += 1 }
        defer { broad.cancel()
            scoped.cancel()
        }

        _ = NSApplication.shared // Establish AppKit's action dispatcher; do not launch a visible app.
        let view = AgentModelsPopoverView(promptViewModel: window.prompt, apiSettingsVM: window.api, windowID: -574)
        let menu = NSMenu.stableMenu(from: view.contextBuilderAgentModelMenuItems())
        let codexMenu = try XCTUnwrap(menu.items.first { $0.title == AgentProviderKind.codexExec.displayName }?.submenu)
        let option = try XCTUnwrap(window.prompt.contextBuilderModelOptions(for: .codexExec).first {
            $0.rawValue == AgentModel.gpt56SolHigh.rawValue
        })
        let item = try XCTUnwrap(actionItem(titled: option.displayName, in: codexMenu))
        let owner = try XCTUnwrap(item.menu)
        XCTAssertTrue(item.isEnabled)
        owner.performActionForItem(at: owner.index(of: item))
        await finishNotificationDelivery()

        XCTAssertEqual(broadEvents, 0, "A picker action is not a recommendation application.")
        XCTAssertGreaterThan(scopedEvents, 0)
        try assertOverlays(window, workspaceID: workspaceID, equal: dirty)
        XCTAssertEqual(window.prompt.contextBuilderAgentModelRaw, option.rawValue)
        XCTAssertTrue(store.reloadFromDisk(), "Verify the actual saved profile, not only its in-memory projection.")
        XCTAssertEqual(store.effectiveAgentModelsProfile(workspaceID: workspaceID).contextBuilderModelsByAgent?[AgentProviderKind.codexExec.rawValue], option.rawValue)
        XCTAssertEqual(try encoded(store.copySettings(for: workspaceID)), persistedCopy)
        XCTAssertEqual(store.chatSettings(for: workspaceID), persistedChat)
    }

    func testExternalScopedUpdatesReachApplicableWindowsWithoutDiscardingOverlays() async throws {
        let store = try makeStore()
        store.setGlobalAgentModelsProfile(profile(.gpt56SolLow), contextBuilderWriteIntent: .userInitiated)
        let workspaceID = UUID()
        let unrelatedID = UUID()
        let inheritedID = UUID()
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile(.gpt56SolLow))
        store.setWorkspaceAgentModelsProfile(workspaceID: unrelatedID, profile: profile(.gpt56SolLow))
        let first = makeWindow(store: store, workspaceID: workspaceID)
        let second = makeWindow(store: store, workspaceID: workspaceID)
        let unrelated = makeWindow(store: store, workspaceID: unrelatedID)
        let inherited = makeWindow(store: store, workspaceID: inheritedID)
        let windows = [(first, workspaceID), (second, workspaceID), (unrelated, unrelatedID), (inherited, inheritedID)]
        await finishNotificationDelivery()
        let dirty = try windows.map { try dirtyOverlays($0.0, workspaceID: $0.1) }

        // An external writer changes the shared authority, not either PromptVM.
        store.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: profile(.gpt56SolHigh))
        await finishNotificationDelivery()
        XCTAssertEqual(first.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolHigh.rawValue)
        XCTAssertEqual(second.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolHigh.rawValue)
        XCTAssertEqual(unrelated.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolLow.rawValue)
        XCTAssertEqual(inherited.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolLow.rawValue)

        store.setGlobalAgentModelsProfile(profile(.gpt56SolMedium), contextBuilderWriteIntent: .userInitiated)
        await finishNotificationDelivery()
        XCTAssertEqual(inherited.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolMedium.rawValue)
        XCTAssertEqual(first.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolHigh.rawValue)
        XCTAssertEqual(second.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolHigh.rawValue)
        XCTAssertEqual(unrelated.prompt.contextBuilderAgentModelRaw, AgentModel.gpt56SolLow.rawValue)
        for (index, entry) in windows.enumerated() {
            try assertOverlays(entry.0, workspaceID: entry.1, equal: dirty[index])
        }
    }

    func testRecommendationApplyStillRefreshesMatchingWorkspaceOnly() async throws {
        let store = try makeStore()
        let workspaceID = UUID()
        let unrelatedID = UUID()
        let first = makeWindow(store: store, workspaceID: workspaceID)
        let second = makeWindow(store: store, workspaceID: workspaceID)
        let unrelated = makeWindow(store: store, workspaceID: unrelatedID)
        await finishNotificationDelivery()
        _ = try dirtyOverlays(first, workspaceID: workspaceID)
        _ = try dirtyOverlays(second, workspaceID: workspaceID)
        let unrelatedDirty = try dirtyOverlays(unrelated, workspaceID: unrelatedID)

        var copy = store.copySettings(for: workspaceID)
        copy.fileTreeOption = .none
        store.updateCopySettings(copy)
        var chat = store.chatSettings(for: workspaceID)
        chat.fileTreeOption = .none
        chat.proFileEdits = false
        store.updateChatSettings(chat)
        RecommendationApplyNotification.post(
            sourceWorkspaceID: workspaceID,
            agentModelsScope: .workspace(workspaceID),
            includesPresetExposure: false
        )
        await finishNotificationDelivery()

        for window in [first, second] {
            XCTAssertEqual(try encoded(window.settings.copySettings(for: workspaceID)), try encoded(copy))
            XCTAssertEqual(window.settings.chatSettings(for: workspaceID), chat)
            XCTAssertEqual(window.prompt.fileTreeOption, .none)
        }
        try assertOverlays(unrelated, workspaceID: unrelatedID, equal: unrelatedDirty)
    }

    private struct Window {
        let prompt: PromptViewModel
        let settings: WindowSettingsManager
        let api: APISettingsViewModel
    }

    private func makeStore() throws -> GlobalSettingsStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentModelsPicker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AgentModelsPicker.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json")))
        store.installApplicationEventBridge()
        return store
    }

    private func makeWindow(store: GlobalSettingsStore, workspaceID: UUID) -> Window {
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let queries = AIQueriesService(keyManager: keys)
        let api = APISettingsViewModel(aiQueriesService: queries, keyManager: keys, loadStoredDataOnInit: false)
        api.isCodexConnected = true
        api.test_completeContextBuilderProviderValidation(verifiedProviders: [.codexExec])
        addTeardownBlock { @MainActor in api.prepareForWindowClose() }
        let files = WorkspaceFilesViewModel()
        files.setCurrentWorkspaceID(workspaceID)
        let settings = WindowSettingsManager(windowID: -574, store: store)
        let prompt = PromptViewModel(fileManager: files, aiQueriesService: queries, apiSettingsViewModel: api, windowID: -574, settingsManager: settings, refreshAvailableModelsOnInit: false)
        return Window(prompt: prompt, settings: settings, api: api)
    }

    private func profile(_ model: AgentModel) -> AgentModelsSettingsProfile {
        AgentModelsSettingsProfile(contextBuilderAgentRaw: AgentProviderKind.codexExec.rawValue, contextBuilderModelsByAgent: [AgentProviderKind.codexExec.rawValue: model.rawValue])
    }

    private func dirtyOverlays(_ window: Window, workspaceID: UUID) throws -> (Data, ChatGlobalSettings) {
        var copy = window.settings.copySettings(for: workspaceID)
        copy.fileTreeOption = .files
        window.settings.updateCopySettings(copy, commit: false)
        var chat = window.settings.chatSettings(for: workspaceID)
        chat.fileTreeOption = .files
        chat.proFileEdits = true
        window.settings.updateChatSettings(chat, commit: false)
        return try (encoded(copy), chat)
    }

    private func assertOverlays(_ window: Window, workspaceID: UUID, equal expected: (Data, ChatGlobalSettings), file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try encoded(window.settings.copySettings(for: workspaceID)), expected.0, file: file, line: line)
        XCTAssertEqual(window.settings.chatSettings(for: workspaceID), expected.1, file: file, line: line)
    }

    private func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private func actionItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title, item.action != nil { return item }
            if let submenu = item.submenu, let match = actionItem(titled: title, in: submenu) { return match }
        }
        return nil
    }

    private func finishNotificationDelivery() async {
        // The old picker scheduled its broad post on the main queue; subscribers then
        // scheduled delivery there too. Two FIFO barriers cover both hops, without sleeps.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

@MainActor
final class StableMenuRowOwnershipTests: XCTestCase {
    private final class Rows: ObservableObject {
        @Published var order = ["A", "B", "C", "D"]
        var frames: [String: CGRect] = [:]
        var resolved: [String] = []
    }

    private struct RowFrames: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
        }
    }

    private struct RowList: View {
        @ObservedObject var rows: Rows

        var body: some View {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows.order, id: \.self) { id in
                        HStack {
                            Text(id)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: RowFrames.self,
                                    value: [id: proxy.frame(in: .named("menuRows"))]
                                )
                            }
                        }
                        .overlay {
                            StableMenuContextRegion(anchor: StableMenuAnchor()) {
                                rows.resolved.append(id)
                                // Empty items expose every accepting region without native tracking.
                                return []
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .coordinateSpace(name: "menuRows")
            .onPreferenceChange(RowFrames.self) { rows.frames = $0 }
        }
    }

    func testContextClickResolvesOnlyClickedRowBeforeAndAfterReorder() throws {
        _ = NSApplication.shared
        let rows = Rows()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RowList(rows: rows))
        window.contentView = host
        defer { window.close() }

        for order in [["A", "B", "C", "D"], ["D", "C", "B", "A"]] {
            rows.order = order
            host.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(2)
            func layoutMatches() -> Bool {
                rows.frames.count == order.count
                    && rows.frames.sorted { $0.value.minY < $1.value.minY }.map(\.key) == order
            }
            while !layoutMatches(), Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                host.layoutSubtreeIfNeeded()
            }
            XCTAssertTrue(layoutMatches(), "Displayed row geometry must settle before clicking")
            for id in order {
                let frame = try XCTUnwrap(rows.frames[id])
                XCTAssertGreaterThan(frame.height, 0)
                let point = host.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
                for (type, flags) in [
                    (NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()),
                    (.leftMouseDown, .control)
                ] {
                    rows.resolved = []
                    let event = try XCTUnwrap(NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 0
                    ))
                    NSApp.sendEvent(event)
                    XCTAssertEqual(rows.resolved, [id], "Click on \(id) must not resolve another row (order \(order), \(type))")
                }
            }
        }
    }
}
