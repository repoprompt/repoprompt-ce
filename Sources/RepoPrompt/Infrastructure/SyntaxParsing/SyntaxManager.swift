//
//  SyntaxManager.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-05.
//

import CryptoKit
import Foundation
import SwiftTreeSitter
import TreeSitterC
import TreeSitterDart
import TreeSitterGo
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterTSX
import TreeSitterTypeScript

enum LanguageType: String, CaseIterable, Comparable, Codable {
    case swift, js, c_sharp, python, c, rust, cpp, go, java, dart, ts, tsx,
         php, ruby // ➜ NEW

    var displayName: String {
        switch self {
        case .swift: "Swift"
        case .js: "JavaScript"
        case .c_sharp: "C#"
        case .python: "Python"
        case .c: "C"
        case .rust: "Rust"
        case .cpp: "C++"
        case .go: "Go"
        case .java: "Java"
        case .dart: "Dart"
        case .ts: "TypeScript"
        case .tsx: "TSX"
        case .php: "PHP" // NEW
        case .ruby: "Ruby"
        }
    }

    // MARK: - Comparable

    static func < (lhs: LanguageType, rhs: LanguageType) -> Bool {
        lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
        // If you’d rather sort by declaration order instead, use:
        // lhs.rawValue < rhs.rawValue
    }
}

enum CodeMapSyntaxQueryOutcome {
    case captures([NamedRange])
    case oversize(CodeMapSyntaxOversizeReason)
    case parseFailed(CodeMapSyntaxParseFailure)
}

struct CodeMapLanguagePipelineDescriptor: Hashable {
    let stableLanguageID: CodeMapPipelineLanguageID
    let grammarRevision: String
    let treeSitterABIVersion: UInt32
    let queryBytes: Data
}

protocol CodeMapSyntaxQuerying {
    func codeMap(content: String, language: LanguageType) throws -> CodeMapSyntaxQueryOutcome
}

final class SyntaxManager: CodeMapSyntaxQuerying {
    static let shared = SyntaxManager()

    private enum CodeMapQueryLookupStatus {
        // Static-slot retrieval is reported as a hit even when Swift performs the slot's first lazy initialization.
        case precomputedHit
        case fallbackCompile
    }

    private struct CodeMapQueryLookupResult {
        let query: Query
        let status: CodeMapQueryLookupStatus
    }

    private enum HighlightQueryLookupStatus {
        case cached
        case compiled
    }

    private struct HighlightQueryLookupResult {
        let query: Query
        let status: HighlightQueryLookupStatus
    }

    private struct RegisteredCodeMapLanguageDescriptor {
        let languageType: LanguageType
        let stableLanguageID: CodeMapPipelineLanguageID
        let displayName: String
        let language: Language
        let grammarRevision: String
        let queryBytes: Data
    }

    private struct CodeMapLanguageRecipe {
        let stableLanguageID: CodeMapPipelineLanguageID
        let displayName: String
        let makeLanguage: () -> Language?
        let grammarRevision: String
        let queryText: String
    }

    private enum RegisteredCodeMapLanguageStore {
        static func recipe(for languageType: LanguageType) -> CodeMapLanguageRecipe {
            switch languageType {
            case .swift:
                CodeMapLanguageRecipe(
                    stableLanguageID: .swift,
                    displayName: "Swift",
                    makeLanguage: { tree_sitter_swift().map(Language.init(language:)) },
                    grammarRevision: "9253825dd2570430b53fa128cbb40cb62498e75d",
                    queryText: swiftCodeMapQuery
                )
            case .js:
                CodeMapLanguageRecipe(
                    stableLanguageID: .javascript,
                    displayName: "JavaScript",
                    makeLanguage: { tree_sitter_javascript().map(Language.init(language:)) },
                    grammarRevision: "39798e26b6d4dbcee8e522b8db83f8b2df33a5ea",
                    queryText: javascriptCodeMapQuery
                )
            case .c_sharp:
                CodeMapLanguageRecipe(
                    stableLanguageID: .cSharp,
                    displayName: "C#",
                    makeLanguage: { tree_sitter_c_sharp().map(Language.init(language:)) },
                    grammarRevision: "b27b091bfdc5f16d0ef76421ea5609c82a57dff0",
                    queryText: csharpCodeMapQuery
                )
            case .python:
                CodeMapLanguageRecipe(
                    stableLanguageID: .python,
                    displayName: "Python",
                    makeLanguage: { tree_sitter_python().map(Language.init(language:)) },
                    grammarRevision: "c5fca1a186e8e528115196178c28eefa8d86b0b0",
                    queryText: pythonCodeMapQuery
                )
            case .c:
                CodeMapLanguageRecipe(
                    stableLanguageID: .c,
                    displayName: "C",
                    makeLanguage: { tree_sitter_c().map(Language.init(language:)) },
                    grammarRevision: "3efee11f784605d44623d7dadd6cd12a0f73ea92",
                    queryText: cCodeMapQuery
                )
            case .rust:
                CodeMapLanguageRecipe(
                    stableLanguageID: .rust,
                    displayName: "Rust",
                    makeLanguage: { tree_sitter_rust().map(Language.init(language:)) },
                    grammarRevision: "2eaf126458a4d6a69401089b6ba78c5e5d6c1ced",
                    queryText: rustCodeMapQuery
                )
            case .cpp:
                CodeMapLanguageRecipe(
                    stableLanguageID: .cpp,
                    displayName: "C++",
                    makeLanguage: { tree_sitter_cpp().map(Language.init(language:)) },
                    grammarRevision: "e5cea0ec884c5c3d2d1e41a741a66ce13da4d945",
                    queryText: cppCodeMapQuery
                )
            case .go:
                CodeMapLanguageRecipe(
                    stableLanguageID: .go,
                    displayName: "Go",
                    makeLanguage: { tree_sitter_go().map(Language.init(language:)) },
                    grammarRevision: "c350fa54d38af725c40d061a602ee3205ef1e072",
                    queryText: goCodeMapQuery
                )
            case .java:
                CodeMapLanguageRecipe(
                    stableLanguageID: .java,
                    displayName: "Java",
                    makeLanguage: { tree_sitter_java().map(Language.init(language:)) },
                    grammarRevision: "e10607b45ff745f5f876bfa3e94fbcc6b44bdc11",
                    queryText: javaCodeMapQuery
                )
            case .dart:
                CodeMapLanguageRecipe(
                    stableLanguageID: .dart,
                    displayName: "Dart",
                    makeLanguage: { tree_sitter_dart().map(Language.init(language:)) },
                    grammarRevision: "80e23c07b64494f7e21090bb3450223ef0b192f4",
                    queryText: dartCodeMapQuery
                )
            case .ts:
                CodeMapLanguageRecipe(
                    stableLanguageID: .typescript,
                    displayName: "TypeScript",
                    makeLanguage: { tree_sitter_typescript().map(Language.init(language:)) },
                    grammarRevision: "75b3874edb2dc714fb1fd77a32013d0f8699989f",
                    queryText: typeScriptCodeMapQuery
                )
            case .tsx:
                CodeMapLanguageRecipe(
                    stableLanguageID: .tsx,
                    displayName: "TSX",
                    makeLanguage: { tree_sitter_tsx().map(Language.init(language:)) },
                    grammarRevision: "75b3874edb2dc714fb1fd77a32013d0f8699989f",
                    queryText: typeScriptCodeMapQuery
                )
            case .php:
                CodeMapLanguageRecipe(
                    stableLanguageID: .php,
                    displayName: "PHP",
                    makeLanguage: { tree_sitter_php().map(Language.init(language:)) },
                    grammarRevision: "0a99deca13c4af1fb9adcb03c958bfc9f4c740a9",
                    queryText: phpCodeMapQuery
                )
            case .ruby:
                CodeMapLanguageRecipe(
                    stableLanguageID: .ruby,
                    displayName: "Ruby",
                    makeLanguage: { tree_sitter_ruby().map(Language.init(language:)) },
                    grammarRevision: "7a010836b74351855148818d5cb8170dc4df8e6a",
                    queryText: rubyCodeMapQuery
                )
            }
        }

        static func lookup(for languageType: LanguageType) throws -> RegisteredCodeMapLanguageDescriptor {
            switch languageType {
            case .swift: try SwiftDescriptor.result.get()
            case .js: try JavaScriptDescriptor.result.get()
            case .c_sharp: try CSharpDescriptor.result.get()
            case .python: try PythonDescriptor.result.get()
            case .c: try CDescriptor.result.get()
            case .rust: try RustDescriptor.result.get()
            case .cpp: try CppDescriptor.result.get()
            case .go: try GoDescriptor.result.get()
            case .java: try JavaDescriptor.result.get()
            case .dart: try DartDescriptor.result.get()
            case .ts: try TypeScriptDescriptor.result.get()
            case .tsx: try TSXDescriptor.result.get()
            case .php: try PHPDescriptor.result.get()
            case .ruby: try RubyDescriptor.result.get()
            }
        }

        private enum SwiftDescriptor { static let result = make(languageType: .swift) }
        private enum JavaScriptDescriptor { static let result = make(languageType: .js) }
        private enum CSharpDescriptor { static let result = make(languageType: .c_sharp) }
        private enum PythonDescriptor { static let result = make(languageType: .python) }
        private enum CDescriptor { static let result = make(languageType: .c) }
        private enum RustDescriptor { static let result = make(languageType: .rust) }
        private enum CppDescriptor { static let result = make(languageType: .cpp) }
        private enum GoDescriptor { static let result = make(languageType: .go) }
        private enum JavaDescriptor { static let result = make(languageType: .java) }
        private enum DartDescriptor { static let result = make(languageType: .dart) }
        private enum TypeScriptDescriptor { static let result = make(languageType: .ts) }
        private enum TSXDescriptor { static let result = make(languageType: .tsx) }
        private enum PHPDescriptor { static let result = make(languageType: .php) }
        private enum RubyDescriptor { static let result = make(languageType: .ruby) }

        private static func make(
            languageType: LanguageType
        ) -> Result<RegisteredCodeMapLanguageDescriptor, Error> {
            Result {
                let recipe = recipe(for: languageType)
                guard let language = recipe.makeLanguage() else {
                    throw SyntaxManager.missingCodeMapQueryError(for: languageType)
                }
                return RegisteredCodeMapLanguageDescriptor(
                    languageType: languageType,
                    stableLanguageID: recipe.stableLanguageID,
                    displayName: recipe.displayName,
                    language: language,
                    grammarRevision: recipe.grammarRevision,
                    queryBytes: Data(recipe.queryText.utf8)
                )
            }
        }
    }

    private enum LazyCodeMapQueryStore {
        static func lookup(for languageType: LanguageType) throws -> CodeMapQueryLookupResult {
            switch languageType {
            case .swift:
                try CodeMapQueryLookupResult(query: SwiftQuery.result.get(), status: .precomputedHit)
            case .js:
                try CodeMapQueryLookupResult(query: JavaScriptQuery.result.get(), status: .precomputedHit)
            case .c_sharp:
                try CodeMapQueryLookupResult(query: CSharpQuery.result.get(), status: .precomputedHit)
            case .python:
                try CodeMapQueryLookupResult(query: PythonQuery.result.get(), status: .precomputedHit)
            case .c:
                try CodeMapQueryLookupResult(query: CQuery.result.get(), status: .precomputedHit)
            case .rust:
                try CodeMapQueryLookupResult(query: RustQuery.result.get(), status: .precomputedHit)
            case .cpp:
                try CodeMapQueryLookupResult(query: CppQuery.result.get(), status: .precomputedHit)
            case .go:
                try CodeMapQueryLookupResult(query: GoQuery.result.get(), status: .precomputedHit)
            case .java:
                try CodeMapQueryLookupResult(query: JavaQuery.result.get(), status: .precomputedHit)
            case .dart:
                try CodeMapQueryLookupResult(query: DartQuery.result.get(), status: .precomputedHit)
            case .ts:
                try CodeMapQueryLookupResult(query: TypeScriptQuery.result.get(), status: .precomputedHit)
            case .tsx:
                try CodeMapQueryLookupResult(query: TSXQuery.result.get(), status: .precomputedHit)
            case .php:
                try CodeMapQueryLookupResult(query: PHPQuery.result.get(), status: .precomputedHit)
            case .ruby:
                try CodeMapQueryLookupResult(query: RubyQuery.result.get(), status: .precomputedHit)
            }
        }

        private enum SwiftQuery { static let result = make(languageType: .swift) }
        private enum JavaScriptQuery { static let result = make(languageType: .js) }
        private enum CSharpQuery { static let result = make(languageType: .c_sharp) }
        private enum PythonQuery { static let result = make(languageType: .python) }
        private enum CQuery { static let result = make(languageType: .c) }
        private enum RustQuery { static let result = make(languageType: .rust) }
        private enum CppQuery { static let result = make(languageType: .cpp) }
        private enum GoQuery { static let result = make(languageType: .go) }
        private enum JavaQuery { static let result = make(languageType: .java) }
        private enum DartQuery { static let result = make(languageType: .dart) }
        private enum TypeScriptQuery { static let result = make(languageType: .ts) }
        private enum TSXQuery { static let result = make(languageType: .tsx) }
        private enum PHPQuery { static let result = make(languageType: .php) }
        private enum RubyQuery { static let result = make(languageType: .ruby) }

        private static func make(languageType: LanguageType) -> Result<Query, Error> {
            Result {
                let descriptor = try RegisteredCodeMapLanguageStore.lookup(for: languageType)
                return try Query(language: descriptor.language, data: descriptor.queryBytes)
            }
        }
    }

    // Large-file safety thresholds (tuned to avoid common real-world files).
    static let parseLineLimit = 25000
    static let parseUTF16Limit = 1_500_000
    static let parseUTF8Limit = 5_000_000

    enum ParseOversizeReason: Equatable, CustomStringConvertible {
        case lineCountExceeded(actual: Int)
        case utf16LengthExceeded(actual: Int)
        case utf8SizeExceeded(actual: Int)

        var description: String {
            switch self {
            case let .lineCountExceeded(actual):
                "line count \(actual) exceeded limit \(SyntaxManager.parseLineLimit)"
            case let .utf16LengthExceeded(actual):
                "UTF-16 length \(actual) exceeded limit \(SyntaxManager.parseUTF16Limit)"
            case let .utf8SizeExceeded(actual):
                "UTF-8 size \(actual) exceeded limit \(SyntaxManager.parseUTF8Limit)"
            }
        }
    }

    /// Maps file extension to LanguageType.
    let extensionToLanguage: [String: LanguageType] = [
        "swift": .swift,
        "js": .js,
        "cs": .c_sharp,
        "py": .python,
        "c": .c,
        "rs": .rust,
        "cpp": .cpp,
        "go": .go,
        "java": .java,
        "dart": .dart,
        "ts": .ts,
        "tsx": .tsx,
        "php": .php, // NEW
        "rb": .ruby
    ]

    /// Optimized Tree‑sitter highlight queries.
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
        .php: basicPhpQuery, // NEW
        .ruby: rubyHighlightQuery
    ]

    /// Compatibility view derived from the authoritative registered query bytes.
    let codeMapQueries: [LanguageType: String]

    /// Cache for language configurations. Highlight queries are intentionally not stored here;
    /// use highlightQuery(for:language:) so they compile lazily outside codemap startup.
    private var languageConfigs: [LanguageType: LanguageConfiguration] = [:]

    /// Serializes SwiftTreeSitter language/parser/query work. These wrappers own C pointers and
    /// are shared through cached LanguageConfiguration/Query values, so keep their access one-at-a-time.
    private let treeSitterExecutionLock = NSRecursiveLock()

    // Highlight queries are compiled lazily on first highlight use so codemap startup avoids highlight query work.
    private let highlightQueryCacheLock = NSLock()
    private var highlightQueryResults: [LanguageType: Result<Query, Error>] = [:]

    private func withTreeSitterExecution<T>(_ operation: () throws -> T) rethrows -> T {
        treeSitterExecutionLock.lock()
        defer { treeSitterExecutionLock.unlock() }
        return try operation()
    }

    /// Returns a reason if the provided content should skip Tree-sitter parsing.
    func parsingOversizeReason(for content: String) -> ParseOversizeReason? {
        let utf8View = content.utf8 // (anchor) keep as first line for stable patching

        // 1) Fast-path: UTF‑8 byte size (O(1) when contiguous, otherwise fallback)
        if let byteCount = utf8View.withContiguousStorageIfAvailable({ $0.count }) {
            if byteCount > Self.parseUTF8Limit {
                return .utf8SizeExceeded(actual: byteCount)
            }
        } else {
            let utf8Size = utf8View.count
            if utf8Size > Self.parseUTF8Limit {
                return .utf8SizeExceeded(actual: utf8Size)
            }
        }

        // 2) UTF‑16 code units (only if we didn't already exceed UTF‑8 bytes)
        let utf16Length = content.utf16.count
        if utf16Length > Self.parseUTF16Limit {
            return .utf16LengthExceeded(actual: utf16Length)
        }

        // 3) Line count (early exit when crossing the threshold)
        if let actualLines = exceededLineCount(in: utf8View, limit: Self.parseLineLimit) {
            return .lineCountExceeded(actual: actualLines)
        }
        return nil
    }

    private func exceededLineCount(in utf8: String.UTF8View, limit: Int) -> Int? {
        guard limit > 0 else { return nil }
        guard !utf8.isEmpty else { return nil }

        // Fast path: contiguous UTF‑8 buffer scanning (no indexing overhead)
        if let res = utf8.withContiguousStorageIfAvailable({ (buf: UnsafeBufferPointer<UInt8>) -> Int? in
            var lines = 1
            var i = buf.startIndex
            let end = buf.endIndex

            while i < end {
                let b = buf[i]
                if b == 0x0A { // \n
                    lines += 1
                    if lines > limit { return lines }
                    i = buf.index(after: i)
                    continue
                } else if b == 0x0D { // \r
                    lines += 1
                    if lines > limit { return lines }
                    i = buf.index(after: i)
                    if i < end, buf[i] == 0x0A { // swallow \r\n
                        i = buf.index(after: i)
                    }
                    continue
                }
                i = buf.index(after: i)
            }
            return nil
        }) {
            // res is Int? produced by the closure; return if limit exceeded
            if let exceeded = res { return exceeded }
            // else fall through to return nil below
            return nil
        }

        // Fallback: safe index-based scan (original logic)
        var lines = 1
        var index = utf8.startIndex
        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == 0x0A { // \n
                lines += 1
                if lines > limit { return lines }
                index = utf8.index(after: index)
                continue
            } else if byte == 0x0D { // \r
                lines += 1
                if lines > limit { return lines }
                let next = utf8.index(after: index)
                if next < utf8.endIndex, utf8[next] == 0x0A {
                    index = utf8.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            index = utf8.index(after: index)
        }
        return nil
    }

    private static func languageAndName(for languageType: LanguageType) -> (language: Language?, name: String) {
        do {
            let descriptor = try RegisteredCodeMapLanguageStore.lookup(for: languageType)
            return (descriptor.language, descriptor.displayName)
        } catch {
            return (nil, languageType.displayName)
        }
    }

    init() {
        codeMapQueries = Dictionary(
            uniqueKeysWithValues: LanguageType.allCases.map { languageType in
                let recipe = Self.RegisteredCodeMapLanguageStore.recipe(for: languageType)
                return (languageType, recipe.queryText)
            }
        )
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

    /// Pre-loads all language configs at app boot.
    private func warmCache(startupStats: inout CodeMapSyntaxStartupPerfStats, collectPerf: Bool) {
        let warmCacheStart = collectPerf ? CodeMapPerfRuntime.currentTime() : nil
        defer {
            if let warmCacheStart {
                startupStats.warmCacheDuration += CodeMapPerfRuntime.durationSince(warmCacheStart)
            }
        }

        withTreeSitterExecution {
            for languageType in Set(optimizedQueries.keys).union(codeMapQueries.keys).sorted() {
                if collectPerf { startupStats.warmCacheLanguageCount += 1 }
                if languageConfigs[languageType] == nil,
                   let config = createLanguageConfig(for: languageType, startupStats: &startupStats, collectPerf: collectPerf)
                {
                    languageConfigs[languageType] = config
                }
            }
        }
    }

    /// Returns the LanguageConfiguration for a given file extension, or nil if unsupported.
    /// Do not use the returned SwiftTreeSitter wrappers for parser/query execution outside SyntaxManager's gate.
    func languageConfig(forFileExtension ext: String) -> LanguageConfiguration? {
        withTreeSitterExecution {
            languageConfigUnlocked(forFileExtension: ext)
        }
    }

    /// Returns the LanguageConfiguration while the Tree-sitter execution lock is already held.
    private func languageConfigUnlocked(forFileExtension ext: String) -> LanguageConfiguration? {
        guard let language = language(forFileExtension: ext) else { return nil }
        return languageConfigUnlocked(for: language)
    }

    private func languageConfigUnlocked(for language: LanguageType) -> LanguageConfiguration? {
        if let config = languageConfigs[language] { return config }
        if let newConfig = createLanguageConfig(for: language) {
            languageConfigs[language] = newConfig
            return newConfig
        }
        return nil
    }

    func language(forFileExtension fileExtension: String) -> LanguageType? {
        extensionToLanguage[fileExtension.lowercased()]
    }

    func codeMapPipelineDescriptor(for languageType: LanguageType) throws -> CodeMapLanguagePipelineDescriptor {
        try withTreeSitterExecution {
            let descriptor = try Self.RegisteredCodeMapLanguageStore.lookup(for: languageType)
            guard let abiVersion = UInt32(exactly: descriptor.language.ABIVersion), abiVersion > 0 else {
                throw CodeMapCanonicalIdentityError.invalidValue(field: "tree-sitter-abi")
            }
            return CodeMapLanguagePipelineDescriptor(
                stableLanguageID: descriptor.stableLanguageID,
                grammarRevision: descriptor.grammarRevision,
                treeSitterABIVersion: abiVersion,
                queryBytes: descriptor.queryBytes
            )
        }
    }

    func pipelineIdentity(
        for languageType: LanguageType,
        decoderPolicy: CodeMapSourceDecoderPolicy
    ) throws -> CodeMapPipelineIdentity {
        let descriptor = try codeMapPipelineDescriptor(for: languageType)
        return try CodeMapPipelineIdentity(
            languageID: descriptor.stableLanguageID,
            decoderPolicy: decoderPolicy,
            grammarRevision: descriptor.grammarRevision,
            treeSitterABIVersion: descriptor.treeSitterABIVersion,
            codeMapQuerySHA256: CodeMapSHA256Digest(
                bytes: Data(SHA256.hash(data: descriptor.queryBytes))
            ),
            // Bump these semantic versions for extraction/finalization changes that are not
            // represented by an explicit limit or flag below.
            extractorVersion: CodeMapSemanticVersion(major: 1, minor: 0, patch: 0),
            generatorVersion: CodeMapSemanticVersion(major: 1, minor: 0, patch: 0),
            artifactSchemaVersion: 1,
            oversizeParsePolicyVersion: 1,
            limits: [
                CodeMapPipelineNamedLimit(
                    name: "jsts-max-appended-continuation-lines",
                    value: UInt64(CodeMapGenerator.jstsMaxAppendedContinuationLines)
                ),
                CodeMapPipelineNamedLimit(name: "parse-line-count", value: UInt64(Self.parseLineLimit)),
                CodeMapPipelineNamedLimit(name: "parse-utf16-code-units", value: UInt64(Self.parseUTF16Limit)),
                CodeMapPipelineNamedLimit(name: "parse-utf8-bytes", value: UInt64(Self.parseUTF8Limit))
            ],
            flags: [
                CodeMapPipelineNamedFlag(name: "filename-main-class-shaping", enabled: false),
                CodeMapPipelineNamedFlag(
                    name: "jsts-signature-extraction",
                    enabled: languageType == .js || languageType == .ts || languageType == .tsx
                ),
                CodeMapPipelineNamedFlag(
                    name: "lightweight-extraction",
                    enabled: Self.isLightweight(language: languageType)
                ),
                CodeMapPipelineNamedFlag(name: "path-free-artifact-finalization", enabled: true),
                CodeMapPipelineNamedFlag(name: "swift-range-strategy", enabled: languageType == .swift),
                CodeMapPipelineNamedFlag(
                    name: "typescript-range-strategy",
                    enabled: languageType == .ts || languageType == .tsx
                )
            ]
        )
    }

    /// Creates a LanguageConfiguration for the specified LanguageType.
    private func createLanguageConfig(for languageType: LanguageType) -> LanguageConfiguration? {
        var startupStats = CodeMapSyntaxStartupPerfStats()
        return createLanguageConfig(for: languageType, startupStats: &startupStats, collectPerf: false)
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
        let (language, name) = Self.languageAndName(for: languageType)
        if let pointerStart {
            startupStats.languagePointerDuration += CodeMapPerfRuntime.durationSince(pointerStart)
        }
        guard let language else {
            print("No language pointer for \(name).")
            if collectPerf { startupStats.languageConfigFailureCount += 1 }
            return nil
        }

        if collectPerf { startupStats.languageConfigSuccessCount += 1 }
        return LanguageConfiguration(language, name: name, queries: [:])
    }

    /// Parses file content into a MutableTree using SwiftTreeSitter.
    func parse(content: String, fileExtension: String) throws -> MutableTree? {
        guard extensionToLanguage[fileExtension.lowercased()] != nil else { return nil }
        if let reason = parsingOversizeReason(for: content) {
            print("[SyntaxManager] Skipping parse for .\(fileExtension): \(reason)")
            return nil
        }

        return try withTreeSitterExecution {
            guard let config = languageConfigUnlocked(forFileExtension: fileExtension) else { return nil }
            let parser = Parser()
            try parser.setLanguage(config.language)
            return parser.parse(content)
        }
    }

    /// Runs the highlight query for a given file's content.
    func highlight(content: String, fileExtension: String) throws -> [NamedRange] {
        // Fast, zero-allocation line guard (bails early once past 5k)
        guard exceededLineCount(in: content.utf8, limit: 5000) == nil else {
            return []
        }

        guard let langType = extensionToLanguage[fileExtension.lowercased()] else { return [] }
        if let reason = parsingOversizeReason(for: content) {
            print("[SyntaxManager] Skipping highlight parse for .\(fileExtension): \(reason)")
            return []
        }

        return try withTreeSitterExecution {
            guard let config = languageConfigUnlocked(forFileExtension: fileExtension) else { return [] }
            let parser = Parser()
            try parser.setLanguage(config.language)

            guard let tree = parser.parse(content),
                  let root = tree.rootNode
            else {
                return []
            }
            guard let highlightLookup = try highlightQuery(for: langType, language: config.language) else {
                return []
            }

            let cursor = highlightLookup.query.execute(node: root, in: tree)
            return cursor.highlights()
        }
    }

    private func highlightQuery(for languageType: LanguageType, language: Language) throws -> HighlightQueryLookupResult? {
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

    private static func missingCodeMapQueryError(for languageType: LanguageType) -> NSError {
        NSError(
            domain: "SyntaxManager.CodeMapQuery",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing codemap query for \(languageType.displayName)"]
        )
    }

    private func codeMapQuery(for languageType: LanguageType, language _: Language) throws -> CodeMapQueryLookupResult {
        try Self.LazyCodeMapQueryStore.lookup(for: languageType)
    }

    /// Runs the legacy extension-based code-map query. Deterministic negative
    /// outcomes remain collapsed to an empty capture list for current serving.
    func codeMap(content: String, fileExtension: String) throws -> [NamedRange] {
        let pipelineStats = CodeMapPerfRuntime.sharedPipelineStats
        let languageLookupStart = pipelineStats != nil ? CodeMapPerfRuntime.currentTime() : nil
        let language = language(forFileExtension: fileExtension)
        let languageLookupDuration = languageLookupStart.map(CodeMapPerfRuntime.durationSince) ?? 0
        guard let language else {
            if let pipelineStats {
                var syntaxPerf = CodeMapSyntaxPerfStats()
                syntaxPerf.calls = 1
                syntaxPerf.unsupported = 1
                syntaxPerf.languageLookupDuration = languageLookupDuration
                pipelineStats.mergeSyntaxCodeMapStats(syntaxPerf)
            }
            return []
        }

        switch try codeMapOutcome(
            content: content,
            language: language,
            diagnosticLabel: ".\(fileExtension)",
            initialLanguageLookupDuration: languageLookupDuration,
            missingConfigurationReturnsEmptyCaptures: true
        ) {
        case let .captures(captures): return captures
        case .oversize, .parseFailed: return []
        }
    }

    /// Runs a code-map query for an already-resolved language without accepting
    /// any filename or path identity.
    func codeMap(content: String, language: LanguageType) throws -> CodeMapSyntaxQueryOutcome {
        try codeMapOutcome(
            content: content,
            language: language,
            diagnosticLabel: language.rawValue,
            initialLanguageLookupDuration: 0,
            missingConfigurationReturnsEmptyCaptures: false
        )
    }

    private func codeMapOutcome(
        content: String,
        language: LanguageType,
        diagnosticLabel: String,
        initialLanguageLookupDuration: TimeInterval,
        missingConfigurationReturnsEmptyCaptures: Bool
    ) throws -> CodeMapSyntaxQueryOutcome {
        let pipelineStats = CodeMapPerfRuntime.sharedPipelineStats
        let collectSyntaxPerf = pipelineStats != nil
        var syntaxPerf = CodeMapSyntaxPerfStats()
        if collectSyntaxPerf {
            syntaxPerf.calls = 1
            syntaxPerf.languageLookupDuration = initialLanguageLookupDuration
        }
        defer {
            if collectSyntaxPerf {
                pipelineStats?.mergeSyntaxCodeMapStats(syntaxPerf)
            }
        }

        let oversizeGuardStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
        let oversizeReason = parsingOversizeReason(for: content)
        if let oversizeGuardStart {
            syntaxPerf.oversizeGuardDuration += CodeMapPerfRuntime.durationSince(oversizeGuardStart)
        }
        if let reason = oversizeReason {
            if collectSyntaxPerf { syntaxPerf.oversized += 1 }
            print("[SyntaxManager] Skipping code map parse for \(diagnosticLabel): \(reason)")
            return .oversize(Self.artifactOversizeReason(reason))
        }

        return try withTreeSitterExecution {
            let configLookupStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
            let config = languageConfigUnlocked(for: language)
            if let configLookupStart {
                syntaxPerf.languageLookupDuration += CodeMapPerfRuntime.durationSince(configLookupStart)
            }
            guard let config else {
                if collectSyntaxPerf { syntaxPerf.unsupported += 1 }
                if missingConfigurationReturnsEmptyCaptures {
                    return .captures([])
                }
                throw Self.missingCodeMapQueryError(for: language)
            }

            let parserCreateStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
            let parser = Parser()
            if let parserCreateStart {
                syntaxPerf.parserCreateDuration += CodeMapPerfRuntime.durationSince(parserCreateStart)
                syntaxPerf.parserCreates += 1
            }

            do {
                let setLanguageStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
                defer {
                    if let setLanguageStart {
                        syntaxPerf.setLanguageDuration += CodeMapPerfRuntime.durationSince(setLanguageStart)
                    }
                }
                try parser.setLanguage(config.language)
            }

            let parseStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
            let tree = parser.parse(content)
            if let parseStart {
                syntaxPerf.parseDuration += CodeMapPerfRuntime.durationSince(parseStart)
            }
            guard let tree else {
                if collectSyntaxPerf { syntaxPerf.parseNilTree += 1 }
                return .parseFailed(.parserReturnedNilTree)
            }
            guard let root = tree.rootNode else {
                if collectSyntaxPerf { syntaxPerf.parseNilRoot += 1 }
                return .parseFailed(.parserReturnedNilRoot)
            }

            let query: Query
            do {
                let queryLookupStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
                defer {
                    if let queryLookupStart {
                        syntaxPerf.codeMapQueryLookupDuration += CodeMapPerfRuntime.durationSince(queryLookupStart)
                    }
                }
                let lookup = try codeMapQuery(for: language, language: config.language)
                if collectSyntaxPerf {
                    switch lookup.status {
                    case .precomputedHit:
                        syntaxPerf.codeMapQueryCacheHits += 1
                    case .fallbackCompile:
                        syntaxPerf.codeMapQueryCacheMisses += 1
                    }
                }
                query = lookup.query
            }

            let queryExecuteStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
            let cursor = query.execute(node: root, in: tree)
            if let queryExecuteStart {
                syntaxPerf.queryExecuteDuration += CodeMapPerfRuntime.durationSince(queryExecuteStart)
                syntaxPerf.queryExecutes += 1
            }

            let materializationStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
            let captures = cursor.highlights()
            if let materializationStart {
                syntaxPerf.captureMaterializationDuration += CodeMapPerfRuntime.durationSince(materializationStart)
                syntaxPerf.captures += captures.count
            }
            return .captures(captures)
        }
    }

    private static func artifactOversizeReason(_ reason: ParseOversizeReason) -> CodeMapSyntaxOversizeReason {
        switch reason {
        case let .utf8SizeExceeded(actual):
            .utf8Bytes(actual: actual, limit: parseUTF8Limit)
        case let .utf16LengthExceeded(actual):
            .utf16Units(actual: actual, limit: parseUTF16Limit)
        case let .lineCountExceeded(actual):
            .lines(actual: actual, limit: parseLineLimit)
        }
    }

    static func isSupportedFileExtension(_ fileExt: String) -> Bool {
        switch fileExt.lowercased() {
        case "swift", "js", "cs", "py", "c", "rs", "cpp", "go", "java", "dart", "ts", "tsx",
             "php", "rb": // NEW
            true
        default:
            false
        }
    }

    /// Returns `true` if the file extension has a codemap query available.
    /// This is stricter than `isSupportedFileExtension` which only checks syntax highlighting.
    static func supportsCodeMap(fileExtension: String) -> Bool {
        guard let langType = shared.extensionToLanguage[fileExtension.lowercased()] else {
            return false
        }
        return shared.codeMapQueries[langType] != nil
    }

    /// Instance method variant for codemap support check.
    func supportsCodeMap(fileExtension: String) -> Bool {
        guard let langType = extensionToLanguage[fileExtension.lowercased()] else {
            return false
        }
        return codeMapQueries[langType] != nil
    }

    // MARK: - Helper: languages with lightweight extraction

    /// Returns `true` for languages whose code-map extraction skips
    /// full regex/type parsing and instead relies on raw declaration text.
    static func isLightweight(language: LanguageType) -> Bool {
        switch language {
        case .php, .ruby, .ts, .tsx, .js:
            true
        default:
            false
        }
    }
}
