import Foundation
@testable import RepoPromptSettingsCore
import XCTest

@MainActor
final class RoutingProfileLegacySettingsCompatibilityTests: XCTestCase {
    func testSchemaV12LegacyProfileFieldsSurviveUnrelatedEditAndReload() throws {
        let fixture = try makeStore()
        let lastCheckAt = Date(timeIntervalSince1970: 1_790_000_000)
        try fixture.file.save(
            GlobalSettingsDocument(
                schemaVersion: GlobalSettingsDocument.routingProfileUpdatePreferenceSchemaVersion,
                scalarPreferences: .init(
                    modelRoutingProfiles: .init(remoteUpdatesDisabled: true, lastCheckAt: lastCheckAt)
                )
            )
        )
        XCTAssertTrue(fixture.store.reloadFromDisk())

        fixture.store.setModelRouterCustomInstructions("Unrelated edit")
        XCTAssertTrue(fixture.store.reloadFromDisk())

        let document = try fixture.file.load()
        XCTAssertEqual(document.schemaVersion, GlobalSettingsDocument.routingProfileUpdatePreferenceSchemaVersion)
        XCTAssertEqual(document.scalarPreferences?.modelRoutingProfiles?.remoteUpdatesDisabled, true)
        XCTAssertEqual(document.scalarPreferences?.modelRoutingProfiles?.lastCheckAt, lastCheckAt)
    }

    func testEitherLegacyFieldKeepsTheContentDerivedV12Fence() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let optedOut = GlobalSettingsDocument(
            scalarPreferences: .init(modelRoutingProfiles: .init(remoteUpdatesDisabled: true))
        )
        let checked = GlobalSettingsDocument(
            scalarPreferences: .init(modelRoutingProfiles: .init(lastCheckAt: date))
        )

        XCTAssertEqual(optedOut.requiredSchemaVersion, GlobalSettingsDocument.routingProfileUpdatePreferenceSchemaVersion)
        XCTAssertEqual(checked.requiredSchemaVersion, GlobalSettingsDocument.routingProfileUpdatePreferenceSchemaVersion)
    }

    private struct Fixture {
        let store: GlobalSettingsStore
        let file: GlobalSettingsFileStore
    }

    private func makeStore() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        try file.save(GlobalSettingsDocument())
        let suite = "RoutingProfileLegacySettingsCompatibility.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Fixture(store: GlobalSettingsStore(defaults: defaults, fileStore: file), file: file)
    }
}
