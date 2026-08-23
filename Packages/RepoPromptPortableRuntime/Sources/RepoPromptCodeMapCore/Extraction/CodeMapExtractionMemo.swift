//
//  CodeMapExtractionMemo.swift
//  RepoPrompt
//
//  Per-file memoization for deterministic codemap extractor calls.
//

import Foundation

struct CodeMapExtractionMemo {
    private struct LanguageLineKey: Hashable {
        let language: LanguageType
        let line: String
    }

    private struct JSTSKey: Hashable {
        let contextRaw: UInt8
        let line: String
    }

    private enum CachedOptional<Value> {
        case some(Value)
        case none
    }

    private var jstsSignatureByKey: [JSTSKey: String] = [:]
    private var functionDictByKey: [LanguageLineKey: CachedOptional<[String: String]>] = [:]
    private var functionParsedByKey: [LanguageLineKey: CachedOptional<LanguageTypeExtractor.FunctionLineMatch>] = [:]
    private var variableDictByKey: [LanguageLineKey: CachedOptional<[String: String]>] = [:]
    private var tsReturnTypeByLine: [String: CachedOptional<String>] = [:]
    private var tsTypeAnnotationByLine: [String: CachedOptional<String>] = [:]
    private var tsTypeAliasRHSByLine: [String: CachedOptional<String>] = [:]

    mutating func jstsSignature(
        from line: String,
        context: JSTSSignatureContext,
        perfStats: CodeMapPerformanceCollector?,
        perfOptions: CodeMapPerfOptions
    ) -> String {
        let key = JSTSKey(contextRaw: Self.rawContext(context), line: line)
        if let cached = jstsSignatureByKey[key] {
            perfStats?.extractionMemoJSTSHits += 1
            return cached
        }
        perfStats?.extractionMemoJSTSMisses += 1
        let result = JSTSSignatureExtractor.extract(
            from: line,
            context: context,
            perfStats: perfStats,
            perfOptions: perfOptions
        )
        jstsSignatureByKey[key] = result
        return result
    }

    mutating func matchFunctionLine(
        _ line: String,
        language: LanguageType,
        stats: CodeMapPerformanceCollector?
    ) -> [String: String]? {
        let key = LanguageLineKey(language: language, line: line)
        if let cached = functionDictByKey[key] {
            stats?.extractionMemoFunctionHits += 1
            return Self.unwrap(cached)
        }
        stats?.extractionMemoFunctionMisses += 1
        let result = LanguageTypeExtractor.matchAnyFunctionLine(line, language: language, stats: stats)
        functionDictByKey[key] = Self.wrap(result)
        return result
    }

    mutating func matchFunctionLineParsed(
        _ line: String,
        language: LanguageType,
        stats: CodeMapPerformanceCollector?
    ) -> LanguageTypeExtractor.FunctionLineMatch? {
        let key = LanguageLineKey(language: language, line: line)
        if let cached = functionParsedByKey[key] {
            stats?.extractionMemoFunctionParsedHits += 1
            return Self.unwrap(cached)
        }
        stats?.extractionMemoFunctionParsedMisses += 1
        let result = LanguageTypeExtractor.matchAnyFunctionLineParsed(line, language: language, stats: stats)
        functionParsedByKey[key] = Self.wrap(result)
        return result
    }

    mutating func matchVariableLine(
        _ line: String,
        language: LanguageType,
        stats: CodeMapPerformanceCollector?
    ) -> [String: String]? {
        let key = LanguageLineKey(language: language, line: line)
        if let cached = variableDictByKey[key] {
            stats?.extractionMemoVariableHits += 1
            return Self.unwrap(cached)
        }
        stats?.extractionMemoVariableMisses += 1
        let result = LanguageTypeExtractor.matchAnyVariableLine(line, language: language, stats: stats)
        variableDictByKey[key] = Self.wrap(result)
        return result
    }

    mutating func tsReturnType(
        from signature: String,
        stats: CodeMapPerformanceCollector?
    ) -> String? {
        if let cached = tsReturnTypeByLine[signature] {
            stats?.extractionMemoTSFastPathHits += 1
            return Self.unwrap(cached)
        }
        stats?.extractionMemoTSFastPathMisses += 1
        let result = LanguageTypeExtractor.TS.extractReturnType(from: signature, stats: stats)
        tsReturnTypeByLine[signature] = Self.wrap(result)
        return result
    }

    mutating func tsTypeAnnotation(from line: String, stats: CodeMapPerformanceCollector?) -> String? {
        if let cached = tsTypeAnnotationByLine[line] {
            stats?.extractionMemoTSFastPathHits += 1
            return Self.unwrap(cached)
        }
        stats?.extractionMemoTSFastPathMisses += 1
        let result = LanguageTypeExtractor.TS.extractTypeAnnotation(from: line)
        tsTypeAnnotationByLine[line] = Self.wrap(result)
        return result
    }

    mutating func tsTypeAliasRHS(from line: String, stats: CodeMapPerformanceCollector?) -> String? {
        if let cached = tsTypeAliasRHSByLine[line] {
            stats?.extractionMemoTSFastPathHits += 1
            return Self.unwrap(cached)
        }
        stats?.extractionMemoTSFastPathMisses += 1
        let result = LanguageTypeExtractor.TS.extractTypeAliasRHS(from: line)
        tsTypeAliasRHSByLine[line] = Self.wrap(result)
        return result
    }

    private static func rawContext(_ context: JSTSSignatureContext) -> UInt8 {
        switch context {
        case .functionLike:
            0
        case .statementLike:
            1
        }
    }

    private static func wrap<Value>(_ value: Value?) -> CachedOptional<Value> {
        if let value {
            return .some(value)
        }
        return .none
    }

    private static func unwrap<Value>(_ cached: CachedOptional<Value>) -> Value? {
        switch cached {
        case let .some(value):
            value
        case .none:
            nil
        }
    }
}
