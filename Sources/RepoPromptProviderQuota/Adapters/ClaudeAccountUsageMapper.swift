import Foundation

/// Account API fields are percentage units, never SDK fractions. A full response replaces
/// the prior account inventory. Omitted values stay unknown; display labels do not establish
/// model identity. Extra spend/credits are not subscription headroom and are not synthesized.
package enum ClaudeAccountUsageMapper {
    private struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey { case utilization
            case resetsAt = "resets_at"
        }
    }

    private struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let id: String?
                let displayName: String?
                enum CodingKeys: String, CodingKey { case id
                    case displayName = "display_name"
                }
            }

            let model: Model?
        }

        let kind: String?
        let group: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
        enum CodingKeys: String, CodingKey { case kind, group, percent, scope
            case resetsAt = "resets_at"
        }
    }

    private struct Payload: Decodable {
        let windows: [(String, Window)]
        let limits: [Limit]
        struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? {
                nil
            }

            init?(stringValue: String) {
                self.stringValue = stringValue
            }

            init(_ value: String) {
                stringValue = value
            }

            init?(intValue: Int) {
                nil
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let keys = container.allKeys.filter { $0.stringValue == "five_hour" || $0.stringValue.hasPrefix("seven_day") }
            let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]
            windows = try keys.sorted {
                let a = order.firstIndex(of: $0.stringValue) ?? order.count
                let b = order.firstIndex(of: $1.stringValue) ?? order.count
                return a == b ? $0.stringValue < $1.stringValue : a < b
            }.compactMap { key in
                if try container.decodeNil(forKey: key) { return nil }
                return try (key.stringValue, container.decode(Window.self, forKey: key))
            }
            limits = try container.decodeIfPresent([Limit].self, forKey: Key("limits")) ?? []
        }
    }

    package static func snapshot(data: Data, account: ProviderAccountKey, observedAt: Date) throws -> ProviderQuotaSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let formatter = ISO8601DateFormatter()
        func reset(_ raw: String?) -> Date? {
            guard let raw else { return nil }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }
        func window(id: ProviderQuotaBucketID, role: String, percent: Double?, resetAt: String?, duration: TimeInterval?) -> ProviderQuotaWindow {
            ProviderQuotaWindow(
                key: .init(bucketID: id, nativeRole: role),
                percent: percent.flatMap { $0.isFinite ? ProviderQuotaPercent(rawValue: $0, sense: .used, declaredUpperBound: 100) : nil },
                windowDuration: duration,
                resetsAt: reset(resetAt),
                observedAt: observedAt
            )
        }
        func bucket(id: ProviderQuotaBucketID, label: String?, scope: ProviderQuotaBucketScope, windows: [ProviderQuotaWindow]) -> ProviderQuotaBucket {
            ProviderQuotaBucket(
                bucketID: id,
                displayLabel: label,
                nativeModelAlias: nil,
                scope: scope,
                reachedType: nil,
                isReached: nil,
                planType: nil,
                credits: nil,
                spendControl: nil,
                windows: windows
            )
        }

        // Both providers expose one account-plan bucket with separate real windows. This
        // prevents duplicate headings and keeps the common UI's structure provider-neutral.
        let accountID = ProviderQuotaBucketID(rawValue: "rpce.claude.account-plan", isSynthesized: true)
        let accountWindows = payload.windows.filter { $0.0 == "five_hour" || $0.0 == "seven_day" }.map { name, value in
            window(
                id: accountID,
                role: name,
                percent: value.utilization,
                resetAt: value.resetsAt,
                duration: name == "five_hour" ? 18000 : 604_800
            )
        }
        var buckets: [ProviderQuotaBucket] = accountWindows.isEmpty ? [] : [bucket(id: accountID, label: nil, scope: .accountWide, windows: accountWindows)]
        for (name, value) in payload.windows where name != "five_hour" && name != "seven_day" {
            let id = ProviderQuotaBucketID(rawValue: name)
            let scope: ProviderQuotaBucketScope
            let label: String
            switch name {
            case "seven_day_sonnet": scope = .nativeModelAlias("sonnet")
                label = "Sonnet weekly limit"
            case "seven_day_opus": scope = .nativeModelAlias("opus")
                label = "Opus weekly limit"
            default: scope = .unattributed
                label = name.replacingOccurrences(of: "_", with: " ").capitalized
            }
            buckets.append(bucket(
                id: id,
                label: label,
                scope: scope,
                windows: [window(id: id, role: name, percent: value.utilization, resetAt: value.resetsAt, duration: 604_800)]
            ))
        }
        // New provider-declared inventory is retained in native array order, without guessing
        // equivalence with coarse legacy family windows or turning a model label into an ID.
        for (index, limit) in payload.limits.enumerated() {
            let id = ProviderQuotaBucketID(rawValue: "rpce.claude.limit.\(index)", isSynthesized: true)
            let model = limit.scope?.model
            let identifier = model?.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            let scope: ProviderQuotaBucketScope = identifier.flatMap { $0.isEmpty ? nil : ProviderQuotaBucketScope.nativeModelAlias($0) } ?? .unattributed
            let label = model?.displayName ?? limit.kind?.replacingOccurrences(of: "_", with: " ").capitalized
            buckets.append(bucket(
                id: id,
                label: label,
                scope: scope,
                windows: [window(
                    id: id,
                    role: limit.kind ?? "reported",
                    percent: limit.percent,
                    resetAt: limit.resetsAt,
                    duration: limit.group == "weekly" ? 604_800 : nil
                )]
            ))
        }
        guard !buckets.isEmpty else { throw ProviderQuotaReadError.invalidResponse }
        return ProviderQuotaSnapshot(
            accountKey: account,
            buckets: buckets,
            facets: .empty,
            source: .claudeOAuthRead,
            coverage: .accountWide,
            observedAt: observedAt
        )
    }
}
