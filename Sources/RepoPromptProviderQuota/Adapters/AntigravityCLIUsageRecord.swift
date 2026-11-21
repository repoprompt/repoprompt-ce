import Foundation

/// Projection of Google's documented CLI status-line JSON. No account identity, paths,
/// transcript data, or raw payload survives this boundary.
package struct AntigravityCLIUsageRecord: Codable {
    private struct Reading: Codable {
        let id: String
        let remainingFraction: Double?
        let resetsAt: Date?
    }

    private struct Payload: Decodable {
        struct Bucket: Decodable {
            let fraction: Double?
            let reset: String?
            let resetIn: Double?
            let disabled: Bool

            enum CodingKeys: String, CodingKey {
                case fraction = "remaining_fraction"
                case reset = "reset_time"
                case resetIn = "reset_in_seconds"
                case disabled
            }

            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                fraction = try? fields.decode(Double.self, forKey: .fraction)
                reset = try? fields.decode(String.self, forKey: .reset)
                resetIn = try? fields.decode(Double.self, forKey: .resetIn)
                disabled = try fields.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            }
        }

        let product: String
        let email: String?
        let quota: [String: Bucket]?

        enum CodingKeys: CodingKey { case product, email, quota }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            product = try fields.decode(String.self, forKey: .product)
            email = try? fields.decode(String.self, forKey: .email)
            guard let quotaFields = try? fields.nestedContainer(keyedBy: BucketKey.self, forKey: .quota) else {
                quota = nil
                return
            }
            quota = Dictionary(uniqueKeysWithValues: AntigravityCLIUsageRecord.groups.flatMap(\.ids).compactMap { id in
                guard let bucket = try? quotaFields.decode(Bucket.self, forKey: BucketKey(stringValue: id)) else { return nil }
                return (id, bucket)
            })
        }

        private struct BucketKey: CodingKey {
            let stringValue: String
            var intValue: Int? {
                nil
            }

            init(stringValue: String) {
                self.stringValue = stringValue
            }

            init?(intValue: Int) {
                nil
            }
        }
    }

    /// Status-line quota is a JSON object (no order). Group only observed native IDs, never
    /// infer either the group or the window length from the remaining time until reset.
    private static let groups: [(id: String, label: String, ids: [String])] = [
        ("gemini", "Gemini", ["gemini-5h", "gemini-weekly"]),
        ("3p", "Third-party models", ["3p-5h", "3p-weekly"]),
        ("gemini-argon-wtu", "Gemini Argon (WTU)", ["gemini-argon-wtu-weekly"])
    ]

    private let readings: [Reading]
    package let observedAt: Date

    package static func extract(_ data: Data, at now: Date = Date()) -> Self? {
        guard data.count <= 65536,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.product == "antigravity", payload.email?.isEmpty == false,
              let quota = payload.quota else { return nil }
        let iso = ISO8601DateFormatter()
        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let readings: [Reading] = groups.flatMap(\.ids).compactMap { id in
            guard let bucket = quota[id], !bucket.disabled else { return nil }
            let fraction = bucket.fraction.flatMap { (0 ... 1).contains($0) ? $0 : nil }
            let absolute = bucket.reset.flatMap { fractionalISO.date(from: $0) ?? iso.date(from: $0) }
            let reset = absolute ?? bucket.resetIn.flatMap { seconds in
                seconds.isFinite && seconds > 0 ? now.addingTimeInterval(seconds) : nil
            }
            guard fraction != nil || reset != nil else { return nil }
            return Reading(id: id, remainingFraction: fraction, resetsAt: reset)
        }
        guard !readings.isEmpty else { return nil }
        return Self(readings: readings, observedAt: now)
    }

    package func snapshot() -> ProviderQuotaSnapshot? {
        let buckets: [ProviderQuotaBucket] = Self.groups.compactMap { group in
            let bucketID = ProviderQuotaBucketID(rawValue: "agy.group.\(group.id)", isSynthesized: true)
            let windows = group.ids.compactMap { id -> ProviderQuotaWindow? in
                guard let reading = readings.first(where: { $0.id == id }) else { return nil }
                return ProviderQuotaWindow(
                    key: ProviderQuotaWindowKey(bucketID: bucketID, nativeRole: id),
                    percent: reading.remainingFraction.flatMap {
                        guard (0 ... 1).contains($0) else { return nil }
                        return ProviderQuotaPercent(rawValue: $0 * 100, sense: .remaining, declaredUpperBound: 100)
                    },
                    windowDuration: id.hasSuffix("-5h") ? 5 * 3600 : 7 * 24 * 3600,
                    resetsAt: reading.resetsAt,
                    observedAt: observedAt
                )
            }
            guard !windows.isEmpty else { return nil }
            return ProviderQuotaBucket(
                bucketID: bucketID,
                displayLabel: group.label,
                nativeModelAlias: nil,
                scope: .unattributed,
                reachedType: nil,
                isReached: nil,
                planType: nil,
                credits: nil,
                spendControl: nil,
                windows: windows
            )
        }
        guard !buckets.isEmpty else { return nil }
        return ProviderQuotaSnapshot(
            accountKey: ProviderAccountKey(lineage: .provider(id: .antigravity), opaqueAccountID: nil),
            buckets: buckets,
            facets: .empty,
            source: .providerRead(.antigravity),
            coverage: .reportedBucketsOnly,
            observedAt: observedAt
        )
    }
}
