import Foundation
@testable import RepoPromptApp
import XCTest

/// Presentation rules for the observe-only quota surface.
///
/// Each assertion guards a specific misreading: an unknown value looking like a full tank,
/// a "remaining" figure reading as "used", a clamped bar silently clamping the printed
/// number, or an aggregate figure implying per-model eligibility.
final class ProviderQuotaPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        buckets: [ProviderQuotaBucket],
        ordinaryUsageAllowed: Bool? = nil,
        coverage: ProviderQuotaCoverage = .accountWide,
        observedAt: Date? = nil
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            accountKey: .codex(accountID: "acct-1"),
            buckets: buckets,
            facets: ProviderQuotaFacets(ordinaryUsageAllowed: ordinaryUsageAllowed),
            source: .codexAppServerRead,
            coverage: coverage,
            observedAt: observedAt ?? now
        )
    }

    private func bucket(
        id: String = "codex",
        label: String? = "Codex",
        alias: String? = nil,
        isReached: Bool? = nil,
        spendControl: ProviderQuotaSpendControl? = nil,
        windows: [ProviderQuotaWindow]
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            bucketID: ProviderQuotaBucketID(rawValue: id),
            displayLabel: label,
            nativeModelAlias: alias,
            scope: alias.map { ProviderQuotaBucketScope.nativeModelAlias($0) } ?? .accountWide,
            reachedType: isReached == true ? "rate_limit_reached" : nil,
            isReached: isReached,
            planType: nil,
            credits: nil,
            spendControl: spendControl,
            windows: windows
        )
    }

    private func window(
        bucket: String = "codex",
        role: String = "primary",
        percent: ProviderQuotaPercent?,
        duration: TimeInterval? = 18000,
        resetsAt: Date? = nil,
        observedAt: Date? = nil
    ) -> ProviderQuotaWindow {
        ProviderQuotaWindow(
            key: ProviderQuotaWindowKey(
                bucketID: ProviderQuotaBucketID(rawValue: bucket),
                nativeRole: role
            ),
            percent: percent,
            windowDuration: duration,
            resetsAt: resetsAt,
            observedAt: observedAt ?? now
        )
    }

    private func loaded(_ state: CodexQuotaViewState) throws -> (
        sections: [CodexQuotaBucketSection], footnote: String?, notice: String?
    ) {
        guard case let .loaded(sections, footnote, notice) = state else {
            throw XCTSkip("expected loaded state, got \(state)")
        }
        return (sections, footnote, notice)
    }

    // MARK: - Non-value states

    func testDisabledRendersNothing() {
        XCTAssertEqual(ProviderQuotaPresenter.viewState(for: .disabled, now: now), .hidden)
    }

    func testIdleNeverShowsAZeroOrABar() {
        let state = ProviderQuotaPresenter.viewState(for: .idle, now: now)
        XCTAssertEqual(state, .idle(message: "Usage remaining: not reported yet"))
    }

    func testWindowWithoutAPercentDrawsNoBar() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(windows: [window(percent: nil)])])),
            now: now
        )
        let row = try XCTUnwrap(loaded(state).sections.first?.rows.first)
        XCTAssertNil(row.barFraction, "absence of data must not look like a full tank")
        XCTAssertEqual(row.valueText, "Usage remaining: not reported yet")
    }

    // MARK: - Value rendering

    func testFreshWindowStatesSenseAndResetTime() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(windows: [window(
                percent: ProviderQuotaPercent(rawValue: 62, sense: .used),
                resetsAt: now.addingTimeInterval(3600)
            )])])),
            now: now
        )
        let result = try loaded(state)
        let row = try XCTUnwrap(result.sections.first?.rows.first)

        XCTAssertEqual(row.title, "5-hour limit")
        XCTAssertEqual(row.valueText, "62% used", "the sense is always stated")
        XCTAssertEqual(try XCTUnwrap(row.detailText).hasPrefix("Resets "), true)
        XCTAssertEqual(row.barFraction, 0.62)
        XCTAssertNil(result.footnote, "a fresh reading needs no age caveat")
    }

    func testRemainingSenseIsLabelledAndNeverInverted() throws {
        let spendControl = ProviderQuotaSpendControl(
            limitRaw: "$100",
            usedRaw: "$62",
            percent: ProviderQuotaPercent(rawValue: 38, sense: .remaining, declaredUpperBound: 100),
            resetsAt: nil,
            isReached: false,
            observedAt: now
        )
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(
                spendControl: spendControl,
                windows: [window(percent: ProviderQuotaPercent(rawValue: 62, sense: .used))]
            )])),
            now: now
        )
        let rows = try XCTUnwrap(loaded(state).sections.first?.rows)
        let spendRow = try XCTUnwrap(rows.first { $0.title == "Spend limit" })
        XCTAssertEqual(spendRow.valueText, "38% remaining", "never silently inverted to 62% used")
    }

    func testValueAboveDeclaredBoundPrintsRealFigureWhileBarClamps() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(windows: [window(
                percent: ProviderQuotaPercent(rawValue: 112, sense: .used, declaredUpperBound: 100)
            )])])),
            now: now
        )
        let row = try XCTUnwrap(loaded(state).sections.first?.rows.first)
        XCTAssertEqual(row.valueText, "112% used", "the printed number never clamps")
        XCTAssertEqual(row.barFraction, 1.0, "the bar does")
    }

    // MARK: - Bar semantics

    func testSpendControlBarShowsUsedFractionNotRemaining() throws {
        let spendControl = ProviderQuotaSpendControl(
            limitRaw: "$100",
            usedRaw: "$62",
            percent: ProviderQuotaPercent(rawValue: 38, sense: .remaining, declaredUpperBound: 100),
            resetsAt: nil,
            isReached: false,
            observedAt: now
        )
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(
                spendControl: spendControl,
                windows: [window(percent: ProviderQuotaPercent(rawValue: 62, sense: .used))]
            )])),
            now: now
        )
        let rows = try XCTUnwrap(loaded(state).sections.first?.rows)
        let windowRow = try XCTUnwrap(rows.first { $0.title == "5-hour limit" })
        let spendRow = try XCTUnwrap(rows.first { $0.title == "Spend limit" })

        // Both bars depict *used*, so 38% remaining and 62% used fill identically. Reading
        // the remaining figure straight into the bar would have drawn 0.38 against the
        // window's 0.62 and made the account look less consumed than it is.
        XCTAssertEqual(try XCTUnwrap(spendRow.barFraction), 0.62, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(windowRow.barFraction), 0.62, accuracy: 0.0001)
        XCTAssertEqual(spendRow.valueText, "38% remaining", "the printed text stays raw")
    }

    func testUsedFractionIsNotDerivedWithoutADeclaredBound() {
        // A remaining figure with no declared bound cannot be converted, so no bar is drawn
        // rather than one implying a scale the provider never stated.
        let unbounded = ProviderQuotaPercent(rawValue: 38, sense: .remaining, declaredUpperBound: nil)
        XCTAssertNil(ProviderQuotaPresenter.usedFraction(for: unbounded))

        let used = ProviderQuotaPercent(rawValue: 62, sense: .used)
        XCTAssertEqual(try XCTUnwrap(ProviderQuotaPresenter.usedFraction(for: used)), 0.62, accuracy: 0.0001)
    }

    func testSpendControlBarClampsWhileTextKeepsRawValue() throws {
        // A negative remaining figure means more than the limit was spent.
        let spendControl = ProviderQuotaSpendControl(
            limitRaw: "$100",
            usedRaw: "$112",
            percent: ProviderQuotaPercent(rawValue: -12, sense: .remaining, declaredUpperBound: 100),
            resetsAt: nil,
            isReached: nil,
            observedAt: now
        )
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(
                spendControl: spendControl,
                windows: [window(percent: ProviderQuotaPercent(rawValue: 5, sense: .used))]
            )])),
            now: now
        )
        let spendRow = try XCTUnwrap(loaded(state).sections.first?.rows.first { $0.title == "Spend limit" })
        XCTAssertEqual(spendRow.valueText, "-12% remaining", "the printed number never clamps")
        XCTAssertEqual(try XCTUnwrap(spendRow.barFraction), 1.0, accuracy: 0.0001, "the bar does")
    }

    // MARK: - Reached state is per-window, not per-bucket

    func testReachedBucketPreservesEveryWindowFigureWhenNoWindowIsNamed() throws {
        // `rate_limit_reached` does not identify a window, so both windows keep their real
        // figures and the bucket carries the status.
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(
                isReached: true,
                windows: [
                    window(role: "primary", percent: ProviderQuotaPercent(rawValue: 100, sense: .used)),
                    window(role: "secondary", percent: ProviderQuotaPercent(rawValue: 21, sense: .used))
                ]
            )])),
            now: now
        )
        let section = try XCTUnwrap(loaded(state).sections.first)

        XCTAssertEqual(section.statusText, "Limit reached", "bucket-level status is surfaced")
        let primary = try XCTUnwrap(section.rows.first { $0.title == "5-hour limit" })
        let secondary = try XCTUnwrap(section.rows.last)
        XCTAssertEqual(primary.valueText, "100% used")
        XCTAssertEqual(
            secondary.valueText,
            "21% used",
            "a weekly window at 21% must not be relabelled 'Limit reached'"
        )
        XCTAssertFalse(secondary.isReached)
    }

    func testOnlyTheNamedWindowIsMarkedReached() throws {
        // A provider whose reached-type does name a role marks that row only.
        let reachedBucket = ProviderQuotaBucket(
            bucketID: ProviderQuotaBucketID(rawValue: "codex"),
            displayLabel: "Codex",
            nativeModelAlias: nil,
            scope: .accountWide,
            reachedType: "primary",
            isReached: true,
            planType: nil,
            credits: nil,
            spendControl: nil,
            windows: [
                window(role: "primary", percent: ProviderQuotaPercent(rawValue: 100, sense: .used)),
                window(role: "secondary", percent: ProviderQuotaPercent(rawValue: 21, sense: .used))
            ]
        )
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [reachedBucket])),
            now: now
        )
        let section = try XCTUnwrap(loaded(state).sections.first)

        let primary = try XCTUnwrap(section.rows.first)
        let secondary = try XCTUnwrap(section.rows.last)
        XCTAssertEqual(primary.valueText, "Limit reached")
        XCTAssertTrue(primary.isReached)
        XCTAssertEqual(secondary.valueText, "21% used", "the other window keeps its figure")
        XCTAssertFalse(secondary.isReached)
        XCTAssertNil(section.statusText, "the named row already reports it; no duplicate banner")
    }

    func testCodexReachedTypesNameNoWindowRole() {
        // None of the generated `RateLimitReachedType` values identify a window.
        for reachedType in [
            "rate_limit_reached",
            "workspace_owner_credits_depleted",
            "workspace_member_credits_depleted",
            "workspace_owner_usage_limit_reached",
            "workspace_member_usage_limit_reached"
        ] {
            XCTAssertNil(
                ProviderQuotaPresenter.reachedWindowRole(forReachedType: reachedType),
                "\(reachedType) must not be read as a window role"
            )
        }
        XCTAssertNil(ProviderQuotaPresenter.reachedWindowRole(forReachedType: nil))
    }

    func testNotReachedBucketHasNoStatusText() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(windows: [window(
                percent: ProviderQuotaPercent(rawValue: 62, sense: .used)
            )])])),
            now: now
        )
        XCTAssertNil(try loaded(state).sections.first?.statusText)
    }

    func testReachedBucketReportsStatusAndStillShowsTheWindowFigure() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(
                isReached: true,
                windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 100, sense: .used),
                    resetsAt: now.addingTimeInterval(1800)
                )]
            )])),
            now: now
        )
        let section = try XCTUnwrap(loaded(state).sections.first)
        let row = try XCTUnwrap(section.rows.first)

        // The bucket says reached; the window still reports what the provider measured and
        // keeps its reset detail.
        XCTAssertEqual(section.statusText, "Limit reached")
        XCTAssertEqual(row.valueText, "100% used")
        XCTAssertTrue(try XCTUnwrap(row.detailText).hasPrefix("Resets "))
    }

    // MARK: - Staleness

    func testStaleSnapshotStatesItsAge() throws {
        let observed = now.addingTimeInterval(-3 * 3600)
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(
                buckets: [bucket(windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 62, sense: .used),
                    observedAt: observed
                )])],
                observedAt: observed
            )),
            now: now
        )
        let footnote = try XCTUnwrap(loaded(state).footnote)
        XCTAssertEqual(footnote, "Last seen 3 hours ago — may be out of date")
    }

    func testElapsedResetIsCalledOutRatherThanShownAsRefilled() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(windows: [window(
                percent: ProviderQuotaPercent(rawValue: 93, sense: .used),
                resetsAt: now.addingTimeInterval(-600),
                observedAt: now.addingTimeInterval(-900)
            )])])),
            now: now
        )
        let result = try loaded(state)
        let row = try XCTUnwrap(result.sections.first?.rows.first)
        XCTAssertEqual(row.valueText, "93% used", "the observed value is kept, not refilled")
        XCTAssertTrue(try XCTUnwrap(row.detailText).contains("Window reset"))
        XCTAssertTrue(try XCTUnwrap(result.footnote).contains("since reset"))
    }

    func testSpendOnlyExpiredResetIsCalledOutAndMarkedStale() throws {
        let spendControl = ProviderQuotaSpendControl(
            limitRaw: "$100",
            usedRaw: "$62",
            percent: ProviderQuotaPercent(rawValue: 38, sense: .remaining, declaredUpperBound: 100),
            resetsAt: now.addingTimeInterval(-600),
            isReached: false,
            observedAt: now.addingTimeInterval(-900)
        )
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(
                buckets: [bucket(spendControl: spendControl, windows: [])],
                observedAt: spendControl.observedAt
            )),
            now: now
        )
        let result = try loaded(state)
        let row = try XCTUnwrap(result.sections.first?.rows.first)

        XCTAssertEqual(row.valueText, "38% remaining", "the old value is retained, not synthesized")
        XCTAssertTrue(try XCTUnwrap(row.detailText).contains("Spend limit reset"))
        XCTAssertTrue(try XCTUnwrap(result.footnote).contains("since reset"))
    }

    // MARK: - Coverage and capability

    func testAggregateOnlyCoverageIsLabelledAsAllModels() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(
                buckets: [bucket(label: nil, windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 62, sense: .used)
                )])],
                coverage: .accountWideAggregateOnly
            )),
            now: now
        )
        XCTAssertEqual(try loaded(state).sections.first?.title, "Plan usage (all models)")
    }

    func testPerModelBucketUsesProviderLabelAndDoesNotClaimAllModels() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(
                buckets: [bucket(label: "Codex Mini", alias: "gpt-5-codex-mini", windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 5, sense: .used)
                )])],
                coverage: .modelFamilies(["gpt-5-codex-mini"])
            )),
            now: now
        )
        let title = try XCTUnwrap(loaded(state).sections.first?.title)
        XCTAssertEqual(title, "Codex Mini")
        XCTAssertFalse(title.contains("all models"))
    }

    func testOrdinaryUsageDisallowedSurfacesIndependentlyOfPercentages() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(
                buckets: [bucket(windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 2, sense: .used)
                )])],
                ordinaryUsageAllowed: false
            )),
            now: now
        )
        XCTAssertEqual(
            try loaded(state).notice,
            "Standard usage unavailable on this account right now"
        )
    }

    // MARK: - Bucket and window ordering / titles

    func testBucketsRenderInProviderOrderAndAreNeverCollapsed() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [
                bucket(id: "codex", label: "Codex", windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 62, sense: .used)
                )]),
                bucket(id: "codex-mini", label: "Codex Mini", windows: [window(
                    bucket: "codex-mini",
                    percent: ProviderQuotaPercent(rawValue: 5, sense: .used)
                )])
            ])),
            now: now
        )
        XCTAssertEqual(try loaded(state).sections.map(\.title), ["Codex", "Codex Mini"])
    }

    func testWindowTitlesDeriveFromProviderDeclaredDuration() {
        XCTAssertEqual(
            ProviderQuotaPresenter.windowTitle(for: window(percent: nil, duration: 300 * 60)),
            "5-hour limit"
        )
        XCTAssertEqual(
            ProviderQuotaPresenter.windowTitle(for: window(percent: nil, duration: 10080 * 60)),
            "Weekly limit"
        )
        // No declared duration: fall back to the provider's own role name, invent nothing.
        XCTAssertEqual(
            ProviderQuotaPresenter.windowTitle(for: window(role: "secondary", percent: nil, duration: nil)),
            "Secondary"
        )
    }
}
