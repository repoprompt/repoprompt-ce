//
//  ReferencedTypesAccumulator.swift
//  RepoPrompt
//
//  Centralized referenced type collection and cleaning.
//

import Foundation

struct ReferencedTypesAccumulator {
    let language: LanguageType
    private(set) var types: Set<String> = []
    private var cache: [TypeCleaner.TypeCleanerCacheKey: [String]] = [:]
    private var rawInsertCount = 0
    private let stats: CodeMapPerformanceCollector?
    private let perfOptions: CodeMapPerfOptions

    init(language: LanguageType, stats: CodeMapPerformanceCollector? = nil, perfOptions: CodeMapPerfOptions = .disabled) {
        self.language = language
        self.stats = stats
        self.perfOptions = perfOptions
    }

    mutating func insert(rawType: String?) {
        guard let raw = rawType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return }
        let activePerfOptions = perfOptions
        let activeStats = stats
        let perfEnabled = activePerfOptions.enabled
        let perfCollectCounters = activePerfOptions.collectCounters
        rawInsertCount += 1
        if perfCollectCounters {
            activeStats?.referencedTypesRawInsertions += 1
        }
        if Self.shouldSkipTypeCleaner(raw: raw, language: language) {
            if perfCollectCounters {
                activeStats?.referencedTypesPrefilterSkips += 1
                activeStats?.referencedTypesEmptyResults += 1
            }
            return
        }
        let start = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let extracted = TypeCleaner.extractBaseTypes(from: raw, language: language, cache: &cache, stats: activeStats)
        if perfEnabled {
            activeStats?.typeCleanerDuration += (CFAbsoluteTimeGetCurrent() - start)
        }
        if perfCollectCounters {
            if extracted.isEmpty {
                activeStats?.referencedTypesEmptyResults += 1
            } else {
                activeStats?.referencedTypesOutputTypeCount += extracted.count
            }
        }
        for typeName in extracted {
            let cleaned = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                types.insert(cleaned)
            }
        }
    }

    private static func shouldSkipTypeCleaner(raw: String, language: LanguageType) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if isDirectTSLiteral(trimmed, language: language) {
            return true
        }

        let lower = trimmed.lowercased()
        if ["untyped", "varargs", "enum", "union"].contains(trimmed) {
            return true
        }

        if language == .swift, ["()", "void", "never", "any"].contains(lower) {
            return true
        }

        if hasComplexTypeSyntax(trimmed) || containsInternalWhitespace(trimmed) {
            return false
        }

        if TypeCleaner.isPrimitiveType(trimmed, language: language) {
            return true
        }
        if TypeCleaner.isContainerType(trimmed, language: language) {
            return true
        }
        if TypeCleaner.isGenericPlaceholderTypeName(trimmed, language: language) {
            return true
        }
        if language == .swift, TypeCleaner.isSwiftSpecialTypeName(trimmed) {
            return true
        }
        return false
    }

    private static func hasComplexTypeSyntax(_ raw: String) -> Bool {
        if raw.contains("->") || raw.contains("=>") {
            return true
        }
        return raw.contains { character in
            "<>()[]{}|&:=,?*.".contains(character)
        }
    }

    private static func containsInternalWhitespace(_ raw: String) -> Bool {
        raw.contains { $0.isWhitespace }
    }

    private static func isDirectTSLiteral(_ raw: String, language: LanguageType) -> Bool {
        guard language == .ts || language == .tsx else { return false }
        if raw == "true" || raw == "false" {
            return true
        }
        if isQuotedLiteral(raw) {
            return true
        }
        if raw.hasSuffix("n"), Int(raw.dropLast()) != nil {
            return true
        }
        return Double(raw) != nil
    }

    private static func isQuotedLiteral(_ raw: String) -> Bool {
        guard raw.count >= 2 else { return false }
        if raw.hasPrefix("`") && raw.hasSuffix("`") {
            return !raw.contains("${")
        }
        return (raw.hasPrefix("\"") && raw.hasSuffix("\""))
            || (raw.hasPrefix("'") && raw.hasSuffix("'"))
    }

    mutating func insertMany(rawTypes: [String]) {
        for rawType in rawTypes {
            insert(rawType: rawType)
        }
    }

    func finalizeSorted() -> [String] {
        Array(types).sorted()
    }

    var rawInsertions: Int {
        rawInsertCount
    }
}
