import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class CodexConnectedAppsProviderBindingTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testProviderSnapshotDefaultsOffAndHumanMutationRoundTrips() throws {
        let defaults = try makeIsolatedDefaults()
        let snapshots = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            codexMCPServerEntries: { [] }
        )

        XCTAssertFalse(try XCTUnwrap(
            snapshots.topLevelSettingsControlsBinding(providerID: .codex).codexTools
        ).connectedAppsEnabled)

        snapshots.applyCodexToolSettingMutation(.connectedApps(enabled: true))

        XCTAssertTrue(try XCTUnwrap(
            snapshots.topLevelSettingsControlsBinding(providerID: .codex).codexTools
        ).connectedAppsEnabled)
        XCTAssertEqual(defaults.object(forKey: CodexConnectedApps.defaultsKey) as? Bool, true)
    }

    func testLaunchSnapshotAllowsDirectSessionAndRejectsMCPControlledSession() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: CodexConnectedApps.defaultsKey)
        let service = AgentModeProviderBindingService(preferences: AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            codexMCPServerEntries: { [] }
        ))

        XCTAssertTrue(service.codexConnectedAppsEnabledForLaunch(isMCPControlled: false))
        XCTAssertFalse(service.codexConnectedAppsEnabledForLaunch(isMCPControlled: true))
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "CodexConnectedAppsProviderBindingTests.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
