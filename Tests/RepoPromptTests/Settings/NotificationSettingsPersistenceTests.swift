import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class NotificationSettingsPersistenceTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationSettingsPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "NotificationSettingsPersistenceTests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private var fileURL: URL {
        root.appendingPathComponent("globalSettings.json")
    }

    private func makeStore() throws -> GlobalSettingsStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
    }

    func testMissingGroupResolvesToProductDefaults() {
        let resolved = GlobalScalarPreferences.NotificationSettings().resolved()
        XCTAssertEqual(resolved, .defaults)
        XCTAssertTrue(resolved.approveFromNotifications, "Approve-from-notification defaults on (strictly gated)")
        XCTAssertFalse(resolved.replyFromCompletion)
        XCTAssertFalse(resolved.includeAgentDrivenSessions)
        XCTAssertFalse(resolved.mcpAskUserNotifyInsteadOfActivate)
    }

    func testDecodeToleratesMissingAndPartialKeys() throws {
        let json = #"{"notifications":{"dockBadge":false}}"#
        let decoded = try JSONDecoder().decode(GlobalScalarPreferences.self, from: Data(json.utf8))
        var expected = NotificationPreferences.defaults
        expected.dockBadge = false
        XCTAssertEqual(decoded.notifications?.resolved(), expected)

        let empty = try JSONDecoder().decode(GlobalScalarPreferences.self, from: Data("{}".utf8))
        XCTAssertNil(empty.notifications)
    }

    func testDecodeIgnoresUnknownFutureNotificationKeys() throws {
        let json = #"{"notifications":{"enabled":false,"futureKnob":"x"},"futureGroup":{"a":1}}"#
        let decoded = try JSONDecoder().decode(GlobalScalarPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.notifications?.enabled, false)
    }

    func testNotificationGroupDoesNotRaiseRequiredSchemaVersion() {
        var settings = GlobalScalarPreferences.NotificationSettings()
        settings.approveFromNotifications = false
        let document = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(notifications: settings))
        XCTAssertEqual(document.requiredSchemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
        XCTAssertEqual(GlobalSettingsDocument.currentSchemaVersion, 10, "This feature must not bump the schema")
    }

    func testStoreEditDoesNotChangeStoredSchemaVersion() throws {
        let store = try makeStore()
        let tooltipsBaseline = store.showTooltips()
        store.setShowTooltips(!tooltipsBaseline)
        store.setShowTooltips(tooltipsBaseline)
        let before = try schemaVersionOnDisk()
        let descriptor = try XCTUnwrap(NotificationSettingDescriptor.all.first { $0.key == "approve_from_notifications" })

        store.setNotificationSetting(descriptor, false)

        XCTAssertEqual(try schemaVersionOnDisk(), before, "The notifications group never raises the stored schema")
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        let notifications = (raw["scalarPreferences"] as? [String: Any])?["notifications"] as? [String: Any]
        XCTAssertEqual(notifications?["approveFromNotifications"] as? Bool, false)

        let reloaded = try makeStore()
        XCTAssertFalse(reloaded.notificationPreferences().approveFromNotifications)
        XCTAssertTrue(reloaded.notificationPreferences().enabled)
    }

    func testOlderTypedReaderLoadsBaselineFileContainingNotificationGroup() throws {
        var settings = GlobalScalarPreferences.NotificationSettings()
        settings.enabled = false
        settings.dockBadge = false
        let document = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(notifications: settings))
        try GlobalSettingsFileStore(fileURL: fileURL).save(document)

        XCTAssertEqual(try schemaVersionOnDisk(), GlobalSettingsDocument.baselineSchemaVersion)
        // The frozen v1.3.0 typed codec stands in for an older released build: it must ignore the group.
        XCTAssertNoThrow(try FrozenV130GlobalSettingsDocument.load(from: fileURL))

        let current = try GlobalSettingsFileStore(fileURL: fileURL).load()
        XCTAssertEqual(current.scalarPreferences?.notifications, settings)
    }

    private func schemaVersionOnDisk() throws -> Int? {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        return raw?["schemaVersion"] as? Int
    }

    func testStorePostsChangeNotificationOnlyOnChange() throws {
        let store = try makeStore()
        let descriptor = try XCTUnwrap(NotificationSettingDescriptor.all.first { $0.key == "dock_badge" })
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: .notificationPreferencesDidChange,
            object: store,
            queue: nil
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        store.setNotificationSetting(descriptor, false)
        store.setNotificationSetting(descriptor, false)

        XCTAssertEqual(count, 1)
    }

    func testDescriptorsAreUniqueAndCoverEveryPreference() {
        let keys = NotificationSettingDescriptor.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(keys.count, 16, "Every NotificationPreferences field has exactly one descriptor")
        for descriptor in NotificationSettingDescriptor.all {
            var preferences = NotificationPreferences.defaults
            preferences[keyPath: descriptor.preference].toggle()
            XCTAssertNotEqual(preferences, .defaults, descriptor.key)
        }
    }

    func testAppSettingsNotificationsGroupReadsAndWrites() async throws {
        let store = try makeStore()
        let service = AppSettingsMCPService(store: store)

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("notifications")
        ])
        let keys = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue).compactMap { $0.objectValue?["key"]?.stringValue }
        XCTAssertEqual(Set(keys), Set(NotificationSettingDescriptor.all.map(\.appSettingsKey)))

        _ = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string("notifications.reply_from_completion"),
            "value": .bool(true)
        ])
        XCTAssertTrue(store.notificationPreferences().replyFromCompletion)

        let read = try await service.handleForTesting([
            "op": .string("get"),
            "key": .string("notifications.reply_from_completion")
        ])
        XCTAssertTrue(String(describing: read).contains("true"))
    }
}
