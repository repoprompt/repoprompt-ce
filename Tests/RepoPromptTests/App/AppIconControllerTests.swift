import AppKit
import Foundation
@testable import RepoPromptApp
import XCTest

final class AppIconControllerTests: XCTestCase {
    func testExplicitModesRemainExplicit() throws {
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertEqual(AppIconMode.light.resolved(for: darkAppearance), .light)
        XCTAssertEqual(AppIconMode.dark.resolved(for: lightAppearance), .dark)
        XCTAssertEqual(AppIconMode.light.customResource?.name, "AppIconLight")
        XCTAssertNil(AppIconMode.dark.customResource)
    }

    func testSystemModeFollowsEffectiveAppearance() throws {
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertEqual(AppIconMode.system.resolved(for: lightAppearance), .light)
        XCTAssertEqual(AppIconMode.system.resolved(for: darkAppearance), .dark)
    }

    @MainActor
    func testModeDefaultsToSystemAndPersists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppIconControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "AppIconControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileURL = root.appendingPathComponent("globalSettings.json")
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )

        XCTAssertEqual(store.appIconModeRaw(), AppIconMode.system.rawValue)
        store.setAppIconModeRaw(AppIconMode.light.rawValue)

        let reloaded = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertEqual(reloaded.appIconModeRaw(), AppIconMode.light.rawValue)
    }
}
