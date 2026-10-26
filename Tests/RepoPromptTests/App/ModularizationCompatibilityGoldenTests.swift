import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

/// Build-modularization P0.6 goldens: runtime identities that a module move must not change.
///
/// Inventory and classification: `docs/migrations/build-modularization/ledger.md`, section
/// "P0.6 compatibility inventory". When a slice moves one of these types, move the matching test
/// with it and keep the literals unchanged.
final class ModularizationCompatibilityGoldenTests: XCTestCase {
    func testSettingsProviderIdentitiesMatchAppProviderMappings() throws {
        XCTAssertEqual(
            Set(SettingsAgentKind.allCases.map(\.rawValue)),
            Set(AgentProviderKind.allCases.map(\.rawValue))
        )
        for agent in AgentProviderKind.allCases {
            let settingsIdentity = try XCTUnwrap(SettingsAgentKind(rawValue: agent.rawValue))
            XCTAssertEqual(settingsIdentity.acpProviderID, agent.acpProviderID)
        }
    }

    // MARK: - Reflection-based sort key

    /// `automaticSelectionIssuePrecedes` orders issues by `String(reflecting:)`, so the key text
    /// embeds module-qualified type names. Both sides of every comparison share the same type
    /// prefix at the same position, so the order depends only on case names and payload values,
    /// not on the owning module. This golden pins that order, including the lexicographic
    /// (not numeric) ordering of integer payloads, so a move or an explicit-key refactor that
    /// changes it fails here.
    func testAutomaticSelectionIssueOrderIsPinned() {
        let rootA = WorkspaceCodemapRootEpoch(
            rootID: uuid("00000000-0000-0000-0000-00000000000A"),
            rootLifetimeID: uuid("00000000-0000-0000-0000-000000000001")
        )
        let rootB = WorkspaceCodemapRootEpoch(
            rootID: uuid("00000000-0000-0000-0000-00000000000B"),
            rootLifetimeID: uuid("00000000-0000-0000-0000-000000000001")
        )
        let fileLow = uuid("00000000-0000-0000-0000-000000000101")
        let fileHigh = uuid("00000000-0000-0000-0000-000000000102")

        func source(
            _ rootEpoch: WorkspaceCodemapRootEpoch,
            catalogGeneration: UInt64 = 1
        ) -> WorkspaceCodemapAutomaticSelectionSourceIdentity {
            WorkspaceCodemapAutomaticSelectionSourceIdentity(
                rootEpoch: rootEpoch,
                fileID: fileLow,
                catalogGeneration: catalogGeneration,
                requestGeneration: 1
            )
        }

        let expected: [WorkspaceCodemapAutomaticSelectionIssue] = [
            .budget(.byteLimit(attempted: 2, limit: 1)),
            .emptySources,
            .graphRevoked(rootA, .rootUnloaded),
            .graphRevoked(rootA, .schemaMismatch),
            .rootScopeChanged,
            // "10" sorts before "9": the key compares rendered text, not numbers.
            .sourceGenerationChanged(source(rootA, catalogGeneration: 10), committedGeneration: nil),
            .sourceGenerationChanged(source(rootA, catalogGeneration: 9), committedGeneration: nil),
            .sourcePending(source(rootA)),
            .sourcePending(source(rootB)),
            .targetDemandUnavailable(rootEpoch: rootA, fileID: fileLow, reason: .busy(retryAfterMilliseconds: nil)),
            .targetDemandUnavailable(rootEpoch: rootA, fileID: fileLow, reason: .rootNotLoaded),
            // Root epoch is compared before file ID.
            .targetNotCataloged(rootEpoch: rootA, fileID: fileHigh),
            .targetNotCataloged(rootEpoch: rootB, fileID: fileLow),
            .updatesPending(rootA)
        ]

        let interleaved = expected.enumerated()
            .sorted { ($0.offset % 3, -$0.offset) < ($1.offset % 3, -$1.offset) }
            .map(\.element)
        for input in [Array(expected.reversed()), interleaved] {
            XCTAssertEqual(input.sorted(by: automaticSelectionIssuePrecedes), expected)
        }
    }

    // MARK: - Cross-process notification names

    /// Darwin notifications cross process boundaries between running app instances.
    @MainActor
    func testFontScaleDarwinNotificationNameIsPinned() {
        XCTAssertEqual(FontScaleManager.externalChangeNotificationRawName, "com.repoprompt.fontScaleDidChange")
    }

    // MARK: - Persisted settings document keys

    /// The global settings document's root keys and scalar-preference group keys are persisted
    /// JSON. Field-level keys inside each group are covered by the settings persistence suites.
    func testGlobalSettingsDocumentPersistedKeysArePinned() throws {
        let groupKeys: Set = [
            "agentMode",
            "contextBuilder",
            "fileSystem",
            "mcp",
            "modelOverrides",
            "modelRouter",
            "modelSelection",
            "notifications",
            "promptPackaging",
            "telemetry",
            "ui"
        ]
        let scalarJSON = "{" + groupKeys.sorted().map { "\"\($0)\":{}" }.joined(separator: ",") + "}"
        let scalarPreferences = try JSONDecoder().decode(GlobalScalarPreferences.self, from: Data(scalarJSON.utf8))
        let document = GlobalSettingsDocument(
            updatedAt: Date(timeIntervalSince1970: 0),
            scalarPreferences: scalarPreferences
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), [
            "chatSettingsByWorkspaceID",
            "copySettingsByWorkspaceID",
            "globalDefaults",
            "scalarPreferences",
            "schemaLineage",
            "schemaVersion",
            "updatedAt"
        ])
        XCTAssertEqual(root["schemaLineage"] as? String, "repoprompt-ce.global-settings")
        let encodedGroups = try XCTUnwrap(root["scalarPreferences"] as? [String: Any])
        XCTAssertEqual(Set(encodedGroups.keys), groupKeys)

        // `agentModelsSettingsByWorkspaceID` is omitted when empty; pin its key on the read side.
        root["agentModelsSettingsByWorkspaceID"] = [String: Any]()
        let decoded = try decoder.decode(
            GlobalSettingsDocument.self,
            from: JSONSerialization.data(withJSONObject: root)
        )
        XCTAssertNotNil(decoded.agentModelsSettingsByWorkspaceID)
        XCTAssertEqual(decoded.scalarPreferences, scalarPreferences)
    }

    private func uuid(_ string: String) -> UUID {
        guard let value = UUID(uuidString: string) else {
            preconditionFailure("invalid fixture UUID \(string)")
        }
        return value
    }
}
