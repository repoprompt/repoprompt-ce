import Foundation

enum ModelPickerStringOrdering {
    static func compare(
        _ lhs: String,
        _ rhs: String,
        caseInsensitiveASCII: Bool
    ) -> ComparisonResult {
        let foldedComparison = compareScalars(
            lhs.unicodeScalars.map { foldedScalarValue($0.value, caseInsensitiveASCII: caseInsensitiveASCII) },
            rhs.unicodeScalars.map { foldedScalarValue($0.value, caseInsensitiveASCII: caseInsensitiveASCII) }
        )
        if foldedComparison != .orderedSame || !caseInsensitiveASCII {
            return foldedComparison
        }

        return compareScalars(
            lhs.unicodeScalars.map(\.value),
            rhs.unicodeScalars.map(\.value)
        )
    }

    static func precedes(
        _ lhs: String,
        _ rhs: String,
        caseInsensitiveASCII: Bool = true
    ) -> Bool {
        compare(lhs, rhs, caseInsensitiveASCII: caseInsensitiveASCII) == .orderedAscending
    }

    private static func foldedScalarValue(
        _ value: UInt32,
        caseInsensitiveASCII: Bool
    ) -> UInt32 {
        guard caseInsensitiveASCII, value >= 65, value <= 90 else { return value }
        return value + 32
    }

    private static func compareScalars(
        _ lhs: [UInt32],
        _ rhs: [UInt32]
    ) -> ComparisonResult {
        let count = min(lhs.count, rhs.count)
        for index in 0 ..< count {
            if lhs[index] == rhs[index] { continue }
            return lhs[index] < rhs[index] ? .orderedAscending : .orderedDescending
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }
}

/// Shared string-only model ordering and labels. No provider construction or persisted lookup.
enum ModelCatalogSemantics {
    struct Metadata {
        let family: String
        let versionComponents: [Int]
        let suffix: String
        let reasoningEffort: CodexReasoningEffort?
        let displayName: String
        let tieBreaker: String

        init(family: String, versionComponents: [Int], suffix: String, reasoningEffort: CodexReasoningEffort?, displayName: String, tieBreaker: String) {
            self.family = family
            self.versionComponents = versionComponents
            self.suffix = suffix
            self.reasoningEffort = reasoningEffort
            self.displayName = displayName
            self.tieBreaker = tieBreaker
        }
    }

    static func codexBaseModelPrecedes(_ lhs: String, _ rhs: String, catalogRecords: () -> [CodexDynamicModelRecord]) -> Bool {
        let leftMetadata = metadata(identifier: lhs, fallbackDisplayName: lhs, reasoningEffort: nil, catalogRecords: catalogRecords)
        let rightMetadata = metadata(identifier: rhs, fallbackDisplayName: rhs, reasoningEffort: nil, catalogRecords: catalogRecords)
        return precedes(leftMetadata, rightMetadata)
    }

    static func codexPreviewDisplayAlias(for raw: String, catalogRecords: () -> [CodexDynamicModelRecord]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let specifier = CodexModelSpecifier(raw: trimmed, catalogRecords: catalogRecords)
        let base = specifier.baseModel ?? trimmed
        let normalizedBase = normalizedSemanticText(base)
        let canonicalBase: String
        switch normalizedBase {
        case "gpt-5.6", "gpt-5.6-sol":
            canonicalBase = "GPT-5.6 Sol"
        case "gpt-5.6-terra":
            canonicalBase = "GPT-5.6 Terra"
        case "gpt-5.6-luna":
            canonicalBase = "GPT-5.6 Luna"
        case "gpt-5.5":
            canonicalBase = "GPT-5.5"
        default:
            return nil
        }

        var label = canonicalBase
        if let serviceTier = specifier.serviceTier {
            label += serviceTier == CodexServiceTierVariantCatalog.fastServiceTier ? " Fast" : " \(serviceTier.capitalized)"
        }
        if let reasoningEffort = specifier.reasoningEffort {
            label += " \(reasoningEffort.displayName)"
        }
        return label
    }

    static func stripCodexReasoningSuffix(from label: String, catalogRecords: () -> [CodexDynamicModelRecord]) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let specifier = codexSpecifierFromSemanticLabel(trimmed, catalogRecords: catalogRecords)
        guard specifier.reasoningEffort != nil, let baseModel = specifier.baseModel else {
            return trimmed
        }

        var stripped = humanizedCodexBaseModel(baseModel, catalogRecords: catalogRecords)
        if let serviceTier = specifier.serviceTier {
            stripped += serviceTier == CodexServiceTierVariantCatalog.fastServiceTier
                ? " Fast"
                : " \(serviceTier.capitalized)"
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func precedes(_ lhs: Metadata, _ rhs: Metadata) -> Bool {
        let familyComparison = ModelPickerStringOrdering.compare(lhs.family, rhs.family, caseInsensitiveASCII: true)
        if familyComparison != .orderedSame {
            return familyComparison == .orderedAscending
        }

        let versionComparison = compareVersionComponents(lhs.versionComponents, rhs.versionComponents)
        if versionComparison != .orderedSame {
            return versionComparison == .orderedDescending
        }

        let leftReasoningRank = reasoningSortRank(lhs.reasoningEffort)
        let rightReasoningRank = reasoningSortRank(rhs.reasoningEffort)
        if leftReasoningRank != rightReasoningRank {
            return leftReasoningRank < rightReasoningRank
        }

        let suffixComparison = ModelPickerStringOrdering.compare(lhs.suffix, rhs.suffix, caseInsensitiveASCII: true)
        if suffixComparison != .orderedSame {
            return suffixComparison == .orderedAscending
        }

        let displayComparison = ModelPickerStringOrdering.compare(lhs.displayName, rhs.displayName, caseInsensitiveASCII: true)
        if displayComparison != .orderedSame {
            return displayComparison == .orderedAscending
        }

        return ModelPickerStringOrdering.precedes(lhs.tieBreaker, rhs.tieBreaker)
    }

    static func metadata(
        identifier: String,
        fallbackDisplayName: String,
        reasoningEffort: CodexReasoningEffort?,
        catalogRecords: () -> [CodexDynamicModelRecord]
    ) -> Metadata {
        let semanticSource = codexPreviewDisplayAlias(for: identifier, catalogRecords: catalogRecords) ?? (identifier.isEmpty ? fallbackDisplayName : identifier)
        let normalizedIdentifier = normalizedSemanticText(semanticSource)
        let family = semanticFamily(in: normalizedIdentifier)
        let versionComponents = semanticVersionComponents(in: normalizedIdentifier)
        let suffix = semanticSuffix(in: normalizedIdentifier)

        return Metadata(
            family: family,
            versionComponents: versionComponents,
            suffix: suffix,
            reasoningEffort: reasoningEffort,
            displayName: fallbackDisplayName,
            tieBreaker: identifier
        )
    }

    private static func compareVersionComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        guard !lhs.isEmpty || !rhs.isEmpty else { return .orderedSame }

        let maxCount = max(lhs.count, rhs.count)
        for index in 0 ..< maxCount {
            let leftValue = index < lhs.count ? lhs[index] : -1
            let rightValue = index < rhs.count ? rhs[index] : -1
            if leftValue == rightValue { continue }
            return leftValue < rightValue ? .orderedAscending : .orderedDescending
        }

        return .orderedSame
    }

    static func reasoningSortRank(_ effort: CodexReasoningEffort?) -> Int {
        guard let effort else { return -1 }
        return CodexReasoningEffort.displayOrder.firstIndex(of: effort) ?? Int.max
    }

    static func reasoningEffort(in text: String, catalogRecords: () -> [CodexDynamicModelRecord]) -> CodexReasoningEffort? {
        codexSpecifierFromSemanticLabel(text, catalogRecords: catalogRecords).reasoningEffort
    }

    private static func codexSpecifierFromSemanticLabel(_ text: String, catalogRecords: () -> [CodexDynamicModelRecord]) -> CodexModelSpecifier {
        let parseableText = text
            .replacingOccurrences(of: "CLI·", with: "")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
        let normalized = normalizedSemanticText(parseableText)
        let candidates = codexSpecifierCandidates(fromNormalizedSemanticText: normalized)
        for candidate in candidates {
            let specifier = CodexModelSpecifier(raw: candidate, catalogRecords: catalogRecords)
            if specifier.reasoningEffort != nil {
                return specifier
            }
        }
        return CodexModelSpecifier(raw: normalized, catalogRecords: catalogRecords)
    }

    private static func codexSpecifierCandidates(fromNormalizedSemanticText normalized: String) -> [String] {
        guard !normalized.isEmpty else { return [normalized] }

        var candidates: [String] = []
        func appendAlias(suffix: String, replacement: String) {
            guard normalized.hasSuffix(suffix) else { return }
            let base = String(normalized.dropLast(suffix.count))
            guard !base.isEmpty else { return }
            candidates.append("\(base)\(replacement)")
        }

        appendAlias(suffix: "-x-high", replacement: "-xhigh")
        appendAlias(suffix: "-med", replacement: "-medium")
        candidates.append(normalized)
        return candidates
    }

    static func normalizedCodexBaseLabel(_ label: String, catalogRecords: () -> [CodexDynamicModelRecord]) -> String {
        let withoutPrefix = label
            .replacingOccurrences(of: "CLI·", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripCodexReasoningSuffix(from: withoutPrefix, catalogRecords: catalogRecords)
    }

    static func humanizedCodexBaseModel(_ raw: String, catalogRecords: () -> [CodexDynamicModelRecord]) -> String {
        if let alias = codexPreviewDisplayAlias(for: raw, catalogRecords: catalogRecords) {
            return alias
        }

        let tokens = raw.split { character in
            character == "_" || character == "-" || character == "/" || character.isWhitespace
        }
        guard !tokens.isEmpty else { return raw }

        var formatted: [String] = []
        formatted.reserveCapacity(tokens.count)
        for token in tokens {
            let value = String(token)
            let formattedToken = formatCodexLabelToken(value)
            if isVersionToken(value), formatted.last == "GPT" {
                formatted[formatted.count - 1] = "GPT-\(formattedToken)"
            } else {
                formatted.append(formattedToken)
            }
        }
        return formatted.joined(separator: " ")
    }

    private static func formatCodexLabelToken(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "gpt" { return "GPT" }
        if lower == "codex" { return "Codex" }
        if lower == "xhigh" { return "XHigh" }
        if isVersionToken(value) { return value }
        return lower.capitalized
    }

    private static func isVersionToken(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }

    private static func normalizedSemanticText(_ text: String) -> String {
        var output = ""
        var previousWasSeparator = false
        for character in text.lowercased() {
            if character == "·" || character == "_" || character.isWhitespace {
                if !previousWasSeparator {
                    output.append("-")
                    previousWasSeparator = true
                }
            } else {
                output.append(character)
                previousWasSeparator = false
            }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "- /"))
    }

    private static func semanticFamily(in text: String) -> String {
        guard let firstNumberIndex = text.firstIndex(where: { $0.isNumber }) else {
            return text
        }

        let prefix = text[..<firstNumberIndex]
            .trimmingCharacters(in: CharacterSet(charactersIn: "- /"))
        return prefix.isEmpty ? text : String(prefix)
    }

    private static func semanticVersionComponents(in text: String) -> [Int] {
        guard let firstNumberIndex = text.firstIndex(where: { $0.isNumber }) else {
            return []
        }

        var cursor = firstNumberIndex
        var versionString = ""
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isNumber || character == "." {
                versionString.append(character)
                cursor = text.index(after: cursor)
                continue
            }
            break
        }

        return versionString
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    private static func semanticSuffix(in text: String) -> String {
        guard let firstNumberIndex = text.firstIndex(where: { $0.isNumber }) else {
            return text
        }

        var cursor = firstNumberIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isNumber || character == "." {
                cursor = text.index(after: cursor)
                continue
            }
            break
        }

        return text[cursor...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "- /"))
    }
}
