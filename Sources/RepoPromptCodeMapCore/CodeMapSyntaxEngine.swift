import CryptoKit
import Foundation
import SwiftTreeSitter
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterDart
import TreeSitterGo
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterPHP
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript

package enum LanguageType: String, CaseIterable, Comparable, Codable, Sendable {
    case swift, js, c_sharp, python, c, rust, cpp, go, java, dart, ts, tsx, php, ruby

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
        case .php: "PHP"
        case .ruby: "Ruby"
        }
    }

    package static func < (lhs: LanguageType, rhs: LanguageType) -> Bool {
        lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
    }
}

package enum CodeMapSyntaxQueryOutcome: Sendable {
    case captures([NamedRange])
    case oversize(CodeMapSyntaxOversizeReason)
    case parseFailed(CodeMapSyntaxParseFailure)
}

package struct CodeMapLanguagePipelineDescriptor: Sendable {
    package let stableLanguageID: CodeMapPipelineLanguageID
    package let grammarRevision: String
    package let treeSitterABIVersion: UInt32
    package let queryBytes: Data
}

package struct CodeMapGrammarDescriptor: Sendable {
    package let languageType: LanguageType
    package let stableLanguageID: CodeMapPipelineLanguageID
    package let displayName: String
    package let language: Language
    package let grammarRevision: String
    package let queryBytes: Data
}

package enum CodeMapSyntaxEngineError: Error, Equatable, Sendable {
    case missingGrammar(language: LanguageType)
    case invalidGrammarABI(language: LanguageType)
    case queryCompilation(language: LanguageType, diagnostic: String)
}

package protocol CodeMapSyntaxQuerying {
    func codeMap(content: String, language: LanguageType) throws -> CodeMapSyntaxQueryOutcome
}

package protocol CodeMapSyntaxPerformanceQuerying: CodeMapSyntaxQuerying {
    func codeMap(
        content: String,
        language: LanguageType,
        performanceCollector: CodeMapPerformanceCollector?
    ) throws -> CodeMapSyntaxQueryOutcome
}

package struct CodeMapSyntaxEngine: CodeMapSyntaxPerformanceQuerying, Sendable {
    package static let shared = CodeMapSyntaxEngine()

    package static let parseLineLimit = 25_000
    package static let parseUTF16Limit = 1_500_000
    package static let parseUTF8Limit = 5_000_000

    package static let extensionToLanguage: [String: LanguageType] = [
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
        "php": .php,
        "rb": .ruby
    ]

    package init() {}

    package func language(forFileExtension fileExtension: String) -> LanguageType? {
        Self.extensionToLanguage[fileExtension.lowercased()]
    }

    package static func isSupportedFileExtension(_ fileExtension: String) -> Bool {
        extensionToLanguage[fileExtension.lowercased()] != nil
    }

    package static func supportsCodeMap(fileExtension: String) -> Bool {
        extensionToLanguage[fileExtension.lowercased()] != nil
    }

    package static func isLightweight(language: LanguageType) -> Bool {
        switch language {
        case .php, .ruby, .ts, .tsx, .js:
            true
        default:
            false
        }
    }

    package func grammarDescriptor(for languageType: LanguageType) throws -> CodeMapGrammarDescriptor {
        try RegisteredLanguageStore.lookup(for: languageType)
    }

    package func codeMapPipelineDescriptor(
        for languageType: LanguageType
    ) throws -> CodeMapLanguagePipelineDescriptor {
        let descriptor = try grammarDescriptor(for: languageType)
        guard let abiVersion = UInt32(exactly: descriptor.language.ABIVersion), abiVersion > 0 else {
            throw CodeMapSyntaxEngineError.invalidGrammarABI(language: languageType)
        }
        return CodeMapLanguagePipelineDescriptor(
            stableLanguageID: descriptor.stableLanguageID,
            grammarRevision: descriptor.grammarRevision,
            treeSitterABIVersion: abiVersion,
            queryBytes: descriptor.queryBytes
        )
    }

    package func pipelineIdentity(
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

    package func oversizeReason(for content: String) -> CodeMapSyntaxOversizeReason? {
        let utf8View = content.utf8
        if let byteCount = utf8View.withContiguousStorageIfAvailable({ $0.count }) {
            if byteCount > Self.parseUTF8Limit {
                return .utf8Bytes(actual: byteCount, limit: Self.parseUTF8Limit)
            }
        } else {
            let utf8Size = utf8View.count
            if utf8Size > Self.parseUTF8Limit {
                return .utf8Bytes(actual: utf8Size, limit: Self.parseUTF8Limit)
            }
        }

        let utf16Length = content.utf16.count
        if utf16Length > Self.parseUTF16Limit {
            return .utf16Units(actual: utf16Length, limit: Self.parseUTF16Limit)
        }

        if let actualLines = Self.exceededLineCount(in: utf8View, limit: Self.parseLineLimit) {
            return .lines(actual: actualLines, limit: Self.parseLineLimit)
        }
        return nil
    }

    package func codeMap(content: String, language: LanguageType) throws -> CodeMapSyntaxQueryOutcome {
        try codeMap(content: content, language: language, performanceCollector: nil)
    }

    package func codeMap(
        content: String,
        language: LanguageType,
        performanceCollector: CodeMapPerformanceCollector?
    ) throws -> CodeMapSyntaxQueryOutcome {
        let collect = performanceCollector != nil
        if collect { performanceCollector?.syntaxCalls = 1 }

        let oversizeStart = collect ? ProcessInfo.processInfo.systemUptime : nil
        let reason = oversizeReason(for: content)
        if let oversizeStart {
            performanceCollector?.syntaxOversizeGuardDuration += ProcessInfo.processInfo.systemUptime - oversizeStart
        }
        if let reason {
            performanceCollector?.syntaxOversized += 1
            return .oversize(reason)
        }

        let descriptorStart = collect ? ProcessInfo.processInfo.systemUptime : nil
        let descriptor: CodeMapGrammarDescriptor
        do {
            descriptor = try grammarDescriptor(for: language)
        } catch {
            performanceCollector?.syntaxUnsupported += 1
            throw error
        }
        if let descriptorStart {
            performanceCollector?.syntaxLanguageLookupDuration += ProcessInfo.processInfo.systemUptime - descriptorStart
        }

        let parserCreateStart = collect ? ProcessInfo.processInfo.systemUptime : nil
        let parser = Parser()
        if let parserCreateStart {
            performanceCollector?.syntaxParserCreateDuration += ProcessInfo.processInfo.systemUptime - parserCreateStart
            performanceCollector?.syntaxParserCreates += 1
        }

        let setLanguageStart = collect ? ProcessInfo.processInfo.systemUptime : nil
        try parser.setLanguage(descriptor.language)
        if let setLanguageStart {
            performanceCollector?.syntaxSetLanguageDuration += ProcessInfo.processInfo.systemUptime - setLanguageStart
        }

        let parseStart = collect ? ProcessInfo.processInfo.systemUptime : nil
        let tree = parser.parse(content)
        if let parseStart {
            performanceCollector?.syntaxParseDuration += ProcessInfo.processInfo.systemUptime - parseStart
        }
        guard let tree else {
            performanceCollector?.syntaxParseNilTree += 1
            return .parseFailed(.parserReturnedNilTree)
        }
        guard let root = tree.rootNode else {
            performanceCollector?.syntaxParseNilRoot += 1
            return .parseFailed(.parserReturnedNilRoot)
        }

        let queryLookupStart = collect ? ProcessInfo.processInfo.systemUptime : nil
        let query = try QueryStore.lookup(for: language)
        if let queryLookupStart {
            performanceCollector?.syntaxCodeMapQueryLookupDuration +=
                ProcessInfo.processInfo.systemUptime - queryLookupStart
            performanceCollector?.syntaxCodeMapQueryCacheHits += 1
        }

        let queryStart = collect ? ProcessInfo.processInfo.systemUptime : nil
        let cursor = query.execute(node: root, in: tree)
        if let queryStart {
            performanceCollector?.syntaxQueryExecuteDuration += ProcessInfo.processInfo.systemUptime - queryStart
            performanceCollector?.syntaxQueryExecutes += 1
        }

        let materializationStart = collect ? ProcessInfo.processInfo.systemUptime : nil
        let captures = cursor.highlights()
        if let materializationStart {
            performanceCollector?.syntaxCaptureMaterializationDuration +=
                ProcessInfo.processInfo.systemUptime - materializationStart
            performanceCollector?.syntaxCaptures += captures.count
        }
        return .captures(captures)
    }

    package static func exceededLineCount(in utf8: String.UTF8View, limit: Int) -> Int? {
        guard limit > 0, !utf8.isEmpty else { return nil }

        if let result = utf8.withContiguousStorageIfAvailable({ buffer -> Int? in
            var lines = 1
            var index = buffer.startIndex
            while index < buffer.endIndex {
                let byte = buffer[index]
                if byte == 0x0A {
                    lines += 1
                    if lines > limit { return lines }
                    index = buffer.index(after: index)
                } else if byte == 0x0D {
                    lines += 1
                    if lines > limit { return lines }
                    index = buffer.index(after: index)
                    if index < buffer.endIndex, buffer[index] == 0x0A {
                        index = buffer.index(after: index)
                    }
                } else {
                    index = buffer.index(after: index)
                }
            }
            return nil
        }) {
            return result
        }

        var lines = 1
        var index = utf8.startIndex
        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == 0x0A {
                lines += 1
                if lines > limit { return lines }
                index = utf8.index(after: index)
            } else if byte == 0x0D {
                lines += 1
                if lines > limit { return lines }
                let next = utf8.index(after: index)
                if next < utf8.endIndex, utf8[next] == 0x0A {
                    index = utf8.index(after: next)
                } else {
                    index = next
                }
            } else {
                index = utf8.index(after: index)
            }
        }
        return nil
    }
}

private struct CodeMapLanguageRecipe {
    let stableLanguageID: CodeMapPipelineLanguageID
    let displayName: String
    let makeLanguage: () -> Language?
    let grammarRevision: String
    let queryText: String
}

private enum RegisteredLanguageStore {
    static func recipe(for languageType: LanguageType) -> CodeMapLanguageRecipe {
        switch languageType {
        case .swift:
            CodeMapLanguageRecipe(
                stableLanguageID: .swift,
                displayName: "Swift",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_swift()) },
                grammarRevision: "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5",
                queryText: swiftCodeMapQuery
            )
        case .js:
            CodeMapLanguageRecipe(
                stableLanguageID: .javascript,
                displayName: "JavaScript",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_javascript()) },
                grammarRevision: "44c892e0be055ac465d5eeddae6d3e194424e7de",
                queryText: javascriptCodeMapQuery
            )
        case .c_sharp:
            CodeMapLanguageRecipe(
                stableLanguageID: .cSharp,
                displayName: "C#",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_c_sharp()) },
                grammarRevision: "cac6d5fb595f5811a076336682d5d595ac1c9e85",
                queryText: csharpCodeMapQuery
            )
        case .python:
            CodeMapLanguageRecipe(
                stableLanguageID: .python,
                displayName: "Python",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_python()) },
                grammarRevision: "293fdc02038ee2bf0e2e206711b69c90ac0d413f",
                queryText: pythonCodeMapQuery
            )
        case .c:
            CodeMapLanguageRecipe(
                stableLanguageID: .c,
                displayName: "C",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_c()) },
                grammarRevision: "b780e47fc780ddc8da13afa35a3f4ed5c157823d",
                queryText: cCodeMapQuery
            )
        case .rust:
            CodeMapLanguageRecipe(
                stableLanguageID: .rust,
                displayName: "Rust",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_rust()) },
                grammarRevision: "77a3747266f4d621d0757825e6b11edcbf991ca5",
                queryText: rustCodeMapQuery
            )
        case .cpp:
            CodeMapLanguageRecipe(
                stableLanguageID: .cpp,
                displayName: "C++",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_cpp()) },
                grammarRevision: "f41e1a044c8a84ea9fa8577fdd2eab92ec96de02",
                queryText: cppCodeMapQuery
            )
        case .go:
            CodeMapLanguageRecipe(
                stableLanguageID: .go,
                displayName: "Go",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_go()) },
                grammarRevision: "1547678a9da59885853f5f5cc8a99cc203fa2e2c",
                queryText: goCodeMapQuery
            )
        case .java:
            CodeMapLanguageRecipe(
                stableLanguageID: .java,
                displayName: "Java",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_java()) },
                grammarRevision: "94703d5a6bed02b98e438d7cad1136c01a60ba2c",
                queryText: javaCodeMapQuery
            )
        case .dart:
            CodeMapLanguageRecipe(
                stableLanguageID: .dart,
                displayName: "Dart",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_dart()) },
                grammarRevision: "be07cf7118d3dba06236a3f19541685a68209934",
                queryText: dartCodeMapQuery
            )
        case .ts:
            CodeMapLanguageRecipe(
                stableLanguageID: .typescript,
                displayName: "TypeScript",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_typescript()) },
                grammarRevision: "f975a621f4e7f532fe322e13c4f79495e0a7b2e7",
                queryText: typeScriptCodeMapQuery
            )
        case .tsx:
            CodeMapLanguageRecipe(
                stableLanguageID: .tsx,
                displayName: "TSX",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_tsx()) },
                grammarRevision: "f975a621f4e7f532fe322e13c4f79495e0a7b2e7",
                queryText: typeScriptCodeMapQuery
            )
        case .php:
            CodeMapLanguageRecipe(
                stableLanguageID: .php,
                displayName: "PHP",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_php()) },
                grammarRevision: "5b5627faaa290d89eb3d01b9bf47c3bb9e797dea",
                queryText: phpCodeMapQuery
            )
        case .ruby:
            CodeMapLanguageRecipe(
                stableLanguageID: .ruby,
                displayName: "Ruby",
                makeLanguage: { wrapGrammarLanguage(tree_sitter_ruby()) },
                grammarRevision: "71bd32fb7607035768799732addba884a37a6210",
                queryText: rubyCodeMapQuery
            )
        }
    }

    static func lookup(for languageType: LanguageType) throws -> CodeMapGrammarDescriptor {
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
    ) -> Result<CodeMapGrammarDescriptor, CodeMapSyntaxEngineError> {
        let recipe = recipe(for: languageType)
        guard let language = recipe.makeLanguage() else {
            return .failure(.missingGrammar(language: languageType))
        }
        return .success(
            CodeMapGrammarDescriptor(
                languageType: languageType,
                stableLanguageID: recipe.stableLanguageID,
                displayName: recipe.displayName,
                language: language,
                grammarRevision: recipe.grammarRevision,
                queryBytes: Data(recipe.queryText.utf8)
            )
        )
    }

    private static func wrapGrammarLanguage(_ pointer: UnsafePointer<some Any>?) -> Language? {
        guard let pointer else { return nil }
        return Language(language: OpaquePointer(pointer))
    }

    private static func wrapGrammarLanguage(_ pointer: OpaquePointer?) -> Language? {
        pointer.map(Language.init(language:))
    }
}

private enum QueryStore {
    static func lookup(for languageType: LanguageType) throws -> Query {
        switch languageType {
        case .swift: try SwiftQuery.result.get()
        case .js: try JavaScriptQuery.result.get()
        case .c_sharp: try CSharpQuery.result.get()
        case .python: try PythonQuery.result.get()
        case .c: try CQuery.result.get()
        case .rust: try RustQuery.result.get()
        case .cpp: try CppQuery.result.get()
        case .go: try GoQuery.result.get()
        case .java: try JavaQuery.result.get()
        case .dart: try DartQuery.result.get()
        case .ts: try TypeScriptQuery.result.get()
        case .tsx: try TSXQuery.result.get()
        case .php: try PHPQuery.result.get()
        case .ruby: try RubyQuery.result.get()
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

    private static func make(
        languageType: LanguageType
    ) -> Result<Query, CodeMapSyntaxEngineError> {
        do {
            let descriptor = try RegisteredLanguageStore.lookup(for: languageType)
            return .success(try Query(language: descriptor.language, data: descriptor.queryBytes))
        } catch let error as CodeMapSyntaxEngineError {
            return .failure(error)
        } catch {
            return .failure(
                .queryCompilation(
                    language: languageType,
                    diagnostic: String(describing: error)
                )
            )
        }
    }
}
