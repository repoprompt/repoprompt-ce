import Foundation
@testable import RepoPromptProviderQuota
@testable import RepoPromptSettingsCore
import XCTest

/// Run telemetry reaches the Claude usage pill by default once Claude usage display is
/// connected; the diagnostics toggle is neither required nor sufficient for the pill.
@MainActor
final class ClaudeRunTelemetryDisplayGateTests: XCTestCase {
    private let profile = "/Users/fixture/.claude"

    func testRecordingFollowsDiagnosticsOrConnectedDisplay() throws {
        try withStore { settings in
            XCTAssertFalse(settings.claudeRunTelemetryRecordingEnabled(profileID: profile), "nothing connected, nothing recorded")

            settings.setUsageLimitsDisplayEnabled(true)
            settings.setClaudeCLIUsageGrant(ClaudeCLIUsageGrant(credentialProfileID: profile, grantedAt: Date()))
            XCTAssertFalse(settings.claudeUsageQuotaEnabled())
            XCTAssertTrue(settings.claudeUsageDisplayConsented(profileID: profile))
            XCTAssertTrue(settings.claudeRunTelemetryRecordingEnabled(profileID: profile), "connected display is sufficient consent")
            XCTAssertFalse(settings.claudeRunTelemetryRecordingEnabled(profileID: "/Users/fixture/other"), "grant is profile scoped")

            settings.setClaudeCLIUsageGrant(ClaudeCLIUsageGrant(credentialProfileID: profile, grantedAt: Date(), setupCompleted: false))
            XCTAssertFalse(settings.claudeRunTelemetryRecordingEnabled(profileID: profile), "unfinished setup is not consent")

            settings.setClaudeCLIUsageGrant(ClaudeCLIUsageGrant(credentialProfileID: profile, grantedAt: Date()))
            settings.setUsageLimitsDisplayEnabled(false)
            XCTAssertFalse(settings.claudeRunTelemetryRecordingEnabled(profileID: profile), "display off")

            settings.setClaudeUsageQuotaEnabled(true)
            XCTAssertTrue(settings.claudeRunTelemetryRecordingEnabled(profileID: profile), "diagnostics keeps its own meaning")
            XCTAssertFalse(settings.claudeUsageDisplayConsented(profileID: profile), "but is not display consent")
        }
    }

    func testConnectedDisplayShowsRunTelemetryWithDiagnosticsOff() async throws {
        try await withAsyncStore { settings in
            settings.setUsageLimitsDisplayEnabled(true)
            settings.setClaudeCLIUsageGrant(ClaudeCLIUsageGrant(credentialProfileID: profile, grantedAt: Date()))
            let shown = await usedPercentAfterRunEvent(settings: settings)
            XCTAssertEqual(shown, 61, "an SDK event updates the pill without the diagnostics toggle")
        }
    }

    func testDisconnectedOrDisplayOffDoesNotUpdateThePill() async throws {
        try await withAsyncStore { settings in
            settings.setUsageLimitsDisplayEnabled(true)
            let disconnected = await usedPercentAfterRunEvent(settings: settings)
            XCTAssertEqual(disconnected, 42, "no Claude usage connection: run telemetry is not recorded")
        }
        try await withAsyncStore { settings in
            settings.setUsageLimitsDisplayEnabled(false)
            settings.setClaudeCLIUsageGrant(ClaudeCLIUsageGrant(credentialProfileID: profile, grantedAt: Date()))
            let displayOff = await usedPercentAfterRunEvent(settings: settings)
            XCTAssertEqual(displayOff, 42, "display off: run telemetry is not recorded")
        }
        try await withAsyncStore { settings in
            settings.setUsageLimitsDisplayEnabled(false)
            settings.setClaudeCLIUsageGrant(ClaudeCLIUsageGrant(credentialProfileID: profile, grantedAt: Date()))
            settings.setClaudeUsageQuotaEnabled(true)
            let diagnosticsOnly = await usedPercentAfterRunEvent(settings: settings)
            XCTAssertEqual(diagnosticsOnly, 42, "diagnostics may record, but never puts telemetry on a non-consented display")
        }
    }

    // MARK: - Pipeline (mirrors runner + runtime wiring)

    /// Shows a 42% CLI reading, then delivers one 61% run event the way the runner does: the
    /// per-run `setEnabled` uses the combined recording policy, and the bridge forwards.
    private func usedPercentAfterRunEvent(settings: GlobalSettingsStore) async -> Int? {
        let now = Date()
        let source = BaseSource(.loaded(cliSnapshot(used: 42, observedAt: now.addingTimeInterval(-600))))
        let store = ProviderQuotaUIStore(service: source, settingsProvider: { true }, freshnessInterval: 0)
        store.activate()
        _ = await waitUntil { store.indicatorState?.usedPercent == 42 }

        let telemetry = ClaudeRunRateLimitTelemetryService()
        let profile = profile
        let bridge = ClaudeRunTelemetryDisplayBridge(
            telemetry: telemetry,
            store: store,
            displayConsented: { settings.claudeUsageDisplayConsented(profileID: profile) }
        )
        await telemetry.setEnabled(settings.claudeRunTelemetryRecordingEnabled(profileID: profile))
        if let lease = await telemetry.beginObservation(credentialProfileID: profile) {
            await telemetry.observe(.init(status: .allowed, rateLimitType: "five_hour", utilization: 0.61), lease: lease, observedAt: now)
        }
        _ = await waitUntil(timeout: 0.5) { store.indicatorState?.usedPercent == 61 }
        let shown = store.indicatorState?.usedPercent
        withExtendedLifetime(bridge) {}
        store.deactivate()
        await telemetry.shutdown()
        return shown
    }

    private func cliSnapshot(used: Double, observedAt: Date) -> ProviderQuotaSnapshot {
        let id = ProviderQuotaBucketID.synthesizedDefault
        let window = ProviderQuotaWindow(
            key: .init(bucketID: id, nativeRole: "five_hour"),
            percent: ProviderQuotaPercent(rawValue: used, sense: .used, declaredUpperBound: 100),
            windowDuration: 5 * 3600,
            resetsAt: observedAt.addingTimeInterval(3 * 3600),
            observedAt: observedAt
        )
        return ProviderQuotaSnapshot(
            accountKey: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: profile),
            buckets: [ProviderQuotaBucket(bucketID: id, displayLabel: nil, nativeModelAlias: nil, scope: .accountWide, reachedType: nil, isReached: nil, planType: nil, credits: nil, spendControl: nil, windows: [window])],
            facets: .empty,
            source: .claudeCLIUsage,
            coverage: .accountWideAggregateOnly,
            observedAt: observedAt
        )
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func makeStore() throws -> (GlobalSettingsStore, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeRunTelemetryDisplayGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "ClaudeRunTelemetryDisplayGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        return (GlobalSettingsStore(defaults: defaults, fileStore: fileStore), cleanup)
    }

    private func withStore(_ body: (GlobalSettingsStore) throws -> Void) throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        try body(store)
    }

    private func withAsyncStore(_ body: (GlobalSettingsStore) async throws -> Void) async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        try await body(store)
    }

    private actor BaseSource: ProviderQuotaObserving {
        private let status: ProviderQuotaStatus
        init(_ status: ProviderQuotaStatus) {
            self.status = status
        }

        func subscribe() -> AsyncStream<ProviderQuotaStatus> {
            let (stream, continuation) = AsyncStream<ProviderQuotaStatus>.makeStream()
            continuation.yield(status)
            return stream
        }

        func setEnabled(_: Bool) {}
        func refreshNow() {}
        func refreshOnForeground() {}
    }
}
