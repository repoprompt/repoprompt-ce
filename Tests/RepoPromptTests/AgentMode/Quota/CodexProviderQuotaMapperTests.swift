import Foundation
@testable import RepoPromptApp
import XCTest

/// Decode tests over the Codex app-server account rate-limit payloads.
///
/// Payload shapes here follow the schema generated from the pinned Codex CLI
/// (`codex app-server generate-json-schema --experimental`), which is camelCase on the wire.
/// `ordinaryUsageAllowed` and `normalModelSlug` exist only on Codex >= 0.155.1; the floor
/// case is covered explicitly.
final class CodexProviderQuotaMapperTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func object(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonValues(_ json: String) throws -> [String: CodexJSONValue] {
        try object(json).compactMapValues { CodexJSONValue.from($0) }
    }

    // MARK: - Read response

    func testMapsMultipleBucketsWithPrimaryAndSecondaryWindows() throws {
        let payload = try object("""
        {
          "accountId": "acct-123",
          "ordinaryUsageAllowed": true,
          "rateLimits": {
            "limitId": "codex",
            "limitName": "Codex",
            "normalModelSlug": "gpt-5-codex",
            "planType": "pro",
            "primary": { "usedPercent": 62, "windowDurationMins": 300, "resetsAt": 1700009000 },
            "secondary": { "usedPercent": 21, "windowDurationMins": 10080, "resetsAt": 1700600000 },
            "rateLimitReachedType": null,
            "spendControlReached": false
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "limitName": "Codex",
              "normalModelSlug": "gpt-5-codex",
              "primary": { "usedPercent": 62, "windowDurationMins": 300, "resetsAt": 1700009000 },
              "secondary": { "usedPercent": 21, "windowDurationMins": 10080, "resetsAt": 1700600000 }
            },
            "codex-mini": {
              "limitId": "codex-mini",
              "limitName": "Codex Mini",
              "normalModelSlug": "gpt-5-codex-mini",
              "primary": { "usedPercent": 5, "windowDurationMins": 300 }
            }
          }
        }
        """)

        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: nil,
            observedAt: observedAt
        ))

        XCTAssertEqual(delta.accountKey.opaqueAccountID, "acct-123")
        XCTAssertEqual(delta.ordinaryUsageAllowed, true)
        XCTAssertEqual(delta.source, .codexAppServerRead)

        // The top-level `rateLimits` duplicates the "codex" map entry and must not be
        // admitted a second time.
        XCTAssertEqual(delta.buckets.count, 2)
        XCTAssertEqual(delta.buckets.map(\.bucketID.rawValue).sorted(), ["codex", "codex-mini"])

        let codex = try XCTUnwrap(delta.buckets.first { $0.bucketID.rawValue == "codex" })
        XCTAssertEqual(codex.displayLabel, "Codex")
        XCTAssertEqual(codex.nativeModelAlias, "gpt-5-codex")
        XCTAssertEqual(codex.windows.count, 2)

        let primary = try XCTUnwrap(codex.windows.first { $0.key.nativeRole == "primary" })
        XCTAssertEqual(primary.percent?.rawValue, 62)
        XCTAssertEqual(primary.percent?.sense, .used)
        XCTAssertEqual(primary.windowDuration, 300 * 60)
        XCTAssertEqual(primary.resetsAt, Date(timeIntervalSince1970: 1_700_009_000))

        let secondary = try XCTUnwrap(codex.windows.first { $0.key.nativeRole == "secondary" })
        XCTAssertEqual(secondary.percent?.rawValue, 21)
        XCTAssertEqual(secondary.windowDuration, 10080 * 60)

        XCTAssertEqual(delta.coverage, .modelFamilies(["gpt-5-codex", "gpt-5-codex-mini"]))
    }

    func testTopLevelBucketIsAdmittedWhenItMatchesNoMapEntry() throws {
        let payload = try object("""
        {
          "rateLimits": {
            "limitId": "legacy",
            "primary": { "usedPercent": 40 }
          },
          "rateLimitsByLimitId": {
            "codex": { "limitId": "codex", "primary": { "usedPercent": 10 } }
          }
        }
        """)

        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: nil,
            observedAt: observedAt
        ))
        XCTAssertEqual(delta.buckets.count, 2)
        XCTAssertTrue(delta.buckets.contains { $0.bucketID.rawValue == "legacy" })
        XCTAssertTrue(delta.buckets.contains { $0.bucketID.rawValue == "codex" })
    }

    func testTopLevelBucketWithoutLimitIDSynthesizesAMarkedID() throws {
        let payload = try object("""
        { "rateLimits": { "primary": { "usedPercent": 33 } } }
        """)

        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: "acct-fallback",
            observedAt: observedAt
        ))
        let bucket = try XCTUnwrap(delta.buckets.first)
        XCTAssertTrue(bucket.bucketID.isSynthesized, "never fabricate a provider-looking limitId")
        XCTAssertEqual(delta.accountKey.opaqueAccountID, "acct-fallback")
        // No model attribution means account-wide, regardless of which field it arrived in.
        XCTAssertEqual(delta.coverage, .accountWide)
    }

    func testTopLevelWithoutLimitIDIsNotSynthesizedAlongsideANonEmptyMap() throws {
        // Floor-shaped payload: 0.153.4 omits `normalModelSlug`, and the compatibility copy
        // carries no `limitId`. It mirrors one of the map buckets, so admitting it would
        // double-count real usage under a synthesized identity.
        let payload = try object("""
        {
          "accountId": "acct-123",
          "rateLimits": {
            "limitName": "Codex",
            "primary": { "usedPercent": 62, "windowDurationMins": 300 },
            "secondary": { "usedPercent": 21, "windowDurationMins": 10080 }
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "limitName": "Codex",
              "primary": { "usedPercent": 62, "windowDurationMins": 300 },
              "secondary": { "usedPercent": 21, "windowDurationMins": 10080 }
            }
          }
        }
        """)

        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: nil,
            observedAt: observedAt
        ))

        XCTAssertEqual(delta.buckets.count, 1, "the compatibility copy is not a second bucket")
        XCTAssertEqual(delta.buckets.first?.bucketID.rawValue, "codex")
        XCTAssertFalse(
            delta.buckets.contains { $0.bucketID.isSynthesized },
            "no synthesized bucket is invented when the map already describes the account"
        )
    }

    func testTopLevelWithoutLimitIDIsStillAdmittedWhenTheMapIsEmpty() throws {
        // With an empty map the compatibility copy is the only description of the account.
        let payload = try object("""
        {
          "rateLimits": { "primary": { "usedPercent": 33 } },
          "rateLimitsByLimitId": {}
        }
        """)

        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: nil,
            observedAt: observedAt
        ))
        XCTAssertEqual(delta.buckets.count, 1)
        XCTAssertTrue(try XCTUnwrap(delta.buckets.first).bucketID.isSynthesized)
    }

    // MARK: - Fields newer than the pinned floor

    //
    // `ordinaryUsageAllowed` and `normalModelSlug` arrived in Codex 0.155.1 and are absent at
    // the 0.153.4 contract floor, so the schema gate cannot declare them (it has no
    // "validate only when present" presence value). These tests are the only drift
    // protection those two fields have until the floor moves; see
    // docs/architecture/codex-app-server-schema-gate.md.

    func testNewerFieldsDecodeWithTheirDeclaredShapesWhenPresent() throws {
        let payload = try object("""
        {
          "accountId": "acct-123",
          "ordinaryUsageAllowed": false,
          "rateLimits": {
            "limitId": "codex",
            "normalModelSlug": "gpt-5-codex",
            "primary": { "usedPercent": 62 }
          }
        }
        """)

        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: nil,
            observedAt: observedAt
        ))
        XCTAssertEqual(delta.ordinaryUsageAllowed, false, "boolean at response level")
        XCTAssertEqual(delta.buckets.first?.nativeModelAlias, "gpt-5-codex", "string at bucket level")
        XCTAssertEqual(delta.coverage, .modelFamilies(["gpt-5-codex"]))
    }

    func testNewerFieldsWithWrongTypesAreIgnoredRatherThanCoerced() throws {
        // A retype upstream must degrade to "unknown", never to a fabricated value.
        let payload = try object("""
        {
          "ordinaryUsageAllowed": "false",
          "rateLimits": {
            "limitId": "codex",
            "normalModelSlug": 42,
            "primary": { "usedPercent": 62 }
          }
        }
        """)

        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: nil,
            observedAt: observedAt
        ))
        XCTAssertNil(delta.ordinaryUsageAllowed, "a string is not read as a boolean")
        XCTAssertNil(delta.buckets.first?.nativeModelAlias, "a number is not read as a slug")
        XCTAssertEqual(delta.coverage, .accountWide)
    }

    func testCreditsAndSpendControlDecodeWithRemainingSense() throws {
        let payload = try object("""
        {
          "rateLimits": {
            "limitId": "codex",
            "credits": { "hasCredits": true, "unlimited": false, "balance": "12.50" },
            "individualLimit": {
              "limit": "$100",
              "used": "$62",
              "remainingPercent": 38,
              "resetsAt": 1700600000
            },
            "spendControlReached": false,
            "primary": { "usedPercent": 62 }
          }
        }
        """)

        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: nil,
            observedAt: observedAt
        ))
        let bucket = try XCTUnwrap(delta.buckets.first)

        XCTAssertEqual(bucket.credits?.hasCredits, true)
        XCTAssertEqual(bucket.credits?.unlimited, false)
        XCTAssertEqual(bucket.credits?.balanceRaw, "12.50", "balance stays the provider's own string")

        let spendControl = try XCTUnwrap(bucket.spendControl)
        XCTAssertEqual(spendControl.percent.rawValue, 38)
        XCTAssertEqual(spendControl.percent.sense, .remaining, "Codex spend control reports REMAINING")
        XCTAssertEqual(spendControl.percent.declaredUpperBound, 100)
        XCTAssertEqual(spendControl.limitRaw, "$100")
        XCTAssertEqual(spendControl.usedRaw, "$62")
        XCTAssertEqual(spendControl.isReached, false)
        XCTAssertEqual(spendControl.observedAt, observedAt)
    }

    func testReachedTypeSetsIsReachedAndAbsenceStaysUnknown() throws {
        let reached = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            object("""
            { "rateLimits": { "limitId": "codex", "rateLimitReachedType": "rate_limit_reached",
              "primary": { "usedPercent": 100 } } }
            """),
            fallbackAccountID: nil,
            observedAt: observedAt
        ))
        XCTAssertEqual(reached.buckets.first?.reachedType, "rate_limit_reached")
        XCTAssertEqual(reached.buckets.first?.isReached, true)

        let notReported = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            object(#"{ "rateLimits": { "limitId": "codex", "primary": { "usedPercent": 10 } } }"#),
            fallbackAccountID: nil,
            observedAt: observedAt
        ))
        XCTAssertNil(notReported.buckets.first?.isReached, "absence is unknown, not 'not reached'")
    }

    func testPinnedFloorPayloadWithoutNewerFieldsDecodesWithUnknowns() throws {
        // Codex 0.153.4 (the contract's minimumCodexVersion) has neither
        // `ordinaryUsageAllowed` nor `normalModelSlug`.
        let payload = try object("""
        {
          "accountId": "acct-123",
          "rateLimits": {
            "limitId": "codex",
            "limitName": "Codex",
            "primary": { "usedPercent": 62, "windowDurationMins": 300 }
          }
        }
        """)

        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: nil,
            observedAt: observedAt
        ))
        XCTAssertNil(delta.ordinaryUsageAllowed, "unknown, not false")
        XCTAssertNil(delta.buckets.first?.nativeModelAlias)
        XCTAssertEqual(delta.coverage, .accountWide)
    }

    func testWindowWithoutUsedPercentIsNotSynthesized() throws {
        let payload = try object("""
        { "rateLimits": { "limitId": "codex", "primary": { "windowDurationMins": 300 } } }
        """)
        let delta = CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: nil,
            observedAt: observedAt
        )
        XCTAssertEqual(delta?.buckets.first?.windows.count, 0, "no value means no window, not a zero")
    }

    func testResponseWithoutRateLimitsIsRejected() throws {
        let payload = try object(#"{ "accountId": "acct-123" }"#)
        XCTAssertNil(CodexProviderQuotaMapper.mapReadResponse(
            payload,
            fallbackAccountID: nil,
            observedAt: observedAt
        ))
    }

    // MARK: - Updated notification

    func testUpdatedNotificationMapsASingleBucketDelta() throws {
        // The generated schema for AccountRateLimitsUpdatedNotification carries exactly one
        // `rateLimits` bucket — not a multi-bucket map.
        let params = try jsonValues("""
        {
          "rateLimits": {
            "limitId": "codex",
            "primary": { "usedPercent": 71, "windowDurationMins": 300, "resetsAt": 1700009000 }
          }
        }
        """)

        let delta = try XCTUnwrap(CodexProviderQuotaMapper.mapUpdatedNotification(
            params: params,
            fallbackAccountID: "acct-123",
            observedAt: observedAt
        ))

        XCTAssertEqual(delta.source, .codexAppServerNotification)
        XCTAssertEqual(delta.buckets.count, 1)
        XCTAssertEqual(delta.buckets.first?.bucketID.rawValue, "codex")
        XCTAssertEqual(delta.buckets.first?.windows.first?.percent?.rawValue, 71)
        XCTAssertNil(delta.ordinaryUsageAllowed, "the notification carries no account facet")
        XCTAssertEqual(delta.accountKey.opaqueAccountID, "acct-123")
    }

    func testNotificationMergesIntoExistingSnapshotWithoutDisturbingOtherBuckets() throws {
        let read = try XCTUnwrap(CodexProviderQuotaMapper.mapReadResponse(
            object("""
            {
              "accountId": "acct-123",
              "rateLimits": { "limitId": "codex", "primary": { "usedPercent": 10 },
                              "secondary": { "usedPercent": 20 } },
              "rateLimitsByLimitId": {
                "codex": { "limitId": "codex", "primary": { "usedPercent": 10 },
                           "secondary": { "usedPercent": 20 } },
                "codex-mini": { "limitId": "codex-mini", "primary": { "usedPercent": 80 } }
              }
            }
            """),
            fallbackAccountID: nil,
            observedAt: observedAt
        ))
        guard case let .merged(snapshot) = ProviderQuotaMerge.apply(read, to: nil) else {
            return XCTFail("expected merged snapshot")
        }

        let notification = try XCTUnwrap(CodexProviderQuotaMapper.mapUpdatedNotification(
            params: jsonValues(#"{ "rateLimits": { "limitId": "codex", "primary": { "usedPercent": 99 } } }"#),
            fallbackAccountID: "acct-123",
            observedAt: observedAt + 30
        ))
        guard case let .merged(updated) = ProviderQuotaMerge.apply(notification, to: snapshot) else {
            return XCTFail("expected merged snapshot")
        }

        let codex = try XCTUnwrap(updated.buckets.first { $0.bucketID.rawValue == "codex" })
        XCTAssertEqual(codex.window(role: "primary")?.percent?.rawValue, 99)
        XCTAssertEqual(codex.window(role: "secondary")?.percent?.rawValue, 20, "untouched window retained")

        let mini = try XCTUnwrap(updated.buckets.first { $0.bucketID.rawValue == "codex-mini" })
        XCTAssertEqual(mini.window(role: "primary")?.percent?.rawValue, 80, "unmentioned bucket retained")
    }
}
