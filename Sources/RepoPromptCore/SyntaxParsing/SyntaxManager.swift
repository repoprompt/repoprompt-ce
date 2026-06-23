//
//  SyntaxManager.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-05.
//

import Foundation
import RepoPromptSyntaxCBridge
import SwiftTreeSitter

package enum LanguageType: String, Comparable, Codable {
    case swift, js, c_sharp, python, c, rust, cpp, go, java, dart, ts, tsx,
         php, ruby // ➜ NEW

    package var displayName: String {
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

    package static func < (lhs: LanguageType, rhs: LanguageType) -> Bool {
        lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
        // If you’d rather sort by declaration order instead, use:
        // lhs.rawValue < rhs.rawValue
    }
}

package final class SyntaxManager {
    package static let shared = SyntaxManager()

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

        private enum SwiftQuery { static let result = make(languageType: .swift, queryText: swiftCodeMapQuery) }
        private enum JavaScriptQuery { static let result = make(languageType: .js, queryText: javascriptCodeMapQuery) }
        private enum CSharpQuery { static let result = make(languageType: .c_sharp, queryText: csharpCodeMapQuery) }
        private enum PythonQuery { static let result = make(languageType: .python, queryText: pythonCodeMapQuery) }
        private enum CQuery { static let result = make(languageType: .c, queryText: cCodeMapQuery) }
        private enum RustQuery { static let result = make(languageType: .rust, queryText: rustCodeMapQuery) }
        private enum CppQuery { static let result = make(languageType: .cpp, queryText: cppCodeMapQuery) }
        private enum GoQuery { static let result = make(languageType: .go, queryText: goCodeMapQuery) }
        private enum JavaQuery { static let result = make(languageType: .java, queryText: javaCodeMapQuery) }
        private enum DartQuery { static let result = make(languageType: .dart, queryText: dartCodeMapQuery) }
        private enum TypeScriptQuery { static let result = make(languageType: .ts, queryText: typeScriptCodeMapQuery) }
        private enum TSXQuery { static let result = make(languageType: .tsx, queryText: typeScriptCodeMapQuery) }
        private enum PHPQuery { static let result = make(languageType: .php, queryText: phpCodeMapQuery) }
        private enum RubyQuery { static let result = make(languageType: .ruby, queryText: rubyCodeMapQuery) }

        private static func make(languageType: LanguageType, queryText: String) -> Result<Query, Error> {
            Result {
                let (language, _) = SyntaxManager.languageAndName(for: languageType)
                guard let language else {
                    throw SyntaxManager.missingCodeMapQueryError(for: languageType)
                }
                guard let data = queryText.data(using: .utf8) else {
                    throw SyntaxManager.missingCodeMapQueryError(for: languageType)
                }
                return try Query(language: language, data: data)
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
    package let extensionToLanguage: [String: LanguageType] = [
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

    /// Code‑map queries for extracting structure.
    let codeMapQueries: [LanguageType: String] = [
        .c: cCodeMapQuery,
        .cpp: cppCodeMapQuery,
        .c_sharp: csharpCodeMapQuery,
        .go: goCodeMapQuery,
        .rust: rustCodeMapQuery,
        .js: javascriptCodeMapQuery,
        .swift: swiftCodeMapQuery,
        .dart: dartCodeMapQuery,
        .java: javaCodeMapQuery,
        .python: pythonCodeMapQuery,
        .ts: typeScriptCodeMapQuery,
        .tsx: typeScriptCodeMapQuery,
        .php: phpCodeMapQuery, // NEW
        .ruby: rubyCodeMapQuery
    ]

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
        switch languageType {
        case .swift: (tree_sitter_swift().map(Language.init(language:)), "Swift")
        case .js: (tree_sitter_javascript().map(Language.init(language:)), "JavaScript")
        case .c_sharp: (tree_sitter_c_sharp().map(Language.init(language:)), "C#")
        case .python: (tree_sitter_python().map(Language.init(language:)), "Python")
        case .c: (tree_sitter_c().map(Language.init(language:)), "C")
        case .rust: (tree_sitter_rust().map(Language.init(language:)), "Rust")
        case .cpp: (tree_sitter_cpp().map(Language.init(language:)), "C++")
        case .go: (tree_sitter_go().map(Language.init(language:)), "Go")
        case .java: (tree_sitter_java().map(Language.init(language:)), "Java")
        case .dart: (tree_sitter_dart().map(Language.init(language:)), "Dart")
        case .ts: (tree_sitter_typescript().map(Language.init(language:)), "TypeScript")
        case .tsx: (tree_sitter_tsx().map(Language.init(language:)), "TSX")
        case .php: (tree_sitter_php().map(Language.init(language:)), "PHP")
        case .ruby: (tree_sitter_ruby().map(Language.init(language:)), "Ruby")
        }
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
        guard let langType = extensionToLanguage[ext.lowercased()] else { return nil }
        if let config = languageConfigs[langType] { return config }
        if let newConfig = createLanguageConfig(for: langType) {
            languageConfigs[langType] = newConfig
            return newConfig
        }
        return nil
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
    package func highlight(content: String, fileExtension: String) throws -> [NamedRange] {
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

    /// Runs the code‑map query for a given file's content.
    package func codeMap(content: String, fileExtension: String) throws -> [NamedRange] {
        let pipelineStats = CodeMapPerfRuntime.sharedPipelineStats
        let collectSyntaxPerf = pipelineStats != nil
        var syntaxPerf = CodeMapSyntaxPerfStats()
        if collectSyntaxPerf {
            syntaxPerf.calls = 1
        }
        defer {
            if collectSyntaxPerf {
                pipelineStats?.mergeSyntaxCodeMapStats(syntaxPerf)
            }
        }

        let languageLookupStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
        let langType = extensionToLanguage[fileExtension.lowercased()]
        if let languageLookupStart {
            syntaxPerf.languageLookupDuration += CodeMapPerfRuntime.durationSince(languageLookupStart)
        }
        guard let langType else {
            if collectSyntaxPerf { syntaxPerf.unsupported += 1 }
            return []
        }

        let oversizeGuardStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
        let oversizeReason = parsingOversizeReason(for: content)
        if let oversizeGuardStart {
            syntaxPerf.oversizeGuardDuration += CodeMapPerfRuntime.durationSince(oversizeGuardStart)
        }
        if let reason = oversizeReason {
            if collectSyntaxPerf { syntaxPerf.oversized += 1 }
            print("[SyntaxManager] Skipping code map parse for .\(fileExtension): \(reason)")
            return []
        }

        return try withTreeSitterExecution {
            let configLookupStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
            defer {
                if let configLookupStart {
                    syntaxPerf.languageLookupDuration += CodeMapPerfRuntime.durationSince(configLookupStart)
                }
            }
            guard let config = languageConfigUnlocked(forFileExtension: fileExtension) else {
                if collectSyntaxPerf { syntaxPerf.unsupported += 1 }
                return []
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

            let tree: MutableTree?
            let parseStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
            tree = parser.parse(content)
            if let parseStart {
                syntaxPerf.parseDuration += CodeMapPerfRuntime.durationSince(parseStart)
            }
            guard let tree else {
                if collectSyntaxPerf { syntaxPerf.parseNilTree += 1 }
                return []
            }
            guard let root = tree.rootNode else {
                if collectSyntaxPerf { syntaxPerf.parseNilRoot += 1 }
                return []
            }

            /*
             print("\nNode tree for file: \(fileExtension)\n")
             // Debug print: Enumerate all nodes in the tree.
             let fullRange = 0..<UInt32(content.utf16.count)
             print("Enumerating all nodes in the tree:")
             tree.enumerateNodes(in: fullRange) { node in
             	print("Node: \(node) - Type: \(node.nodeType)")
             }
             print("\n-------------------------------------------------\n")
             */

            let query: Query
            do {
                let queryLookupStart = collectSyntaxPerf ? CodeMapPerfRuntime.currentTime() : nil
                defer {
                    if let queryLookupStart {
                        syntaxPerf.codeMapQueryLookupDuration += CodeMapPerfRuntime.durationSince(queryLookupStart)
                    }
                }
                let lookup = try codeMapQuery(for: langType, language: config.language)
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
            return captures
        }
    }

    package static func isSupportedFileExtension(_ fileExt: String) -> Bool {
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
    package static func supportsCodeMap(fileExtension: String) -> Bool {
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
