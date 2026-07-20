//
//  SyntaxManager.swift
//  RepoPrompt
//

import Foundation
import RepoPromptCodeMapCore
import SwiftTreeSitter

/// App-owned syntax highlighting and general parsing adapter.
///
/// CodeMap grammar/query identity and synchronous extraction live in
/// `RepoPromptCodeMapCore`; this type retains only highlighting caches,
/// app diagnostics, and compatibility entry points.
final class SyntaxManager: @unchecked Sendable {
    static let shared = SyntaxManager()

    static let parseLineLimit = CodeMapSyntaxEngine.parseLineLimit
    static let parseUTF16Limit = CodeMapSyntaxEngine.parseUTF16Limit
    static let parseUTF8Limit = CodeMapSyntaxEngine.parseUTF8Limit

    let optimizedQueries: [LanguageType: String] = [
        .swift: swiftQuery,
        .js: javascriptQuery,
        .c_sharp: csharpQuery,
        .python: pythonQuery,
        .c: cQuery,
        .rust: rustQuery,
        .cpp: cppQuery,
        .go: goQuery,
        .java: javaQuery,
        .dart: dartQuery,
        .ts: typeScriptHighlightQuery,
        .tsx: typeScriptHighlightQuery,
        .php: basicPhpQuery,
        .ruby: rubyHighlightQuery
    ]

    private let languageConfigCacheLock = NSLock()
    private var languageConfigs: [LanguageType: LanguageConfiguration] = [:]

    private let highlightQueryCacheLock = NSLock()
    private var highlightQueryResults: [LanguageType: Result<Query, Error>] = [:]

    private enum HighlightQueryLookupStatus {
        case cached
        case compiled
    }

    private struct HighlightQueryLookupResult {
        let query: Query
        let status: HighlightQueryLookupStatus
    }

    init() {
        let pipelineStats = CodeMapPerfRuntime.sharedPipelineStats
        let collectStartupPerf = pipelineStats != nil
        var startupStats = CodeMapSyntaxStartupPerfStats()
        let primeStart = collectStartupPerf ? CodeMapPerfRuntime.currentTime() : nil

        warmCache(startupStats: &startupStats, collectPerf: collectStartupPerf)

        if let primeStart {
            startupStats.primeDuration += CodeMapPerfRuntime.durationSince(primeStart)
            pipelineStats?.mergeSyntaxManagerStartupStats(startupStats)
        }
    }

    var extensionToLanguage: [String: LanguageType] {
        CodeMapSyntaxEngine.extensionToLanguage
    }

    func parsingOversizeReason(for content: String) -> CodeMapSyntaxOversizeReason? {
        CodeMapSyntaxEngine.shared.oversizeReason(for: content)
    }

    private func warmCache(startupStats: inout CodeMapSyntaxStartupPerfStats, collectPerf: Bool) {
        let warmCacheStart = collectPerf ? CodeMapPerfRuntime.currentTime() : nil
        defer {
            if let warmCacheStart {
                startupStats.warmCacheDuration += CodeMapPerfRuntime.durationSince(warmCacheStart)
            }
        }

        languageConfigCacheLock.withLock {
            for languageType in optimizedQueries.keys.sorted() {
                if collectPerf { startupStats.warmCacheLanguageCount += 1 }
                if languageConfigs[languageType] == nil,
                   let config = createLanguageConfig(
                       for: languageType,
                       startupStats: &startupStats,
                       collectPerf: collectPerf
                   )
                {
                    languageConfigs[languageType] = config
                }
            }
        }
    }

    func languageConfig(forFileExtension fileExtension: String) -> LanguageConfiguration? {
        guard let language = language(forFileExtension: fileExtension) else { return nil }
        return languageConfig(for: language)
    }

    private func languageConfig(for language: LanguageType) -> LanguageConfiguration? {
        languageConfigCacheLock.withLock {
            if let config = languageConfigs[language] { return config }
            if let newConfig = createLanguageConfig(for: language) {
                languageConfigs[language] = newConfig
                return newConfig
            }
            return nil
        }
    }

    func language(forFileExtension fileExtension: String) -> LanguageType? {
        CodeMapSyntaxEngine.shared.language(forFileExtension: fileExtension)
    }

    func codeMapPipelineDescriptor(for languageType: LanguageType) throws -> CodeMapLanguagePipelineDescriptor {
        try CodeMapSyntaxEngine.shared.codeMapPipelineDescriptor(for: languageType)
    }

    func pipelineIdentity(
        for languageType: LanguageType,
        decoderPolicy: CodeMapSourceDecoderPolicy
    ) throws -> CodeMapPipelineIdentity {
        try CodeMapSyntaxEngine.shared.pipelineIdentity(
            for: languageType,
            decoderPolicy: decoderPolicy
        )
    }

    private func createLanguageConfig(for languageType: LanguageType) -> LanguageConfiguration? {
        var startupStats = CodeMapSyntaxStartupPerfStats()
        return createLanguageConfig(
            for: languageType,
            startupStats: &startupStats,
            collectPerf: false
        )
    }

    private func createLanguageConfig(
        for languageType: LanguageType,
        startupStats: inout CodeMapSyntaxStartupPerfStats,
        collectPerf: Bool
    ) -> LanguageConfiguration? {
        if collectPerf { startupStats.languageConfigCreateCount += 1 }
        let createStart = collectPerf ? CodeMapPerfRuntime.currentTime() : nil
        defer {
            if let createStart {
                startupStats.languageConfigCreateDuration += CodeMapPerfRuntime.durationSince(createStart)
            }
        }

        let pointerStart = collectPerf ? CodeMapPerfRuntime.currentTime() : nil
        let descriptor: CodeMapGrammarDescriptor
        do {
            descriptor = try CodeMapSyntaxEngine.shared.grammarDescriptor(for: languageType)
        } catch {
            if collectPerf { startupStats.languageConfigFailureCount += 1 }
            print("No language pointer for \(languageType.displayName): \(error)")
            return nil
        }
        if let pointerStart {
            startupStats.languagePointerDuration += CodeMapPerfRuntime.durationSince(pointerStart)
        }

        if collectPerf { startupStats.languageConfigSuccessCount += 1 }
        return LanguageConfiguration(
            descriptor.language,
            name: descriptor.displayName,
            queries: [:]
        )
    }

    func parse(content: String, fileExtension: String) throws -> MutableTree? {
        guard language(forFileExtension: fileExtension) != nil else { return nil }
        if let reason = parsingOversizeReason(for: content) {
            print("[SyntaxManager] Skipping parse for .\(fileExtension): \(reason)")
            return nil
        }

        guard let config = languageConfig(forFileExtension: fileExtension) else { return nil }
        let parser = Parser()
        try parser.setLanguage(config.language)
        return parser.parse(content)
    }

    func compileHighlightQuery(for languageType: LanguageType) throws {
        guard let queryText = optimizedQueries[languageType],
              let data = queryText.data(using: .utf8)
        else {
            return
        }
        let descriptor = try CodeMapSyntaxEngine.shared.grammarDescriptor(for: languageType)
        _ = try Query(language: descriptor.language, data: data)
    }

    func highlight(content: String, fileExtension: String) throws -> [NamedRange] {
        guard CodeMapSyntaxEngine.exceededLineCount(in: content.utf8, limit: 5000) == nil else {
            return []
        }

        guard let languageType = language(forFileExtension: fileExtension) else { return [] }
        if let reason = parsingOversizeReason(for: content) {
            print("[SyntaxManager] Skipping highlight parse for .\(fileExtension): \(reason)")
            return []
        }

        guard let config = languageConfig(forFileExtension: fileExtension) else { return [] }
        let parser = Parser()
        try parser.setLanguage(config.language)

        guard let tree = parser.parse(content),
              let root = tree.rootNode
        else {
            return []
        }
        guard let highlightLookup = try highlightQuery(
            for: languageType,
            language: config.language
        ) else {
            return []
        }

        let cursor = highlightLookup.query.execute(node: root, in: tree)
        return cursor.highlights()
    }

    private func highlightQuery(
        for languageType: LanguageType,
        language: Language
    ) throws -> HighlightQueryLookupResult? {
        try highlightQueryCacheLock.withLock {
            if let cachedResult = highlightQueryResults[languageType] {
                switch cachedResult {
                case let .success(query):
                    return HighlightQueryLookupResult(query: query, status: .cached)
                case let .failure(error):
                    if languageType == .php || languageType == .ruby {
                        return nil
                    }
                    throw error
                }
            }

            guard let highlightQueryText = optimizedQueries[languageType],
                  let data = highlightQueryText.data(using: .utf8)
            else {
                return nil
            }

            let result = Result {
                try Query(language: language, data: data)
            }
            highlightQueryResults[languageType] = result

            switch result {
            case let .success(query):
                return HighlightQueryLookupResult(query: query, status: .compiled)
            case let .failure(error):
                print("Error creating query for \(languageType.displayName): \(error)")
                if languageType == .php || languageType == .ruby {
                    return nil
                }
                throw error
            }
        }
    }

    func codeMap(content: String, fileExtension: String) throws -> [NamedRange] {
        let pipelineStats = CodeMapPerfRuntime.sharedPipelineStats
        let lookupStart = pipelineStats != nil ? CodeMapPerfRuntime.currentTime() : nil
        guard let language = language(forFileExtension: fileExtension) else {
            if let pipelineStats {
                var syntaxPerf = CodeMapSyntaxPerfStats()
                syntaxPerf.calls = 1
                syntaxPerf.unsupported = 1
                if let lookupStart {
                    syntaxPerf.languageLookupDuration = CodeMapPerfRuntime.durationSince(lookupStart)
                }
                pipelineStats.mergeSyntaxCodeMapStats(syntaxPerf)
            }
            return []
        }

        let operationStart = pipelineStats != nil ? CodeMapPerfRuntime.currentTime() : nil
        let outcome = try CodeMapSyntaxEngine.shared.codeMap(content: content, language: language)
        if let pipelineStats {
            var syntaxPerf = CodeMapSyntaxPerfStats()
            syntaxPerf.calls = 1
            if let lookupStart {
                syntaxPerf.languageLookupDuration = CodeMapPerfRuntime.durationSince(lookupStart)
            }
            if let operationStart {
                syntaxPerf.parseDuration = CodeMapPerfRuntime.durationSince(operationStart)
            }
            switch outcome {
            case let .captures(captures):
                syntaxPerf.captures = captures.count
                syntaxPerf.queryExecutes = 1
            case .oversize:
                syntaxPerf.oversized = 1
            case let .parseFailed(failure):
                switch failure {
                case .parserReturnedNilTree: syntaxPerf.parseNilTree = 1
                case .parserReturnedNilRoot: syntaxPerf.parseNilRoot = 1
                }
            }
            pipelineStats.mergeSyntaxCodeMapStats(syntaxPerf)
        }

        switch outcome {
        case let .captures(captures):
            return captures
        case .oversize, .parseFailed:
            return []
        }
    }

    func codeMap(content: String, language: LanguageType) throws -> CodeMapSyntaxQueryOutcome {
        try CodeMapSyntaxEngine.shared.codeMap(content: content, language: language)
    }

    static func isSupportedFileExtension(_ fileExtension: String) -> Bool {
        CodeMapSyntaxEngine.isSupportedFileExtension(fileExtension)
    }

    static func supportsCodeMap(fileExtension: String) -> Bool {
        CodeMapSyntaxEngine.supportsCodeMap(fileExtension: fileExtension)
    }

    func supportsCodeMap(fileExtension: String) -> Bool {
        Self.supportsCodeMap(fileExtension: fileExtension)
    }

    static func isLightweight(language: LanguageType) -> Bool {
        CodeMapSyntaxEngine.isLightweight(language: language)
    }
}
