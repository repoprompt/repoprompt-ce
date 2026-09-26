@testable import RepoPromptApp
import XCTest

/// Domain + sparse-merge semantics for account quota.
///
/// These assertions encode the upstream-documented merge contract: a delta merges into the
/// most recent snapshot, and a value absent from a rolling update does not clear a
/// previously observed one.
final class ProviderQuotaModelTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    private func window(
        bucket: String,
        role: String,
        used: Double?,
        duration: TimeInterval? = nil,
        resetsAt: Date? = nil,
        observedAt: Date
    ) -> ProviderQuotaWindowDelta {
        ProviderQuotaWindowDelta(
            key: ProviderQuotaWindowKey(
                bucketID: ProviderQuotaBucketID(rawValue: bucket),
                nativeRole: role
            ),
            percent: used.map { ProviderQuotaPercent(rawValue: $0, sense: .used) },
            windowDuration: duration,
            resetsAt: resetsAt,
            observedAt: observedAt
        )
    }

    private func delta(
        accountID: String? = "acct-1",
        buckets: [ProviderQuotaBucketDelta],
        ordinaryUsageAllowed: Bool? = nil,
        source: ProviderQuotaSource = .codexAppServerRead,
        observedAt: Date,
        coverage: ProviderQuotaCoverage = .accountWide
    ) -> ProviderQuotaSnapshotDelta {
        ProviderQuotaSnapshotDelta(
            accountKey: .codex(accountID: accountID),
            buckets: buckets,
            ordinaryUsageAllowed: ordinaryUsageAllowed,
            source: source,
            observedAt: observedAt,
            coverage: coverage
        )
    }

    private func merged(
        _ delta: ProviderQuotaSnapshotDelta,
        into previous: ProviderQuotaSnapshot?
    ) throws -> ProviderQuotaSnapshot {
        guard case let .merged(snapshot) = ProviderQuotaMerge.apply(delta, to: previous) else {
            throw XCTSkip("expected a merged snapshot")
        }
        return snapshot
    }

    // MARK: - Bucket vs window identity

    func testPrimaryAndSecondaryWindowsOfOneBucketDoNotOverwriteEachOther() throws {
        let initial = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [
                        window(bucket: "codex", role: "primary", used: 10, observedAt: base),
                        window(bucket: "codex", role: "secondary", used: 20, observedAt: base)
                    ]
                )],
                observedAt: base
            ),
            into: nil
        )

        // A delta that mentions only `primary` must leave `secondary` untouched.
        let updated = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 55, observedAt: base + 60)]
                )],
                source: .codexAppServerNotification,
                observedAt: base + 60
            ),
            into: initial
        )

        let bucket = try XCTUnwrap(updated.buckets.first)
        XCTAssertEqual(bucket.windows.count, 2)
        XCTAssertEqual(bucket.window(role: "primary")?.percent?.rawValue, 55)
        XCTAssertEqual(bucket.window(role: "secondary")?.percent?.rawValue, 20)
        // Only the mentioned window advances its observation time.
        XCTAssertEqual(bucket.window(role: "secondary")?.observedAt, base)
        XCTAssertEqual(bucket.window(role: "primary")?.observedAt, base + 60)
    }

    func testBucketAbsentFromDeltaRetainsPriorValue() throws {
        let initial = try merged(
            delta(
                buckets: [
                    ProviderQuotaBucketDelta(
                        bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                        windows: [window(bucket: "codex", role: "primary", used: 10, observedAt: base)]
                    ),
                    ProviderQuotaBucketDelta(
                        bucketID: ProviderQuotaBucketID(rawValue: "codex-mini"),
                        windows: [window(bucket: "codex-mini", role: "primary", used: 80, observedAt: base)]
                    )
                ],
                observedAt: base
            ),
            into: nil
        )

        let updated = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 11, observedAt: base + 30)]
                )],
                observedAt: base + 30
            ),
            into: initial
        )

        XCTAssertEqual(updated.buckets.count, 2)
        XCTAssertEqual(updated.buckets.map(\.bucketID.rawValue), ["codex", "codex-mini"], "provider order preserved")
        XCTAssertEqual(updated.buckets[1].window(role: "primary")?.percent?.rawValue, 80)
    }

    func testAbsentFieldMeansUnchangedNotNil() throws {
        let initial = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    displayLabel: "Codex",
                    nativeModelAlias: "gpt-5-codex",
                    planType: "pro",
                    credits: ProviderQuotaCredits(hasCredits: true, unlimited: false, balanceRaw: "12.50"),
                    windows: [window(
                        bucket: "codex",
                        role: "primary",
                        used: 10,
                        duration: 18000,
                        resetsAt: base + 9000,
                        observedAt: base
                    )]
                )],
                ordinaryUsageAllowed: true,
                observedAt: base
            ),
            into: nil
        )

        // A sparse update carrying only the percentage must not erase labels, facets, the
        // window duration, or the reset time.
        let updated = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 42, observedAt: base + 60)]
                )],
                observedAt: base + 60
            ),
            into: initial
        )

        let bucket = try XCTUnwrap(updated.buckets.first)
        XCTAssertEqual(bucket.displayLabel, "Codex")
        XCTAssertEqual(bucket.nativeModelAlias, "gpt-5-codex")
        XCTAssertEqual(bucket.planType, "pro")
        XCTAssertEqual(bucket.credits?.balanceRaw, "12.50")
        XCTAssertEqual(bucket.window(role: "primary")?.windowDuration, 18000)
        XCTAssertEqual(bucket.window(role: "primary")?.resetsAt, base + 9000)
        XCTAssertEqual(updated.facets.ordinaryUsageAllowed, true)
    }

    // MARK: - Percent semantics

    func testRemainingSenseIsNeverSilentlyTreatedAsUsed() {
        let remaining = ProviderQuotaPercent(rawValue: 38, sense: .remaining, declaredUpperBound: 100)
        XCTAssertEqual(remaining.sense, .remaining)
        XCTAssertEqual(remaining.usedPercentIfDerivable, 62)

        let used = ProviderQuotaPercent(rawValue: 38, sense: .used)
        XCTAssertEqual(used.usedPercentIfDerivable, 38)
        XCTAssertNotEqual(used, remaining, "sense participates in equality")
    }

    func testRemainingWithoutDeclaredBoundIsNotGuessed() {
        let remaining = ProviderQuotaPercent(rawValue: 38, sense: .remaining, declaredUpperBound: nil)
        XCTAssertNil(remaining.usedPercentIfDerivable, "no bound means no derivation, not an assumed 100")
    }

    func testValueAboveDeclaredBoundIsPreservedButBarClamps() {
        let percent = ProviderQuotaPercent(rawValue: 112, sense: .used, declaredUpperBound: 100)
        XCTAssertEqual(percent.rawValue, 112, "printed figure is never clamped")
        XCTAssertEqual(percent.clampedForDisplay(), 100, "bar clamps")
    }

    func testNegativeValueClampsOnlyForDisplay() {
        let percent = ProviderQuotaPercent(rawValue: -5, sense: .used)
        XCTAssertEqual(percent.rawValue, -5)
        XCTAssertEqual(percent.clampedForDisplay(), 0)
    }

    // MARK: - Reached / capability independence

    func testIsReachedIsIndependentOfPercentage() throws {
        let snapshot = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    reachedType: "rate_limit_reached",
                    isReached: true,
                    windows: [window(bucket: "codex", role: "primary", used: 3, observedAt: base)]
                )],
                observedAt: base
            ),
            into: nil
        )

        let bucket = try XCTUnwrap(snapshot.buckets.first)
        XCTAssertEqual(bucket.isReached, true, "an explicit provider flag outranks a low percentage")
        XCTAssertEqual(bucket.window(role: "primary")?.percent?.rawValue, 3)
    }

    func testOrdinaryUsageAllowedFalseSurvivesMergeAndIsIndependentOfPercentages() throws {
        let initial = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 1, observedAt: base)]
                )],
                ordinaryUsageAllowed: false,
                observedAt: base
            ),
            into: nil
        )
        XCTAssertEqual(initial.facets.ordinaryUsageAllowed, false)

        let updated = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 2, observedAt: base + 10)]
                )],
                observedAt: base + 10
            ),
            into: initial
        )
        XCTAssertEqual(updated.facets.ordinaryUsageAllowed, false, "absent facet does not clear a known one")
    }

    // MARK: - Freshness

    func testUnknownIsNotFullAndHasNoWindows() {
        let snapshot = ProviderQuotaSnapshot(
            accountKey: .codex(accountID: "acct-1"),
            buckets: [],
            facets: .empty,
            source: .codexAppServerRead,
            coverage: .accountWide,
            observedAt: base
        )
        XCTAssertEqual(snapshot.availability(now: base), .unknown)
    }

    func testSnapshotFreshnessTakesOldestContributingWindow() throws {
        // 5-hour window: horizon is a fraction of the window, so a 4-hour-old reading is stale.
        let snapshot = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [
                        window(bucket: "codex", role: "primary", used: 10, duration: 18000, observedAt: base),
                        window(
                            bucket: "codex",
                            role: "secondary",
                            used: 20,
                            duration: 18000,
                            observedAt: base - 14400
                        )
                    ]
                )],
                observedAt: base
            ),
            into: nil
        )

        let availability = snapshot.availability(now: base)
        guard case let .stale(observedAt, reason) = availability else {
            return XCTFail("expected stale, got \(availability)")
        }
        XCTAssertEqual(reason, .observationAged)
        XCTAssertEqual(observedAt, base - 14400, "oldest contributor, never the newest")
    }

    func testElapsedResetMarksWindowStaleWithoutSynthesizingARefill() {
        let expired = ProviderQuotaWindow(
            key: ProviderQuotaWindowKey(
                bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                nativeRole: "primary"
            ),
            percent: ProviderQuotaPercent(rawValue: 93, sense: .used),
            windowDuration: 18000,
            resetsAt: base - 60,
            observedAt: base - 120
        )
        let availability = ProviderQuotaSnapshot.availability(for: expired, now: base)
        XCTAssertEqual(availability, .stale(observedAt: base - 120, reason: .resetElapsed))
        XCTAssertEqual(expired.percent?.rawValue, 93, "values are kept; only the label changes")
    }

    func testSparseWindowUpdateRetainsSpendControlWithItsOriginalObservationTime() throws {
        let spendControl = ProviderQuotaSpendControl(
            limitRaw: "$100",
            usedRaw: "$62",
            percent: ProviderQuotaPercent(rawValue: 38, sense: .remaining, declaredUpperBound: 100),
            resetsAt: nil,
            isReached: false,
            observedAt: base
        )
        let initial = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    spendControl: spendControl,
                    windows: [window(
                        bucket: "codex",
                        role: "primary",
                        used: 10,
                        duration: 18000,
                        observedAt: base
                    )]
                )],
                observedAt: base
            ),
            into: nil
        )

        let later = base.addingTimeInterval(20 * 60)
        let updated = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(
                        bucket: "codex",
                        role: "primary",
                        used: 20,
                        duration: 18000,
                        observedAt: later
                    )]
                )],
                source: .codexAppServerNotification,
                observedAt: later
            ),
            into: initial
        )

        XCTAssertEqual(updated.buckets.first?.spendControl?.observedAt, base)
        XCTAssertEqual(
            updated.availability(now: later),
            .stale(observedAt: base, reason: .observationAged),
            "fresh window activity must not make retained spend metadata look fresh"
        )
    }

    // MARK: - Account identity

    func testDeltaForDifferentAccountIsReportedAsMismatch() throws {
        let initial = try merged(
            delta(
                accountID: "acct-1",
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 10, observedAt: base)]
                )],
                observedAt: base
            ),
            into: nil
        )

        let outcome = ProviderQuotaMerge.apply(
            delta(
                accountID: "acct-2",
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 90, observedAt: base + 5)]
                )],
                observedAt: base + 5
            ),
            to: initial
        )
        XCTAssertEqual(outcome, .accountMismatch)
    }

    func testUnidentifiedNotificationMergesIntoIdentifiedSnapshotAndKeepsIdentity() throws {
        let initial = try merged(
            delta(
                accountID: "acct-1",
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 10, observedAt: base)]
                )],
                observedAt: base
            ),
            into: nil
        )

        // A push notification carries no account ID; it must not orphan the known identity.
        let updated = try merged(
            delta(
                accountID: nil,
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 44, observedAt: base + 5)]
                )],
                source: .codexAppServerNotification,
                observedAt: base + 5
            ),
            into: initial
        )
        XCTAssertEqual(updated.accountKey.opaqueAccountID, "acct-1")
        XCTAssertEqual(updated.buckets.first?.window(role: "primary")?.percent?.rawValue, 44)
    }

    func testDifferentLineageNeverRefersToSameAccount() {
        let codex = ProviderAccountKey(lineage: .codexFirstParty, opaqueAccountID: "same")
        let anthropic = ProviderAccountKey(lineage: .anthropicFirstParty, opaqueAccountID: "same")
        XCTAssertFalse(codex.refersToSameAccount(as: anthropic))
        XCTAssertNotEqual(codex, anthropic)

        let compatible = ProviderAccountKey(lineage: .claudeCompatible(backendID: "zai"), opaqueAccountID: "same")
        XCTAssertFalse(anthropic.refersToSameAccount(as: compatible))
    }

    // MARK: - Redaction

    func testAccountKeyMirrorExposesBooleansOnly() {
        let key = ProviderAccountKey.codex(accountID: "secret-account-id")
        let mirror = String(describing: Mirror(reflecting: key).children.map { "\($0.label ?? ""):\($0.value)" })
        XCTAssertFalse(mirror.contains("secret-account-id"))
        XCTAssertTrue(mirror.contains("hasAccountID:true"))
        XCTAssertFalse("\(key)".contains("secret-account-id"))
    }

    func testSnapshotDescriptionIsShapeOnly() throws {
        let snapshot = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    planType: "pro",
                    windows: [window(bucket: "codex", role: "primary", used: 87, observedAt: base)]
                )],
                observedAt: base
            ),
            into: nil
        )
        let described = "\(snapshot)"
        XCTAssertEqual(described, "ProviderQuotaSnapshot(1 buckets, 1 windows)")
        XCTAssertFalse(described.contains("87"))
        XCTAssertFalse(described.contains("pro"))
    }

    // MARK: - Coverage

    func testAggregateOnlyCoverageIsNeverWidenedByALaterDelta() throws {
        let initial = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 10, observedAt: base)]
                )],
                observedAt: base,
                coverage: .accountWideAggregateOnly
            ),
            into: nil
        )

        let updated = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex"),
                    windows: [window(bucket: "codex", role: "primary", used: 12, observedAt: base + 5)]
                )],
                observedAt: base + 5,
                coverage: .accountWide
            ),
            into: initial
        )
        XCTAssertEqual(updated.coverage, .accountWideAggregateOnly)
    }

    func testModelFamilyCoverageIsNotWidenedBySparseAccountWideDelta() throws {
        let initial = try merged(
            delta(
                buckets: [ProviderQuotaBucketDelta(
                    bucketID: ProviderQuotaBucketID(rawValue: "codex-model"),
                    nativeModelAlias: "gpt-5-codex",
                    windows: [window(bucket: "codex-model", role: "primary", used: 10, observedAt: base)]
                )],
                observedAt: base,
                coverage: .modelFamilies(["gpt-5-codex"])
            ),
            into: nil
        )

        let updated = try merged(
            delta(
                buckets: [],
                source: .codexAppServerNotification,
                observedAt: base + 5,
                coverage: .accountWide
            ),
            into: initial
        )

        XCTAssertEqual(updated.coverage, .modelFamilies(["gpt-5-codex"]))
        XCTAssertEqual(updated.buckets.first?.window(role: "primary")?.percent?.rawValue, 10)
    }
}
