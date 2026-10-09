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

    // MARK: - Overlay accumulation across publications

    func testANewRunKeepsTheEarlierRunsNewerWindows() async throws {
        try await withAsyncStore { settings in
            settings.setUsageLimitsDisplayEnabled(true)
            settings.setClaudeCLIUsageGrant(ClaudeCLIUsageGrant(credentialProfileID: profile, grantedAt: Date()))
            let t0 = Date().addingTimeInterval(-600)
            let pipeline = await Pipeline.start(settings: settings, base: cliSnapshot(fiveHour: 20, weekly: 60, observedAt: t0), profile: profile)
            let base = await waitUntil { pipeline.store.indicatorState?.usedPercent == 60 }
            XCTAssertTrue(base, "the CLI reading is shown first")

            let run1 = await pipeline.beginRun()
            await pipeline.event("five_hour", 0.30, lease: run1, at: t0.addingTimeInterval(60))
            await pipeline.event("seven_day", 0.85, lease: run1, at: t0.addingTimeInterval(60))
            let firstRun = await waitUntil { pipeline.store.indicatorState?.usedPercent == 85 }
            XCTAssertTrue(firstRun, "run 1 raises the weekly window to 85%")

            // A new run resets the telemetry snapshot and reports only the 5-hour window.
            let run2 = await pipeline.beginRun()
            await pipeline.event("five_hour", 0.35, lease: run2, at: t0.addingTimeInterval(120))
            let secondRun = await waitUntil { rowValues(pipeline.store).contains { $0.hasPrefix("35%") } }
            XCTAssertTrue(secondRun, "run 2's 5-hour reading is displayed")
            XCTAssertEqual(pipeline.store.indicatorState?.usedPercent, 85, "run 1's newer weekly reading is kept, not the older CLI 60%")
            await pipeline.stop()
        }
    }

    func testAnEventWithoutUtilizationNeverErasesTheDisplayedFigure() async throws {
        try await withAsyncStore { settings in
            settings.setUsageLimitsDisplayEnabled(true)
            settings.setClaudeCLIUsageGrant(ClaudeCLIUsageGrant(credentialProfileID: profile, grantedAt: Date()))
            let t0 = Date().addingTimeInterval(-600)
            let pipeline = await Pipeline.start(settings: settings, base: cliSnapshot(fiveHour: 40, weekly: 10, observedAt: t0), profile: profile)
            let base = await waitUntil { pipeline.store.indicatorState?.usedPercent == 40 }
            XCTAssertTrue(base)

            let run = await pipeline.beginRun()
            await pipeline.event("five_hour", 0.70, lease: run, at: t0.addingTimeInterval(60))
            let seventy = await waitUntil { pipeline.store.indicatorState?.usedPercent == 70 }
            XCTAssertTrue(seventy)

            // Same window, no utilization; then an unrelated weekly event as a sync point.
            await pipeline.event("five_hour", nil, lease: run, at: t0.addingTimeInterval(120))
            await pipeline.event("seven_day", 0.20, lease: run, at: t0.addingTimeInterval(180))
            let synced = await waitUntil { rowValues(pipeline.store).contains { $0.hasPrefix("20%") } }
            XCTAssertTrue(synced, "later telemetry was displayed")
            XCTAssertEqual(pipeline.store.indicatorState?.usedPercent, 70, "a missing utilization keeps 70%, not the older CLI 40%")
            await pipeline.stop()
        }
    }

    // MARK: - Pipeline (mirrors runner + runtime wiring)

    /// Real telemetry service + display bridge + UI store over a fixed CLI base snapshot.
    @MainActor
    private struct Pipeline {
        let store: ProviderQuotaUIStore
        let telemetry: ClaudeRunRateLimitTelemetryService
        let bridge: ClaudeRunTelemetryDisplayBridge
        let profile: String

        static func start(settings: GlobalSettingsStore, base: ProviderQuotaSnapshot, profile: String) async -> Pipeline {
            let store = ProviderQuotaUIStore(service: BaseSource(.loaded(base)), settingsProvider: { true }, freshnessInterval: 0)
            store.activate()
            let telemetry = ClaudeRunRateLimitTelemetryService()
            let bridge = ClaudeRunTelemetryDisplayBridge(
                telemetry: telemetry,
                store: store,
                displayConsented: { settings.claudeUsageDisplayConsented(profileID: profile) }
            )
            await telemetry.setEnabled(settings.claudeRunTelemetryRecordingEnabled(profileID: profile))
            return Pipeline(store: store, telemetry: telemetry, bridge: bridge, profile: profile)
        }

        func beginRun() async -> UUID? {
            await telemetry.beginObservation(credentialProfileID: profile)
        }

        func event(_ role: String, _ utilization: Double?, lease: UUID?, at date: Date) async {
            guard let lease else { return XCTFail("telemetry must be recording") }
            await telemetry.observe(.init(status: .allowed, rateLimitType: role, utilization: utilization), lease: lease, observedAt: date)
        }

        func stop() async {
            withExtendedLifetime(bridge) {}
            store.deactivate()
            await telemetry.shutdown()
        }
    }

    private func rowValues(_ store: ProviderQuotaUIStore) -> [String] {
        guard case let .loaded(sections, _, _) = store.state else { return [] }
        return sections.flatMap { $0.rows.map(\.valueText) }
    }

    /// Shows a 42% CLI reading, then delivers one 61% run event the way the runner does: the
    /// per-run `setEnabled` uses the combined recording policy, and the bridge forwards.
    private func usedPercentAfterRunEvent(settings: GlobalSettingsStore) async -> Int? {
        let now = Date()
        let source = BaseSource(.loaded(cliSnapshot(fiveHour: 42, weekly: nil, observedAt: now.addingTimeInterval(-600))))
        let store = ProviderQuotaUIStore(service: source, settingsProvider: { true }, freshnessInterval: 0)
        store.activate()
        let baseShown = await waitUntil { store.indicatorState?.usedPercent == 42 }
        XCTAssertTrue(baseShown, "the CLI reading is shown before the run event")

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
        // Positive cases return as soon as 61 shows; negative cases need the full window.
        _ = await waitUntil(timeout: 0.5) { store.indicatorState?.usedPercent == 61 }
        let shown = store.indicatorState?.usedPercent
        withExtendedLifetime(bridge) {}
        store.deactivate()
        await telemetry.shutdown()
        return shown
    }

    private func cliSnapshot(fiveHour: Double, weekly: Double?, observedAt: Date) -> ProviderQuotaSnapshot {
        let id = ProviderQuotaBucketID.synthesizedDefault
        let rows: [(String, Double, TimeInterval)] = [("five_hour", fiveHour, 5 * 3600)] + (weekly.map { [("seven_day", $0, 7 * 86400)] } ?? [])
        let windows = rows.map { role, used, duration in
            ProviderQuotaWindow(
                key: .init(bucketID: id, nativeRole: role),
                percent: ProviderQuotaPercent(rawValue: used, sense: .used, declaredUpperBound: 100),
                windowDuration: duration,
                resetsAt: observedAt.addingTimeInterval(3 * 3600),
                observedAt: observedAt
            )
        }
        return ProviderQuotaSnapshot(
            accountKey: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: profile),
            buckets: [ProviderQuotaBucket(bucketID: id, displayLabel: nil, nativeModelAlias: nil, scope: .accountWide, reachedType: nil, isReached: nil, planType: nil, credits: nil, spendControl: nil, windows: windows)],
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
