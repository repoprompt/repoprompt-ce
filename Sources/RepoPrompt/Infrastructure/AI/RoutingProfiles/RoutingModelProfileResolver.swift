import Foundation

enum RoutingProfileFieldSource: Equatable {
    case providerCatalog
    case exactProfile
    case familyProfile
    case genericFallback
}

enum RoutingProfileFreshness: Equatable {
    case current
    case stale
    case unknown
}

struct Provenanced<Value: Equatable>: Equatable {
    let value: Value
    let source: RoutingProfileFieldSource
    let sourceID: String?
    let version: String?
    let freshness: RoutingProfileFreshness
    let checkedAt: Date?

    init(
        value: Value,
        source: RoutingProfileFieldSource,
        sourceID: String?,
        version: String?,
        freshness: RoutingProfileFreshness,
        checkedAt: Date? = nil
    ) {
        self.value = value
        self.source = source
        self.sourceID = sourceID
        self.version = version
        self.freshness = freshness
        self.checkedAt = checkedAt
    }
}

struct ResolvedRoutingProfile: Equatable {
    enum Match: Equatable { case exact, exactAlias, family, unknown }

    let match: Match
    let familyID: Provenanced<String?>
    let executionProviderID: Provenanced<String>
    let modelID: Provenanced<String>
    let displayName: Provenanced<String>
    let advertisedEffortIDs: Provenanced<[String]>
    let executableEffortIDs: Provenanced<[String]>
    let defaultEffortID: Provenanced<String?>
    let utilityTier: Provenanced<String>
    let summary: Provenanced<String>
    let rubric: Provenanced<String>
    let price: Provenanced<String?>
    let evidence: Provenanced<[String]>

    func description(snapshotDate: String) -> String {
        var parts = [summary.value]
        if !evidence.value.isEmpty {
            let prefix = evidence.freshness == .stale ? "Stale historical evidence: " : ""
            parts.append(prefix + evidence.value.joined(separator: " "))
        }
        if let priceText = price.value {
            parts.append(price.freshness == .stale ? "Stale historical price (not current): \(priceText)" : priceText)
        } else {
            parts.append("Price is unknown; no current audited price is available.")
        }
        return "Evidence snapshot \(snapshotDate) (provider-published; API list price is a comparison proxy and CLI or subscription billing may differ): \(parts.joined(separator: " "))"
    }
}

/// Immutable profile annotation over an already-authorized execution catalog model.
/// The result has no executable-target constructor and cannot admit a model or effort.
struct RoutingModelProfileResolver {
    let document: RoutingProfileDocument?

    static let bundled: RoutingModelProfileResolver = {
        guard let document = try? RoutingProfileDocumentDecoder.decode(BundledRoutingProfiles.data)
        else { return .init(document: nil) }
        return .init(document: document)
    }()

    var profileVersion: String {
        document?.profileVersion ?? "rpce.routing-profiles.unavailable"
    }

    var evidenceVersion: String {
        document?.evidenceVersion ?? "rpce.model-routing-evidence.unavailable"
    }

    var rubricVersion: String {
        document?.rubricVersion ?? "rpce.routing-rubric.unavailable"
    }

    var snapshotDate: String {
        guard let date = document?.issuedAt else { return "unknown" }
        return ISO8601DateFormatter().string(from: date).prefix(10).description
    }

    func resolve(
        _ model: RoutingExecutionModelMetadata,
        catalogRevision: String,
        providerFamilyID: String? = nil,
        now: Date = Date()
    ) -> ResolvedRoutingProfile {
        let provider = model.provider.rawValue
        let providerField: (String) -> Provenanced<String> = {
            .init(
                value: $0,
                source: .providerCatalog,
                sourceID: provider,
                version: catalogRevision,
                freshness: .current
            )
        }
        let profileFreshness: RoutingProfileFreshness = document?.expiresAt.map { now > $0 ? .stale : .current } ?? .unknown
        let exact = document?.models.first { $0.providerID == provider && $0.id == model.baseModelRaw }
        let alias = exact == nil ? document?.models.first {
            $0.providerID == provider && $0.aliases.contains(model.baseModelRaw)
        } : nil
        let matched = exact ?? alias
        let family: RoutingProfileDocument.Family?
        let match: ResolvedRoutingProfile.Match
        if let matched {
            if let providerFamilyID, let declared = matched.familyID, providerFamilyID != declared {
                family = nil
                match = .unknown
            } else {
                family = document?.families.first { $0.providerID == provider && $0.id == matched.familyID }
                match = exact == nil ? .exactAlias : .exact
            }
        } else {
            let candidates = document?.families.filter { family in
                guard family.providerID == provider else { return false }
                return family.id == providerFamilyID
                    || family.aliases.contains(model.baseModelRaw)
                    || family.matchers.contains { matcher in
                        Self.matches(model.baseModelRaw, prefix: matcher.prefix)
                    }
            } ?? []
            family = candidates.count == 1 && (providerFamilyID == nil || candidates[0].id == providerFamilyID)
                ? candidates.first : nil
            match = family == nil ? .unknown : .family
        }
        let selectedExact = match == .exact || match == .exactAlias ? matched : nil
        func profileField(_ exactValue: String?, _ familyValue: String?, fallback: String) -> Provenanced<String> {
            if selectedExact != nil, let exactValue {
                return .init(
                    value: exactValue,
                    source: .exactProfile,
                    sourceID: "\(provider):\(selectedExact!.id)",
                    version: profileVersion,
                    freshness: profileFreshness,
                    checkedAt: document?.issuedAt
                )
            }
            if let family, let familyValue {
                return .init(
                    value: familyValue,
                    source: .familyProfile,
                    sourceID: "\(provider):\(family.id)",
                    version: profileVersion,
                    freshness: profileFreshness,
                    checkedAt: document?.issuedAt
                )
            }
            return .init(
                value: fallback,
                source: .genericFallback,
                sourceID: nil,
                version: "rpce.generic-routing.v1",
                freshness: .unknown
            )
        }
        let genericSummary = "No audited benchmark or pricing profile is available for this exact model identity. Treat capability and cost as uncertain; do not infer strength or price from its name."
        let genericRubric = "Use provider-advertised identity and stated capabilities only. Capability and cost not audited; do not infer them from the model name."
        let tier = if let exactTier = selectedExact?.utilityTier {
            Provenanced(
                value: exactTier,
                source: .exactProfile,
                sourceID: "\(provider):\(selectedExact!.id)",
                version: profileVersion,
                freshness: profileFreshness,
                checkedAt: document?.issuedAt
            )
        } else if let family, let familyTier = family.utilityTier {
            Provenanced(
                value: familyTier,
                source: .familyProfile,
                sourceID: "\(provider):\(family.id)",
                version: profileVersion,
                freshness: profileFreshness,
                checkedAt: document?.issuedAt
            )
        } else {
            providerField(model.baseModelRaw)
        }
        let price: Provenanced<String?> = if let selectedExact, let dated = selectedExact.price {
            .init(
                value: dated.text,
                source: .exactProfile,
                sourceID: "\(provider):\(selectedExact.id)",
                version: evidenceVersion,
                freshness: Self.freshness(expiresAt: dated.expiresAt, document: document, now: now),
                checkedAt: dated.checkedAt
            )
        } else {
            .init(
                value: nil,
                source: .genericFallback,
                sourceID: nil,
                version: "rpce.generic-routing.v1",
                freshness: .unknown
            )
        }
        let records = selectedExact?.evidenceIDs.compactMap { id in document?.evidence.first { $0.id == id } } ?? []
        let evidence: Provenanced<[String]> = if let selectedExact, !records.isEmpty {
            .init(
                value: records.map(\.text),
                source: .exactProfile,
                sourceID: "\(provider):\(selectedExact.id)",
                version: evidenceVersion,
                freshness: records.contains { Self.freshness(expiresAt: $0.expiresAt, document: document, now: now) == .stale } ? .stale : profileFreshness,
                checkedAt: records.map(\.checkedAt).min()
            )
        } else {
            .init(
                value: [],
                source: .genericFallback,
                sourceID: nil,
                version: "rpce.generic-routing.v1",
                freshness: .unknown
            )
        }
        return .init(
            match: match,
            familyID: .init(
                value: family?.id,
                source: family == nil ? .genericFallback : (selectedExact == nil ? .familyProfile : .exactProfile),
                sourceID: family.map { "\(provider):\($0.id)" },
                version: family == nil ? "rpce.generic-routing.v1" : profileVersion,
                freshness: family == nil ? .unknown : profileFreshness,
                checkedAt: family == nil ? nil : document?.issuedAt
            ),
            executionProviderID: providerField(provider),
            modelID: providerField(model.baseModelRaw),
            displayName: providerField(model.displayName),
            advertisedEffortIDs: .init(
                value: model.efforts.map(\.id.rawValue),
                source: .providerCatalog,
                sourceID: provider,
                version: catalogRevision,
                freshness: .current
            ),
            executableEffortIDs: .init(
                value: model.efforts.filter(\.isExecutable).map(\.id.rawValue),
                source: .providerCatalog,
                sourceID: provider,
                version: catalogRevision,
                freshness: .current
            ),
            defaultEffortID: .init(
                value: model.defaultEffortID?.rawValue,
                source: .providerCatalog,
                sourceID: provider,
                version: catalogRevision,
                freshness: .current
            ),
            utilityTier: tier,
            summary: profileField(selectedExact?.summary, family?.summary, fallback: genericSummary),
            rubric: profileField(selectedExact?.rubric, family?.rubric, fallback: genericRubric),
            price: price,
            evidence: evidence
        )
    }

    func effortDescription(raw: String?, now: Date = Date()) -> Provenanced<String> {
        guard let raw else {
            return .init(
                value: "Effort is provider-default or unspecified, so total task cost and quality are less predictable.",
                source: .genericFallback,
                sourceID: nil,
                version: "rpce.generic-effort.v1",
                freshness: .unknown
            )
        }
        if let effort = document?.efforts.first(where: { $0.id == raw || $0.aliases.contains(raw) }) {
            return .init(
                value: effort.description.replacingOccurrences(of: "{effort}", with: raw),
                source: .exactProfile,
                sourceID: "effort:\(effort.id)",
                version: profileVersion,
                freshness: Self.freshness(expiresAt: document?.expiresAt, document: document, now: now),
                checkedAt: document?.issuedAt
            )
        }
        return .init(
            value: "Provider-advertised effort \(raw); relative cost and quality behavior is not yet profiled.",
            source: .genericFallback,
            sourceID: nil,
            version: "rpce.generic-effort.v1",
            freshness: .unknown
        )
    }

    private static func matches(_ modelID: String, prefix: String) -> Bool {
        guard modelID.hasPrefix(prefix) else { return false }
        let suffix = modelID.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.first?.isNumber == true else { return false }
        let pieces = suffix.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "." })
        return !pieces.isEmpty && pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            && !suffix.hasSuffix("-") && !suffix.hasSuffix(".")
    }

    private static func freshness(expiresAt: Date?, document: RoutingProfileDocument?, now: Date) -> RoutingProfileFreshness {
        let dates = [expiresAt, document?.expiresAt].compactMap(\.self)
        guard !dates.isEmpty else { return .unknown }
        return dates.contains(where: { now > $0 }) ? .stale : .current
    }
}
