import Foundation
import RepoPromptSettingsCore
import XCTest

final class SubscriptionProfileCatalogTests: XCTestCase {
    func testNamedProfilesRoundTripWithoutCountLimitOrIdentityChanges() throws {
        var catalog = SubscriptionProfileCatalog()
        let ids = try (0 ..< 150).map { index in
            try catalog.add(backend: .claudeCode, label: "Account \(index)")
        }
        let codex = try catalog.add(backend: .codex, label: "Work")
        try catalog.rename(ids[0], label: " Personal ")
        try catalog.setDefault(.profile(ids[0]))
        try catalog.setDefault(.profile(codex))

        let restored = try JSONDecoder().decode(
            SubscriptionProfileCatalog.self,
            from: JSONEncoder().encode(catalog)
        )
        XCTAssertEqual(restored, catalog)
        XCTAssertEqual(restored.profiles.filter { $0.id.backend == .claudeCode }.map(\.id), ids)
        XCTAssertEqual(restored.profiles.first?.label, "Personal")
        XCTAssertEqual(restored.defaultSelection(for: .claudeCode), .profile(ids[0]))
        XCTAssertEqual(restored.defaultSelection(for: .codex), .profile(codex))
    }

    func testArchiveClearsOnlyItsOwnDefaultAndRestoreDoesNotSelectIt() throws {
        var catalog = SubscriptionProfileCatalog()
        let claude = try catalog.add(backend: .claudeCode, label: "Work")
        let codex = try catalog.add(backend: .codex, label: "Work")
        try catalog.setDefault(.profile(claude))
        try catalog.setDefault(.profile(codex))
        try catalog.setArchived(true, for: claude)
        XCTAssertThrowsError(try catalog.setDefault(.profile(claude))) { error in
            XCTAssertEqual(error as? SubscriptionProfileCatalog.CatalogError, .archivedProfile)
        }
        try catalog.setArchived(false, for: claude)
        XCTAssertEqual(catalog.defaultSelection(for: .claudeCode), .legacy(.claudeCode))
        XCTAssertEqual(catalog.defaultSelection(for: .codex), .profile(codex))
        XCTAssertEqual(catalog.profiles.first?.id, claude)
    }

    func testDecodeRejectsFutureVersionsDuplicateIDsAndInvalidDefaults() throws {
        let root: [String: Any] = ["version": 1, "profiles": [], "defaults": [:]]
        let id = ["backend": "codex", "uuid": UUID().uuidString]
        let profile: [String: Any] = ["id": id, "label": "Work", "isArchived": false]
        let archived: [String: Any] = ["id": id, "label": "Work", "isArchived": true]
        let cases: [([String: Any], SubscriptionProfileCatalog.CatalogError)] = [
            (["version": 2], .unsupportedVersion),
            (["profiles": [profile, profile]], .duplicateID),
            (["defaults": ["codex": id]], .invalidDefault),
            (["profiles": [profile], "defaults": ["claudeCode": id]], .invalidDefault),
            (["profiles": [archived], "defaults": ["codex": id]], .invalidDefault)
        ]
        for (overrides, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: root.merging(overrides) { _, new in new })
            XCTAssertThrowsError(try JSONDecoder().decode(SubscriptionProfileCatalog.self, from: data)) { error in
                guard case let DecodingError.dataCorrupted(context) = error else {
                    return XCTFail("Expected catalog validation to surface as data corruption")
                }
                XCTAssertEqual(context.underlyingError as? SubscriptionProfileCatalog.CatalogError, expected)
            }
        }
    }

    func testSettingsProjectionSeparatesProvidersDefaultsAndGateReasons() throws {
        var catalog = SubscriptionProfileCatalog()
        let codex = try catalog.add(backend: .codex, label: "Work")
        let archived = try catalog.add(backend: .codex, label: "Archived")
        let claude = try catalog.add(backend: .claudeCode, label: "Work")
        try catalog.setArchived(true, for: archived)
        try catalog.setDefault(.profile(codex))

        let codexView = SubscriptionAccountSettingsSnapshot(backend: .codex, catalog: catalog)
        XCTAssertEqual(codexView.gate, .codexIdentityAndIsolationUnverified)
        XCTAssertEqual(codexView.defaultSelection, .profile(codex))
        XCTAssertEqual(codexView.rows.map(\.id), [codex, archived])
        XCTAssertEqual(codexView.rows.map(\.isArchived), [false, true])
        XCTAssertEqual(codexView.rows.map(\.isDefault), [true, false])

        let claudeView = SubscriptionAccountSettingsSnapshot(backend: .claudeCode, catalog: catalog)
        XCTAssertEqual(claudeView.gate, .claudeIdentityUnverified)
        XCTAssertEqual(claudeView.defaultSelection, .legacy(.claudeCode))
        XCTAssertEqual(claudeView.rows.map(\.id), [claude])
        XCTAssertFalse(claudeView.rows[0].isDefault)
    }

    func testUnavailableCatalogDoesNotProjectLegacyDefault() {
        let unavailable = SubscriptionAccountSettingsSnapshot(backend: .codex, catalog: nil)
        XCTAssertNil(unavailable.defaultSelection)
        XCTAssertTrue(unavailable.rows.isEmpty)
        XCTAssertEqual(
            SubscriptionAccountSettingsSnapshot(backend: .codex, catalog: .init()).defaultSelection,
            .legacy(.codex)
        )
    }
}
