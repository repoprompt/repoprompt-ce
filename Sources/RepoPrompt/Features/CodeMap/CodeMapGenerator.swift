//
//  CodeMapGenerator.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-08.
//

import Foundation
#if CODEMAP_PERF_SIGNPOSTS
    import os
#endif
import SwiftTreeSitter

struct CodeMapGenerator {
    static let debug = false

    /// Maximum continuation lines appended after the first JS/TS declaration line.
    /// This changes extracted artifact content and is therefore part of pipeline identity.
    static let jstsMaxAppendedContinuationLines = 80

    // MARK: - Debug Configuration

    /// Controls detailed logging for code map generation
    /// Set to true to enable extensive logging for debugging lightweight language parsing
    static let debugLogging = false

    // MARK: - Perf Signposts

    #if CODEMAP_PERF_SIGNPOSTS
        private typealias SignpostToken = OSSignpostID
    #else
        private typealias SignpostToken = UInt8
    #endif

    private enum Signpost {
        #if CODEMAP_PERF_SIGNPOSTS
            static let log = OSLog(subsystem: "com.repoprompt", category: "codemap")
        #endif

        @inline(__always)
        static func begin(_ name: StaticString) -> SignpostToken {
            #if CODEMAP_PERF_SIGNPOSTS
                let id = OSSignpostID(log: log)
                os_signpost(.begin, log: log, name: name, signpostID: id)
                return id
            #else
                return 0
            #endif
        }

        @inline(__always)
        static func end(_ name: StaticString, _ token: SignpostToken) {
            #if CODEMAP_PERF_SIGNPOSTS
                os_signpost(.end, log: log, name: name, signpostID: token)
            #endif
        }
    }

    private enum CaptureLoopAttributionCategory {
        case swiftStrategy
        case tsStrategy
        case interfaceHeuristic
        case importExport
        case typeAlias
        case enumMacro
        case function
        case variable
        case skipped
        case unclassified
    }

    private static func recordCaptureLoopLineAdvance(
        duration: TimeInterval,
        collectCounters: Bool,
        perfStats: CodeMapPerfStats?
    ) {
        guard let perfStats else { return }
        perfStats.captureLoopLineAdvanceDuration += duration
        if collectCounters {
            perfStats.captureLoopLineAdvanceCount += 1
        }
    }

    private static func recordCaptureLoopAttribution(
        category: CaptureLoopAttributionCategory,
        duration: TimeInterval,
        collectCounters: Bool,
        perfStats: CodeMapPerfStats?
    ) {
        guard let perfStats else { return }
        switch category {
        case .swiftStrategy:
            perfStats.captureLoopSwiftStrategyDuration += duration
            if collectCounters { perfStats.captureLoopSwiftStrategyCount += 1 }
        case .tsStrategy:
            perfStats.captureLoopTSStrategyDuration += duration
            if collectCounters { perfStats.captureLoopTSStrategyCount += 1 }
        case .interfaceHeuristic:
            perfStats.captureLoopInterfaceHeuristicDuration += duration
            if collectCounters { perfStats.captureLoopInterfaceHeuristicCount += 1 }
        case .importExport:
            perfStats.captureLoopImportExportDuration += duration
            if collectCounters { perfStats.captureLoopImportExportCount += 1 }
        case .typeAlias:
            perfStats.captureLoopTypeAliasDuration += duration
            if collectCounters { perfStats.captureLoopTypeAliasCount += 1 }
        case .enumMacro:
            perfStats.captureLoopEnumMacroDuration += duration
            if collectCounters { perfStats.captureLoopEnumMacroCount += 1 }
        case .function:
            perfStats.captureLoopFunctionDuration += duration
            if collectCounters { perfStats.captureLoopFunctionCount += 1 }
        case .variable:
            perfStats.captureLoopVariableDuration += duration
            if collectCounters { perfStats.captureLoopVariableCount += 1 }
        case .skipped:
            perfStats.captureLoopSkippedDuration += duration
            if collectCounters { perfStats.captureLoopSkippedCount += 1 }
        case .unclassified:
            perfStats.captureLoopUnclassifiedDuration += duration
            if collectCounters { perfStats.captureLoopUnclassifiedCount += 1 }
        }
    }

    private enum FallbackFunctionAttributionCategory {
        case declaration
        case jstsSignature
        case nameExtraction
        case lteParse
        case tsFastPath
        case referencedTypes
        case routing
        case modelInsertion
        case skipped
    }

    private static func recordFallbackFunctionAttribution(
        category: FallbackFunctionAttributionCategory,
        duration: TimeInterval,
        collectCounters: Bool,
        perfStats: CodeMapPerfStats?
    ) {
        guard let perfStats else { return }
        switch category {
        case .declaration:
            perfStats.fallbackFunctionDeclarationDuration += duration
            if collectCounters { perfStats.fallbackFunctionDeclarationCount += 1 }
        case .jstsSignature:
            perfStats.fallbackFunctionJSTSSignatureDuration += duration
            if collectCounters { perfStats.fallbackFunctionJSTSSignatureCount += 1 }
        case .nameExtraction:
            perfStats.fallbackFunctionNameExtractionDuration += duration
            if collectCounters { perfStats.fallbackFunctionNameExtractionCount += 1 }
        case .lteParse:
            perfStats.fallbackFunctionLTEParseDuration += duration
            if collectCounters { perfStats.fallbackFunctionLTEParseCount += 1 }
        case .tsFastPath:
            perfStats.fallbackFunctionTSFastPathDuration += duration
            if collectCounters { perfStats.fallbackFunctionTSFastPathCount += 1 }
        case .referencedTypes:
            perfStats.fallbackFunctionReferencedTypesDuration += duration
            if collectCounters { perfStats.fallbackFunctionReferencedTypesCount += 1 }
        case .routing:
            perfStats.fallbackFunctionRoutingDuration += duration
            if collectCounters { perfStats.fallbackFunctionRoutingCount += 1 }
        case .modelInsertion:
            perfStats.fallbackFunctionModelInsertionDuration += duration
            if collectCounters { perfStats.fallbackFunctionModelInsertionCount += 1 }
        case .skipped:
            perfStats.fallbackFunctionSkippedDuration += duration
            if collectCounters { perfStats.fallbackFunctionSkippedCount += 1 }
        }
    }

    // MARK: - Range Helpers

    private struct LineCache {
        private struct RangeCacheKey: Hashable {
            let location: Int
            let length: Int

            init(_ range: NSRange) {
                location = range.location
                length = range.length
            }
        }

        let nsContent: NSString
        let boundaries: [Int]
        let contentLength: Int
        var rangeCache: [Int: NSRange] = [:]
        var lineCache: [Int: String] = [:]
        var trimmedCache: [Int: String] = [:]
        private var coveringRangeCache: [RangeCacheKey: NSRange] = [:]
        private var coveringLineCache: [RangeCacheKey: String] = [:]
        private var coveringTrimmedCache: [RangeCacheKey: String] = [:]

        init(nsContent: NSString, boundaries: [Int], contentLength: Int) {
            self.nsContent = nsContent
            self.boundaries = boundaries
            self.contentLength = contentLength
        }

        mutating func lineIndex(for location: Int) -> Int {
            CodeMapGenerator.lineIndex(for: location, using: boundaries)
        }

        mutating func range(for location: Int) -> NSRange {
            let idx = lineIndex(for: location)
            if let cached = rangeCache[idx] { return cached }
            let start = boundaries[idx]
            let end = (idx + 1 < boundaries.count) ? boundaries[idx + 1] : contentLength
            let range = NSRange(location: start, length: end - start)
            rangeCache[idx] = range
            return range
        }

        mutating func range(covering range: NSRange) -> NSRange {
            let key = RangeCacheKey(range)
            if let cached = coveringRangeCache[key] { return cached }
            let startIdx = lineIndex(for: range.location)
            let endLocation = max(range.location, NSMaxRange(range) - 1)
            let endIdx = lineIndex(for: endLocation)
            let start = boundaries[startIdx]
            let end = (endIdx + 1 < boundaries.count) ? boundaries[endIdx + 1] : contentLength
            let coveringRange = NSRange(location: start, length: end - start)
            coveringRangeCache[key] = coveringRange
            return coveringRange
        }

        mutating func line(for location: Int) -> String {
            let idx = lineIndex(for: location)
            if let cached = lineCache[idx] { return cached }
            let line = nsContent.substring(with: range(for: location))
            lineCache[idx] = line
            return line
        }

        mutating func line(covering range: NSRange) -> String {
            let key = RangeCacheKey(range)
            if let cached = coveringLineCache[key] { return cached }
            let line = nsContent.substring(with: self.range(covering: range))
            coveringLineCache[key] = line
            return line
        }

        mutating func trimmedLine(for location: Int) -> String {
            let idx = lineIndex(for: location)
            if let cached = trimmedCache[idx] { return cached }
            let trimmed = line(for: location).trimmingCharacters(in: .whitespacesAndNewlines)
            trimmedCache[idx] = trimmed
            return trimmed
        }

        mutating func trimmedLine(covering range: NSRange) -> String {
            let key = RangeCacheKey(range)
            if let cached = coveringTrimmedCache[key] { return cached }
            let trimmed = line(covering: range).trimmingCharacters(in: .whitespacesAndNewlines)
            coveringTrimmedCache[key] = trimmed
            return trimmed
        }
    }

    /// Checks if inner range is fully contained within outer range
    private static func rangeContains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location &&
            NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// Determines if a language should skip synthetic main class creation
    private static func shouldSkipSyntheticMainClass(for language: LanguageType) -> Bool {
        switch language {
        case .swift, .ts, .tsx, .js, .c, .cpp, .go, .rust, .python, .php, .ruby, .dart:
            true // These languages should populate functions[] and globalVars[] directly
        default:
            false
        }
    }

    private struct GenerationOutput {
        let imports: [String]
        let exports: [String]
        let enums: [EnumInfo]
        let aliases: [TypeAliasInfo]
        let literalUnions: [String]
        let macros: [String]
        let referencedTypes: [String]
        let globalFunctions: [FunctionInfo]
        let globalVariables: [VariableInfo]
        let classesByLine: [Int: ClassInfo]
        let interfacesByLine: [Int: InterfaceInfo]
    }

    static func generateSyntaxArtifact(
        from namedRanges: [NamedRange],
        content: String,
        language: LanguageType,
        perfOptions: CodeMapPerfOptions = .disabled,
        perfStats: CodeMapPerfStats? = nil
    ) -> CodeMapSyntaxArtifact? {
        let output = extractCodeMap(
            from: namedRanges,
            content: content,
            language: language,
            terminator: declarationTerminator(for: language),
            perfOptions: perfOptions,
            perfStats: perfStats
        )
        return makeSyntaxArtifact(from: output)
    }

    private static func declarationTerminator(for language: LanguageType) -> Character {
        switch language {
        case .python: ":"
        case .ruby: "\0"
        default: "{"
        }
    }

    private static func extractCodeMap(
        from namedRanges: [NamedRange],
        content: String,
        language supportedLanguage: LanguageType,
        terminator: Character,
        perfOptions: CodeMapPerfOptions,
        perfStats: CodeMapPerfStats?
    ) -> GenerationOutput {
        // ------------------------------------------------------------------
        // 0) Early setup & helpers
        // ------------------------------------------------------------------
        let isLightweightLang = SyntaxManager.isLightweight(language: supportedLanguage)

        // BUG FIX #1: Split TS/TSX from JS for proper routing
        let isTSLike = (supportedLanguage == .ts || supportedLanguage == .tsx)
        let isJSLike = (supportedLanguage == .js)
        let isJSTS = isTSLike || isJSLike // For string-based heuristics

        if debugLogging {
            print("🔍 [CodeMapGenerator] Starting code map generation")
            print("🏷️  Explicit language: \(supportedLanguage)")
            print("⚡️ Lightweight mode: \(isLightweightLang)")
            print("🎯 Terminator: '\(terminator)'")
            print("📊 Total named ranges: \(namedRanges.count)")
            print("📏 Content length: \(content.count) characters")
            print("📝 Content line count: \(content.components(separatedBy: .newlines).count)")
            print("📘 isTSLike: \(isTSLike), isJSLike: \(isJSLike)")
        }

        let nsContent = content as NSString
        let boundaries = computeLineBoundaries(content: content)
        let contentLength = nsContent.length
        var lineCache = LineCache(nsContent: nsContent, boundaries: boundaries, contentLength: contentLength)
        var extractionMemo = CodeMapExtractionMemo()
        let activePerfOptions = CodeMapPerfRuntime.activeOptions(perfOptions)
        let activePerfStats = CodeMapPerfRuntime.activeStats(perfStats)
        let perfEnabled = activePerfOptions.enabled
        let perfCollectCounters = activePerfOptions.collectCounters

        // Build capture index for efficient lookups
        let indexToken = Signpost.begin("codemap.index")
        let indexStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let captureIndex = CodeMapCaptureIndex(namedRanges)
        if perfEnabled {
            activePerfStats?.captureIndexDuration += (CFAbsoluteTimeGetCurrent() - indexStart)
        }
        let sortedCaps = captureIndex.all
        Signpost.end("codemap.index", indexToken)

        if debugLogging {
            print("🗂️  Line boundaries computed: \(boundaries.count) lines")
            print("🔄 Named ranges indexed: \(sortedCaps.count) captures")

            // Log all captured ranges for debugging
            print("📋 All captured ranges:")
            for (index, cap) in sortedCaps.enumerated() {
                let lineNo = lineNumber(for: cap.range.location, using: boundaries)
                let captured = substring(content: content, range: cap.range)
                print("  [\(index)] \(cap.name) @ line \(lineNo): '\(captured.prefix(50))\(captured.count > 50 ? "..." : "")'")
            }
        }

        // ------------------------------------------------------------------
        // 1)  Capture buckets
        // ------------------------------------------------------------------
        var imports: [String] = []
        var exports: [String] = []
        var enums: [EnumInfo] = []
        var aliases: [TypeAliasInfo] = []
        var literalUnions: [String] = []
        var macros: [String] = []
        var referencedTypes = ReferencedTypesAccumulator(language: supportedLanguage, stats: activePerfStats, perfOptions: activePerfOptions)
        var globalFunctions: [FunctionInfo] = []
        var globalVariables: [VariableInfo] = []
        var classesByLine: [Int: ClassInfo] = [:]
        var interfaceBoundaries: [Int: InterfaceInfo] = [:] // key = startLine

        var processedVarLines = Set<Int>()
        var processedMultiVarKeys = Set<String>()
        var processedFunctionLines = Set<Int>() // Track function lines to avoid duplicate arrow functions
        var currentEnum: EnumInfo? = nil
        var seenImportExport = Set<String>()

        // ------------------------------------------------------------------
        // 2)  Build class boundaries only (interfaces ≠ classes)
        // ------------------------------------------------------------------
        struct ClassBoundary { let startLine: Int
            let name: String
            let range: NSRange?
        }
        var classBoundaries: [ClassBoundary] = []
        var usesRangeContainmentForClasses = false

        if debugLogging {
            print("\n🏗️  [Phase 2] Building class boundaries and interfaces")
        }

        // — real classes (skip for Swift and TS/TSX - they use range-based strategies) —
        if supportedLanguage != .swift, !isTSLike {
            // Prefer range-based class boundaries when available
            let classDeclCaps = captureIndex.captures(named: "type.class.decl")
            let enumDeclCaps = captureIndex.captures(named: "type.enum.decl")
            var declCaps: [NamedRange] = []
            declCaps.reserveCapacity(classDeclCaps.count + enumDeclCaps.count)
            declCaps.append(contentsOf: classDeclCaps)
            declCaps.append(contentsOf: enumDeclCaps)
            if !declCaps.isEmpty {
                usesRangeContainmentForClasses = true
                for cap in declCaps {
                    // Find the name within this declaration
                    let nameCap =
                        captureIndex.firstCapture(named: "type.class", containedIn: cap.range) ??
                        captureIndex.firstCapture(named: "class", containedIn: cap.range) ??
                        captureIndex.firstCapture(named: "type.struct", containedIn: cap.range) ??
                        captureIndex.firstCapture(named: "type.trait", containedIn: cap.range) ??
                        captureIndex.firstCapture(named: "type.enum", containedIn: cap.range)
                    guard let resolvedName = nameCap.map({ substring(content: content, range: $0.range) }),
                          !resolvedName.isEmpty
                    else { continue }
                    let ln = lineNumber(for: cap.range.location, using: boundaries)
                    classBoundaries.append(.init(startLine: ln, name: resolvedName, range: cap.range))
                    if debugLogging {
                        print("🏛️  Found class (range): '\(resolvedName)' at line \(ln)")
                    }
                }
            } else {
                for cap in sortedCaps where cap.name == "class" || cap.name == "type.class" || cap.name == "type.struct" || cap.name == "type.trait" {
                    let ln = lineNumber(for: cap.range.location, using: boundaries)
                    let cls = substring(content: content, range: cap.range)
                    classBoundaries.append(.init(startLine: ln, name: cls, range: nil))
                    if debugLogging {
                        print("🏛️  Found class: '\(cls)' at line \(ln)")
                    }
                }
            }
        }

        // ------------------------------------------------------------------
        // 2b) Python enum declaration ranges (for routing enum members)
        // ------------------------------------------------------------------
        var pythonEnumDecls: [(range: NSRange, name: String)] = []
        if supportedLanguage == .python {
            for decl in captureIndex.captures(named: "type.class.decl") {
                let declLine = lineCache.line(for: decl.range.location)
                if !RegexCache.pythonEnumClass.matches(declLine) {
                    continue
                }
                if let nameCap = captureIndex.firstCapture(named: "type.class", containedIn: decl.range) {
                    let name = substring(content: content, range: nameCap.range)
                    if !name.isEmpty {
                        pythonEnumDecls.append((range: decl.range, name: name))
                    }
                }
            }
        }
        let pythonEnumDeclsByRange = pythonEnumDecls.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            return lhs.range.length < rhs.range.length
        }
        func pythonEnumName(containing range: NSRange) -> String? {
            let endIdx = binarySearchFirstFalse(count: pythonEnumDeclsByRange.count) { idx in
                pythonEnumDeclsByRange[idx].range.location <= range.location
            }
            guard endIdx > 0 else { return nil }

            var best: (range: NSRange, name: String)? = nil
            for i in stride(from: endIdx - 1, through: 0, by: -1) {
                let decl = pythonEnumDeclsByRange[i]
                if rangeContains(decl.range, range), best == nil || isBetterRange(decl.range, than: best!.range) {
                    best = decl
                }
            }
            return best?.name
        }

        // — interfaces recorded separately (skip for TS/TSX - handled by strategy) —
        struct InterfaceBoundary { let startLine: Int
            let name: String
            let range: NSRange?
        }
        var interfaceBoundaryList: [InterfaceBoundary] = []
        var usesRangeContainmentForInterfaces = false

        if !isTSLike {
            let interfaceDeclCaps = captureIndex.captures(named: "type.interface.decl")
            if !interfaceDeclCaps.isEmpty {
                usesRangeContainmentForInterfaces = true
                for cap in interfaceDeclCaps {
                    let nameCap =
                        captureIndex.firstCapture(named: "type.interface", containedIn: cap.range) ??
                        captureIndex.firstCapture(named: "interface", containedIn: cap.range)
                    guard let resolvedName = nameCap.map({ substring(content: content, range: $0.range) }),
                          !resolvedName.isEmpty
                    else { continue }
                    let ln = lineNumber(for: cap.range.location, using: boundaries)
                    interfaceBoundaries[ln] = InterfaceInfo(name: resolvedName, properties: [], methods: [])
                    interfaceBoundaryList.append(.init(startLine: ln, name: resolvedName, range: cap.range))
                    if debugLogging {
                        print("🔌 Found interface (range) '\(resolvedName)' at line \(ln)")
                    }
                }
            } else {
                for cap in sortedCaps where cap.name == "interface" || cap.name == "type.interface" {
                    let ln = lineNumber(for: cap.range.location, using: boundaries)
                    let name = substring(content: content, range: cap.range)
                    interfaceBoundaries[ln] = InterfaceInfo(name: name, properties: [], methods: [])
                    interfaceBoundaryList.append(.init(startLine: ln, name: name, range: nil))
                    if debugLogging {
                        print("🔌 Found interface '\(name)' at line \(ln)")
                    }
                }
            }
        }

        classBoundaries.sort { $0.startLine < $1.startLine }
        for b in classBoundaries {
            classesByLine[b.startLine] = ClassInfo(name: b.name, methods: [], properties: [])
        }

        struct RustImplBoundary { let range: NSRange
            let targetTypeName: String
            let startLine: Int
        }
        var rustImplBoundaries: [RustImplBoundary] = []
        var rustStructNames: Set<String> = []
        if supportedLanguage == .rust {
            rustStructNames = Set(
                captureIndex.captures(named: "type.struct")
                    .map { substring(content: content, range: $0.range) }
            )
            for decl in captureIndex.captures(named: "rust.impl.decl") {
                guard let nameCap = captureIndex.firstCapture(named: "rust.impl.type", containedIn: decl.range) else { continue }
                let targetName = substring(content: content, range: nameCap.range)
                if targetName.isEmpty { continue }
                let ln = lineNumber(for: decl.range.location, using: boundaries)
                rustImplBoundaries.append(.init(range: decl.range, targetTypeName: targetName, startLine: ln))
            }
        }

        if !interfaceBoundaryList.isEmpty {
            interfaceBoundaryList.sort { $0.startLine < $1.startLine }
        }
        let classBoundariesByRange = classBoundaries.filter { $0.range != nil }.sorted { lhs, rhs in
            let lhsRange = lhs.range!
            let rhsRange = rhs.range!
            if lhsRange.location != rhsRange.location { return lhsRange.location < rhsRange.location }
            return lhsRange.length < rhsRange.length
        }
        let interfaceBoundaryListByRange = interfaceBoundaryList.filter { $0.range != nil }.sorted { lhs, rhs in
            let lhsRange = lhs.range!
            let rhsRange = rhs.range!
            if lhsRange.location != rhsRange.location { return lhsRange.location < rhsRange.location }
            return lhsRange.length < rhsRange.length
        }
        let rustImplBoundariesByRange = rustImplBoundaries.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            return lhs.range.length < rhs.range.length
        }

        if debugLogging {
            print("📊 Class boundaries summary:")
            print("   • Classes found: \(classBoundaries.count)")
            print("   • Interfaces found: \(interfaceBoundaries.count)")
            if !classBoundaries.isEmpty {
                print("   • Class order by line:")
                for b in classBoundaries {
                    print("     - '\(b.name)' @ line \(b.startLine)")
                }
            }
        }

        func enclosingBoundary(for range: NSRange, line: Int) -> ClassBoundary? {
            if usesRangeContainmentForClasses {
                let endIdx = binarySearchFirstFalse(count: classBoundariesByRange.count) { idx in
                    (classBoundariesByRange[idx].range?.location ?? Int.max) <= range.location
                }
                guard endIdx > 0 else { return nil }

                var best: ClassBoundary? = nil
                for i in stride(from: endIdx - 1, through: 0, by: -1) {
                    let b = classBoundariesByRange[i]
                    guard let bRange = b.range else { continue }
                    if rangeContains(bRange, range), best == nil || isBetterRange(bRange, than: best!.range!) {
                        best = b
                    }
                }
                return best
            }
            let idx = binarySearchFirstFalse(count: classBoundaries.count) { classBoundaries[$0].startLine <= line }
            return idx > 0 ? classBoundaries[idx - 1] : nil
        }

        func enclosingInterface(for range: NSRange, line: Int) -> InterfaceBoundary? {
            if usesRangeContainmentForInterfaces {
                let endIdx = binarySearchFirstFalse(count: interfaceBoundaryListByRange.count) { idx in
                    (interfaceBoundaryListByRange[idx].range?.location ?? Int.max) <= range.location
                }
                guard endIdx > 0 else { return nil }

                var best: InterfaceBoundary? = nil
                for i in stride(from: endIdx - 1, through: 0, by: -1) {
                    let b = interfaceBoundaryListByRange[i]
                    guard let bRange = b.range else { continue }
                    if rangeContains(bRange, range), best == nil || isBetterRange(bRange, than: best!.range!) {
                        best = b
                    }
                }
                return best
            }
            // Only return an interface if we're within a very close range
            // TypeScript interfaces are typically compact
            let idx = binarySearchFirstFalse(count: interfaceBoundaryList.count) { interfaceBoundaryList[$0].startLine <= line }
            let candidate: InterfaceBoundary?
            if idx > 0 {
                let b = interfaceBoundaryList[idx - 1]
                candidate = (line - b.startLine <= 30) ? b : nil
            } else {
                candidate = nil
            }
            if debugLogging, let c = candidate {
                print("   🔍 Line \(line) might be in interface '\(c.name)' starting at line \(c.startLine)")
            }
            return candidate
        }

        func enclosingRustImplBoundary(for range: NSRange) -> RustImplBoundary? {
            let endIdx = binarySearchFirstFalse(count: rustImplBoundariesByRange.count) { idx in
                rustImplBoundariesByRange[idx].range.location <= range.location
            }
            guard endIdx > 0 else { return nil }

            var best: RustImplBoundary? = nil
            for i in stride(from: endIdx - 1, through: 0, by: -1) {
                let b = rustImplBoundariesByRange[i]
                if rangeContains(b.range, range), best == nil || isBetterRange(b.range, than: best!.range) {
                    best = b
                }
            }
            return best
        }

        func classKey(forTypeName name: String) -> Int? {
            classesByLine.first(where: { $0.value.name == name })?.key
        }

        func simpleIdentifier(from text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return Self.firstRegexGroup(RegexCache.simpleIdentifier, in: trimmed)
        }

        func goReceiverType(from decl: String) -> String? {
            if let receiver = Self.firstRegexGroup(RegexCache.goReceiverType, in: decl) {
                let tokens = receiver.split(whereSeparator: { $0.isWhitespace })
                guard let last = tokens.last else { return nil }
                var typeToken = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
                typeToken = typeToken.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                if let bracket = typeToken.firstIndex(of: "[") {
                    typeToken = String(typeToken[..<bracket])
                }
                if let dot = typeToken.split(separator: ".").last {
                    typeToken = String(dot)
                }
                return typeToken.isEmpty ? nil : typeToken
            }
            return nil
        }

        // ------------------------------------------------------------------
        // 2.5) Swift-specific: Build type boundaries with full ranges (via strategy)
        // ------------------------------------------------------------------
        var swiftContext: SwiftCodeMapStrategy.Context? = nil

        if supportedLanguage == .swift {
            if debugLogging {
                print("\n🍎 [Phase 2.5] Swift-specific: Building range-based type boundaries via strategy")
            }
            let swiftToken = Signpost.begin("codemap.swift_context")
            let swiftContextStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            swiftContext = SwiftCodeMapStrategy.buildContext(
                index: captureIndex,
                content: content,
                boundaries: boundaries
            )
            if perfEnabled {
                activePerfStats?.swiftContextDuration += (CFAbsoluteTimeGetCurrent() - swiftContextStart)
            }
            Signpost.end("codemap.swift_context", swiftToken)

            // Also populate interfaceBoundaries for protocols
            for boundary in swiftContext!.typeBoundaries where boundary.isProtocol {
                interfaceBoundaries[boundary.startLine] = InterfaceInfo(name: boundary.name, properties: [], methods: [])
            }

            if debugLogging {
                print("   🍎 Built \(swiftContext!.typeBoundaries.count) Swift type boundaries")
            }
        }

        // ------------------------------------------------------------------
        // 2.6) TS/TSX-specific: Build container boundaries (via strategy)
        //      BUG FIX #1: Only for TS/TSX, NOT for JS
        // ------------------------------------------------------------------
        var tsContext: TypeScriptCodeMapStrategy.Context? = nil
        var usesTSRangeContainment = false

        if isTSLike {
            if debugLogging {
                print("\n📘 [Phase 2.6] TS/TSX-specific: Building range-based container boundaries via strategy")
            }
            let tsToken = Signpost.begin("codemap.ts_context")
            let tsContextStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            tsContext = TypeScriptCodeMapStrategy.buildContext(
                index: captureIndex,
                content: content,
                boundaries: boundaries
            )
            if perfEnabled {
                activePerfStats?.tsContextDuration += (CFAbsoluteTimeGetCurrent() - tsContextStart)
            }
            Signpost.end("codemap.ts_context", tsToken)

            usesTSRangeContainment = TypeScriptCodeMapStrategy.useRangeContainment(tsContext!)

            // Also populate classesByLine and interfaceBoundaries for compatibility
            for boundary in tsContext!.containerBoundaries {
                switch boundary.kind {
                case .class:
                    if classesByLine[boundary.startLine] == nil {
                        classesByLine[boundary.startLine] = ClassInfo(name: boundary.name, methods: [], properties: [])
                    }
                case .interface:
                    if interfaceBoundaries[boundary.startLine] == nil {
                        interfaceBoundaries[boundary.startLine] = InterfaceInfo(name: boundary.name, properties: [], methods: [])
                    }
                }
            }

            if debugLogging {
                print("   📘 Built \(tsContext!.containerBoundaries.count) TS container boundaries")
                print("   📘 usesTSRangeContainment: \(usesTSRangeContainment)")
            }
        }

        // ------------------------------------------------------------------
        // Capture declaration helper (closure for strategies)
        // ------------------------------------------------------------------
        let captureDecl: (NSRange, Character) -> String = { range, term in
            captureDeclaration(
                nsContent: nsContent,
                for: range,
                lineRange: lineCache.range(covering: range),
                terminator: term,
                jsTsContext: nil,
                perfStats: activePerfStats,
                perfOptions: activePerfOptions
            )
        }

        // ------------------------------------------------------------------
        // 3)  Main capture loop
        // ------------------------------------------------------------------
        if debugLogging {
            print("\n🔄 [Phase 3] Processing captures in main loop")
        }

        let loopToken = Signpost.begin("codemap.capture_loop")
        let loopStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        func recordCaptureAttribution(_ category: CaptureLoopAttributionCategory, since start: CFAbsoluteTime) {
            guard perfEnabled else { return }
            Self.recordCaptureLoopAttribution(
                category: category,
                duration: CFAbsoluteTimeGetCurrent() - start,
                collectCounters: perfCollectCounters,
                perfStats: activePerfStats
            )
        }
        func recordFallbackFunctionAttribution(_ category: FallbackFunctionAttributionCategory, since start: CFAbsoluteTime) {
            guard perfEnabled else { return }
            Self.recordFallbackFunctionAttribution(
                category: category,
                duration: CFAbsoluteTimeGetCurrent() - start,
                collectCounters: perfCollectCounters,
                perfStats: activePerfStats
            )
        }
        var currentLineIndex = 0
        let lineCount = boundaries.count
        for cap in sortedCaps {
            if perfCollectCounters {
                activePerfStats?.capturesProcessed += 1
            }
            var handledByStrategy = false
            let location = cap.range.location
            let lineAdvanceStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            while currentLineIndex + 1 < lineCount,
                  boundaries[currentLineIndex + 1] <= location
            {
                currentLineIndex += 1
            }
            let lineNo = currentLineIndex + 1
            if perfEnabled {
                Self.recordCaptureLoopLineAdvance(
                    duration: CFAbsoluteTimeGetCurrent() - lineAdvanceStart,
                    collectCounters: perfCollectCounters,
                    perfStats: activePerfStats
                )
            }
            let attributionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0

            if debugLogging {
                let captured = substring(content: content, range: cap.range)
                print("\n🎯 Processing capture: '\(cap.name)' @ line \(lineNo)")
                print("   📝 Raw captured: '\(captured.prefix(100))\(captured.count > 100 ? "..." : "")'")
            }

            // ------------------------------------------------------------------
            // Swift-specific routing (via strategy)
            // ------------------------------------------------------------------
            if supportedLanguage == .swift, let ctx = swiftContext {
                let handled = SwiftCodeMapStrategy.handleCapture(
                    cap,
                    context: ctx,
                    index: captureIndex,
                    content: content,
                    nsContent: nsContent,
                    boundaries: boundaries,
                    lineNo: lineNo,
                    classesByLine: &classesByLine,
                    interfaceBoundaries: &interfaceBoundaries,
                    globalFunctions: &globalFunctions,
                    globalVariables: &globalVariables,
                    referencedTypes: &referencedTypes,
                    captureDeclaration: captureDecl,
                    perfStats: activePerfStats
                )
                if handled {
                    if debugLogging {
                        print("   🍎 Handled by SwiftCodeMapStrategy")
                    }
                    if perfCollectCounters {
                        activePerfStats?.swiftStrategyHandled += 1
                    }
                    handledByStrategy = true
                    recordCaptureAttribution(.swiftStrategy, since: attributionStart)
                    continue
                }
            }

            // ------------------------------------------------------------------
            // TS/TSX-specific routing (via strategy)
            // BUG FIX #1: Only route TS/TSX through this, NOT JS
            // ------------------------------------------------------------------
            if isTSLike, let ctx = tsContext, usesTSRangeContainment {
                let handled = TypeScriptCodeMapStrategy.handleCapture(
                    cap,
                    context: ctx,
                    index: captureIndex,
                    content: content,
                    nsContent: nsContent,
                    boundaries: boundaries,
                    lineNo: lineNo,
                    language: supportedLanguage,
                    getTrimmedLine: { range in
                        lineCache.trimmedLine(covering: range)
                    },
                    classesByLine: &classesByLine,
                    interfaceBoundaries: &interfaceBoundaries,
                    globalFunctions: &globalFunctions,
                    globalVariables: &globalVariables,
                    referencedTypes: &referencedTypes,
                    extractionMemo: &extractionMemo,
                    perfStats: activePerfStats,
                    perfOptions: activePerfOptions
                )
                if handled {
                    if debugLogging {
                        print("   📘 Handled by TypeScriptCodeMapStrategy")
                    }
                    if perfCollectCounters {
                        activePerfStats?.tsStrategyHandled += 1
                    }
                    handledByStrategy = true
                    recordCaptureAttribution(.tsStrategy, since: attributionStart)
                    continue
                }
            }

            if perfCollectCounters, !handledByStrategy {
                activePerfStats?.fallbackHandled += 1
            }
            // — FIRST, are we sitting inside an interface? ————————————————
            // BUG FIX #2: Gate the line-based heuristic for TS/TSX when using range containment
            if !usesTSRangeContainment, let ifaceBoundary = enclosingInterface(for: cap.range, line: lineNo) {
                // Only process specific captures that are known to be interface members
                switch cap.name {
                case "method_signature", "call_signature":
                    // These are definitely interface method signatures
                    let decl = captureDeclaration(
                        nsContent: nsContent,
                        for: cap.range,
                        lineRange: lineCache.range(covering: cap.range),
                        terminator: terminator,
                        jsTsContext: nil,
                        perfStats: activePerfStats,
                        perfOptions: activePerfOptions
                    )
                    let fnLine = lineNo
                    interfaceBoundaries[ifaceBoundary.startLine]?.methods.append(
                        FunctionInfo(
                            name: decl,
                            parameters: [],
                            returnType: nil,
                            definitionLine: decl,
                            lineNumber: fnLine
                        )
                    )
                    if debugLogging {
                        print("   ✅ Added method signature '\(decl)' to interface at line \(ifaceBoundary.startLine)")
                    }
                    recordCaptureAttribution(.interfaceHeuristic, since: attributionStart)
                    continue

                case "property_signature":
                    // These are definitely interface property signatures
                    let decl = captureDeclaration(
                        nsContent: nsContent,
                        for: cap.range,
                        lineRange: lineCache.range(covering: cap.range),
                        terminator: terminator,
                        jsTsContext: nil,
                        perfStats: activePerfStats,
                        perfOptions: activePerfOptions
                    )
                    interfaceBoundaries[ifaceBoundary.startLine]?.properties.append(
                        PropertyInfo(
                            name: decl,
                            typeName: nil
                        )
                    )
                    if debugLogging {
                        print("   ✅ Added property signature '\(decl)' to interface at line \(ifaceBoundary.startLine)")
                    }
                    recordCaptureAttribution(.interfaceHeuristic, since: attributionStart)
                    continue

                default:
                    // For other captures, don't assume they're interface members
                    if debugLogging {
                        print("   🤔 Capture '\(cap.name)' near interface but not a known interface member type")
                    }
                }
            }

            switch cap.name {
            // -------- imports / exports ------------------------------------
            case "import", "import.module", "import.namespace":
                let fullLine = lineCache.trimmedLine(covering: cap.range)
                if !seenImportExport.contains(fullLine) {
                    imports.append(fullLine)
                    seenImportExport.insert(fullLine)
                    if debugLogging {
                        print("   ✅ Added import: '\(fullLine)'")
                    }
                } else if debugLogging {
                    print("   ⏭️  Skipped duplicate import: '\(fullLine)'")
                }
                recordCaptureAttribution(.importExport, since: attributionStart)

            case "export", "export.source":
                // Use only the line at cap.range.location to avoid multi-line spans (e.g., "export class Foo { ... }")
                let fullLine = lineCache.trimmedLine(for: cap.range.location)
                if !seenImportExport.contains(fullLine) {
                    exports.append(fullLine)
                    seenImportExport.insert(fullLine)
                    if debugLogging {
                        print("   ✅ Added export: '\(fullLine)'")
                    }
                } else if debugLogging {
                    print("   ⏭️  Skipped duplicate export: '\(fullLine)'")
                }
                recordCaptureAttribution(.importExport, since: attributionStart)

            // -------- type‑aliases ----------------------------------------
            case "typeAlias":
                // BUG FIX #4: Use statementLike context for type aliases
                let decl: String
                if isJSTS {
                    let rawDecl = captureDeclaration(
                        nsContent: nsContent,
                        for: cap.range,
                        lineRange: lineCache.range(covering: cap.range),
                        terminator: terminator,
                        jsTsContext: .statementLike,
                        returnRawJSTS: true,
                        perfStats: activePerfStats,
                        perfOptions: activePerfOptions
                    )
                    decl = extractionMemo.jstsSignature(
                        from: rawDecl,
                        context: .statementLike,
                        perfStats: activePerfStats,
                        perfOptions: activePerfOptions
                    )
                } else {
                    decl = captureDeclaration(
                        nsContent: nsContent,
                        for: cap.range,
                        lineRange: lineCache.range(covering: cap.range),
                        terminator: terminator,
                        jsTsContext: nil,
                        perfStats: activePerfStats,
                        perfOptions: activePerfOptions
                    )
                }

                // Detect trivial literal‑union alias   (e.g. `'a' | 'b' | 'c'`)
                if decl.contains("'"), decl.contains("|") {
                    literalUnions.append(decl)
                    if debugLogging {
                        print("   ✅ Added literal union: '\(decl)'")
                    }
                } else {
                    let aliasName = substring(content: content, range: cap.range)
                    aliases.append(TypeAliasInfo(name: aliasName, definitionLine: decl))
                    if debugLogging {
                        print("   ✅ Added type alias: '\(aliasName)' -> '\(decl)'")
                    }
                }

                if isTSLike, let rhs = extractionMemo.tsTypeAliasRHS(from: decl, stats: activePerfStats) {
                    activePerfStats?.tsTypeAliasRhsFastPathHits += 1
                    referencedTypes.insert(rawType: rhs)
                }
                recordCaptureAttribution(.typeAlias, since: attributionStart)

            // -------- enums ------------------------------------------------
            case "type.enum":
                if supportedLanguage == .python {
                    recordCaptureAttribution(.enumMacro, since: attributionStart)
                    continue
                }
                let enumName = substring(content: content, range: cap.range)
                if let e = currentEnum, e.name.isEmpty, !e.cases.isEmpty {
                    currentEnum = EnumInfo(name: enumName, cases: e.cases)
                    if debugLogging {
                        print("   🏷️  Assigned enum name '\(enumName)' to pending cases (\(e.cases.count))")
                    }
                    recordCaptureAttribution(.enumMacro, since: attributionStart)
                    continue
                }
                if let e = currentEnum {
                    enums.append(e)
                    if debugLogging {
                        print("   📦 Finalized previous enum: '\(e.name)' with \(e.cases.count) cases")
                    }
                }
                currentEnum = EnumInfo(name: enumName, cases: [])
                if debugLogging {
                    print("   🆕 Started new enum: '\(enumName)'")
                }
                recordCaptureAttribution(.enumMacro, since: attributionStart)

            case "enum.entry":
                let entry = substring(content: content, range: cap.range)
                if currentEnum != nil {
                    currentEnum!.cases.append(entry)
                    if debugLogging {
                        print("   ➕ Added enum case: '\(entry)' to '\(currentEnum?.name ?? "unknown")'")
                    }
                } else {
                    currentEnum = EnumInfo(name: "", cases: [entry])
                    if debugLogging {
                        print("   🆕 Started anonymous enum with case: '\(entry)'")
                    }
                }
                recordCaptureAttribution(.enumMacro, since: attributionStart)

            // -------- functions / methods (generic, non-Swift) ---------------
            case "function.definition", "function.declaration", "function", "method":
                // Skip legacy function captures for Swift - we use SwiftCodeMapStrategy
                if supportedLanguage == .swift {
                    recordFallbackFunctionAttribution(.skipped, since: attributionStart)
                    recordCaptureAttribution(.function, since: attributionStart)
                    continue
                }

                // Skip for TS/TSX if using range containment - strategy handles these
                if isTSLike && usesTSRangeContainment && cap.name == "method" {
                    recordFallbackFunctionAttribution(.skipped, since: attributionStart)
                    recordCaptureAttribution(.function, since: attributionStart)
                    continue
                }

                // Track this line as processed for functions
                let lnRange = lineCache.range(for: cap.range.location)
                processedFunctionLines.insert(lnRange.location)

                // For TS/TSX arrow functions, the capture is on the identifier - use it as the name
                // For other function types, the capture may be on a larger node
                let capturedText = substring(content: content, range: cap.range)
                let rawDecl: String
                let declarationStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                if isJSTS {
                    rawDecl = captureDeclaration(
                        nsContent: nsContent,
                        for: cap.range,
                        lineRange: lineCache.range(covering: cap.range),
                        terminator: terminator,
                        jsTsContext: .functionLike,
                        returnRawJSTS: true,
                        perfStats: activePerfStats,
                        perfOptions: activePerfOptions
                    )
                } else {
                    rawDecl = captureDeclaration(
                        nsContent: nsContent,
                        for: cap.range,
                        lineRange: lineCache.range(covering: cap.range),
                        terminator: terminator,
                        jsTsContext: nil,
                        perfStats: activePerfStats,
                        perfOptions: activePerfOptions
                    )
                }
                recordFallbackFunctionAttribution(.declaration, since: declarationStart)
                // BUG FIX #4: Use functionLike context for function declarations
                var decl: String
                if isJSTS {
                    let jstsSignatureStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                    decl = extractionMemo.jstsSignature(
                        from: rawDecl,
                        context: .functionLike,
                        perfStats: activePerfStats,
                        perfOptions: activePerfOptions
                    )
                    recordFallbackFunctionAttribution(.jstsSignature, since: jstsSignatureStart)
                    let trimmedDecl = decl.trimmingCharacters(in: .whitespacesAndNewlines)
                    let tsFastPathStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                    if trimmedDecl.hasSuffix(":"),
                       let rt = extractionMemo.tsReturnType(from: rawDecl, stats: activePerfStats),
                       !rt.isEmpty
                    {
                        decl = trimmedDecl + " " + rt
                    }
                    recordFallbackFunctionAttribution(.tsFastPath, since: tsFastPathStart)
                } else {
                    decl = rawDecl
                }

                if debugLogging {
                    print("   🔧 Function/method declaration: '\(decl.prefix(150))\(decl.count > 150 ? "..." : "")'")
                    print("   📝 Captured text: '\(capturedText)'")
                }

                // ⚡️ Fast path for lightweight languages: no heavy regex
                if isLightweightLang {
                    if perfCollectCounters {
                        activePerfStats?.fallbackFunctionLightweightCount += 1
                    }
                    let rawLine = lineCache.line(for: cap.range.location)
                    // For TS/TSX, extract a clean function name using robust regex
                    let nameExtractionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                    var fnName: String
                    if isJSTS {
                        fnName = extractJSTSFunctionName(captureText: capturedText, decl: decl)
                    } else {
                        let trimmedCaptured = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedCaptured.isEmpty,
                           !containsWhitespace(trimmedCaptured)
                        {
                            fnName = trimmedCaptured
                        } else {
                            fnName = decl
                        }
                    }
                    recordFallbackFunctionAttribution(.nameExtraction, since: nameExtractionStart)

                    var returnType: String? = nil
                    var params: [ParameterInfo] = []

                    let lightweightMatch: [String: String]?
                    if isTSLike {
                        let lteParseStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                        lightweightMatch = extractionMemo.matchFunctionLine(decl, language: supportedLanguage, stats: activePerfStats)
                        recordFallbackFunctionAttribution(.lteParse, since: lteParseStart)
                    } else {
                        lightweightMatch = nil
                    }
                    if let match = lightweightMatch {
                        if let n = match["name"], !n.isEmpty { fnName = n }
                        if let rt = match["returnType"], !rt.isEmpty {
                            returnType = rt
                            let refsStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                            referencedTypes.insert(rawType: rt)
                            recordFallbackFunctionAttribution(.referencedTypes, since: refsStart)
                        }
                        if let pt = match["parameterTypes"], !pt.isEmpty {
                            let types = pt
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                            params = types.enumerated().map {
                                ParameterInfo(
                                    externalName: nil,
                                    localName: "param\($0.offset)",
                                    typeName: $0.element
                                )
                            }
                            let refsStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                            referencedTypes.insertMany(rawTypes: types)
                            recordFallbackFunctionAttribution(.referencedTypes, since: refsStart)
                        }
                    }
                    if isTSLike, returnType == nil {
                        let tsFastPathStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                        let rawMatch = extractionMemo.matchFunctionLineParsed(rawLine, language: supportedLanguage, stats: activePerfStats)
                        recordFallbackFunctionAttribution(.tsFastPath, since: tsFastPathStart)
                        if let rawMatch, let rt = rawMatch.returnType, !rt.isEmpty {
                            returnType = rt
                            let refsStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                            referencedTypes.insert(rawType: rt)
                            recordFallbackFunctionAttribution(.referencedTypes, since: refsStart)
                        }
                    }
                    if isTSLike {
                        let tsFastPathStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                        let varMatch = extractionMemo.matchVariableLine(rawDecl, language: supportedLanguage, stats: activePerfStats)
                        recordFallbackFunctionAttribution(.tsFastPath, since: tsFastPathStart)
                        if let varMatch,
                           let vType = varMatch["type"], !vType.isEmpty
                        {
                            if returnType == nil {
                                returnType = vType
                            }
                            let refsStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                            referencedTypes.insert(rawType: vType)
                            recordFallbackFunctionAttribution(.referencedTypes, since: refsStart)
                        }
                    }

                    let modelInsertionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                    let fnLine = lineNo
                    let fnInfo = FunctionInfo(
                        name: fnName,
                        parameters: params,
                        returnType: returnType,
                        definitionLine: decl,
                        lineNumber: fnLine
                    )
                    let routingStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                    let ifaceBoundary = (!isTSLike && supportedLanguage != .swift)
                        ? enclosingInterface(for: cap.range, line: lineNo)
                        : nil
                    recordFallbackFunctionAttribution(.routing, since: routingStart)
                    if let iface = ifaceBoundary {
                        if !interfaceBoundaries[iface.startLine]!.methods.contains(where: { $0.definitionLine == decl }) {
                            interfaceBoundaries[iface.startLine]?.methods.append(fnInfo)
                            if perfCollectCounters {
                                activePerfStats?.fallbackFunctionInterfaceInsertCount += 1
                            }
                        }
                        if debugLogging {
                            print("   ⚡️ Added interface method '\(decl)' to '\(iface.name)'")
                        }
                        recordFallbackFunctionAttribution(.modelInsertion, since: modelInsertionStart)
                        recordCaptureAttribution(.function, since: attributionStart)
                        continue
                    }

                    // For JS/TS, only add to class if it's actually a method (not just any function after a class)
                    if isJSTS, cap.name == "method" {
                        // This is definitely a class method
                        let routingStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                        let boundary = enclosingBoundary(for: cap.range, line: lineNo)
                        recordFallbackFunctionAttribution(.routing, since: routingStart)
                        if let boundary {
                            if !classesByLine[boundary.startLine]!.methods.contains(where: { $0.definitionLine == decl }) {
                                classesByLine[boundary.startLine]?.methods.append(fnInfo)
                                if perfCollectCounters {
                                    activePerfStats?.fallbackFunctionMethodInsertCount += 1
                                }
                                if debugLogging {
                                    print("   ⚡️ JS/TS: Added method '\(decl)' to class '\(boundary.name)'")
                                }
                            }
                        }
                    } else if isJSTS {
                        // For JS/TS, all non-method functions are global
                        if !globalFunctions.contains(where: { $0.definitionLine == decl }) {
                            globalFunctions.append(fnInfo)
                            if perfCollectCounters {
                                activePerfStats?.fallbackFunctionGlobalInsertCount += 1
                            }
                            if debugLogging {
                                print("   ⚡️ JS/TS: Added global function '\(decl)'")
                            }
                        }
                    } else {
                        // Original logic for other languages
                        let routingStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                        let boundary = enclosingBoundary(for: cap.range, line: lineNo)
                        recordFallbackFunctionAttribution(.routing, since: routingStart)
                        if let boundary {
                            if !classesByLine[boundary.startLine]!.methods.contains(where: { $0.definitionLine == decl }) {
                                classesByLine[boundary.startLine]?.methods.append(fnInfo)
                                if perfCollectCounters {
                                    activePerfStats?.fallbackFunctionMethodInsertCount += 1
                                }
                                if debugLogging {
                                    print("   ⚡️ Lightweight: Added method '\(decl)' to class '\(boundary.name)'")
                                }
                            } else if debugLogging {
                                print("   ⏭️  Lightweight: Skipped duplicate method: '\(decl)'")
                            }
                        } else {
                            if !globalFunctions.contains(where: { $0.definitionLine == decl }) {
                                globalFunctions.append(fnInfo)
                                if perfCollectCounters {
                                    activePerfStats?.fallbackFunctionGlobalInsertCount += 1
                                }
                                if debugLogging {
                                    print("   ⚡️ Lightweight: Added global function '\(decl)'")
                                }
                            } else if debugLogging {
                                print("   ⏭️  Lightweight: Skipped duplicate global function: '\(decl)'")
                            }
                        }
                    }
                    recordFallbackFunctionAttribution(.modelInsertion, since: modelInsertionStart)
                    recordCaptureAttribution(.function, since: attributionStart)
                    continue
                }

                // Heavyweight parsing with regex extractor
                if perfCollectCounters {
                    activePerfStats?.fallbackFunctionHeavyweightCount += 1
                }
                var fnName = decl
                var returnType: String? = nil
                var paramTypes: [String] = []

                let lteParseStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                let heavyweightMatch = extractionMemo.matchFunctionLine(decl, language: supportedLanguage, stats: activePerfStats)
                recordFallbackFunctionAttribution(.lteParse, since: lteParseStart)
                if let match = heavyweightMatch {
                    if let n = match["name"], !n.isEmpty { fnName = n }
                    if let rt = match["returnType"], !rt.isEmpty {
                        returnType = rt
                        let refsStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                        referencedTypes.insert(rawType: rt)
                        recordFallbackFunctionAttribution(.referencedTypes, since: refsStart)
                    }
                    if let pt = match["parameterTypes"], !pt.isEmpty {
                        let types = pt
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                        paramTypes.append(contentsOf: types)
                        let refsStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                        referencedTypes.insertMany(rawTypes: types)
                        recordFallbackFunctionAttribution(.referencedTypes, since: refsStart)
                    }
                    if debugLogging {
                        print("   🔍 Heavyweight parsing extracted:")
                        print("      • Function name: '\(fnName)'")
                        print("      • Return type: '\(returnType ?? "none")'")
                        print("      • Parameter types: \(paramTypes)")
                    }
                } else if debugLogging {
                    print("   ⚠️  Heavyweight regex parsing failed for: '\(decl)'")
                }

                let nameExtractionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                if fnName == decl {
                    let trimmedCaptured = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedCaptured.isEmpty,
                       !containsWhitespace(trimmedCaptured)
                    {
                        fnName = trimmedCaptured
                    }
                }
                recordFallbackFunctionAttribution(.nameExtraction, since: nameExtractionStart)

                let modelInsertionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                let params = paramTypes.enumerated().map {
                    ParameterInfo(
                        externalName: nil,
                        localName: "param\($0.offset)",
                        typeName: $0.element
                    )
                }
                let fnLine = lineNo
                let fnInfo = FunctionInfo(
                    name: fnName,
                    parameters: params,
                    returnType: returnType,
                    definitionLine: decl,
                    lineNumber: fnLine
                )
                let goRoutingStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                let goReceiver = supportedLanguage == .go ? goReceiverType(from: decl) : nil
                recordFallbackFunctionAttribution(.routing, since: goRoutingStart)
                if supportedLanguage == .go, let receiverType = goReceiver {
                    let targetKey = classKey(forTypeName: receiverType) ?? lineNo
                    if classesByLine[targetKey] == nil {
                        classesByLine[targetKey] = ClassInfo(name: receiverType, methods: [], properties: [])
                    }
                    if !classesByLine[targetKey]!.methods.contains(where: { $0.definitionLine == decl }) {
                        classesByLine[targetKey]?.methods.append(fnInfo)
                        if perfCollectCounters {
                            activePerfStats?.fallbackFunctionMethodInsertCount += 1
                        }
                    }
                    recordFallbackFunctionAttribution(.modelInsertion, since: modelInsertionStart)
                    recordCaptureAttribution(.function, since: attributionStart)
                    continue
                }
                let rustRoutingStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                let rustImplBoundary = supportedLanguage == .rust ? enclosingRustImplBoundary(for: cap.range) : nil
                recordFallbackFunctionAttribution(.routing, since: rustRoutingStart)
                if supportedLanguage == .rust, let implBoundary = rustImplBoundary {
                    let targetName = implBoundary.targetTypeName
                    if rustStructNames.contains(targetName) {
                        let targetKey = classKey(forTypeName: targetName) ?? implBoundary.startLine
                        if classesByLine[targetKey] == nil {
                            classesByLine[targetKey] = ClassInfo(name: targetName, methods: [], properties: [])
                        }
                        if !classesByLine[targetKey]!.methods.contains(where: { $0.definitionLine == decl }) {
                            classesByLine[targetKey]?.methods.append(fnInfo)
                            if perfCollectCounters {
                                activePerfStats?.fallbackFunctionMethodInsertCount += 1
                            }
                        }
                    }
                    recordFallbackFunctionAttribution(.modelInsertion, since: modelInsertionStart)
                    recordCaptureAttribution(.function, since: attributionStart)
                    continue
                }
                let routingStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                let ifaceBoundary = (!isTSLike && supportedLanguage != .swift)
                    ? enclosingInterface(for: cap.range, line: lineNo)
                    : nil
                recordFallbackFunctionAttribution(.routing, since: routingStart)
                if let iface = ifaceBoundary {
                    if !interfaceBoundaries[iface.startLine]!.methods.contains(where: { $0.definitionLine == decl }) {
                        interfaceBoundaries[iface.startLine]?.methods.append(fnInfo)
                        if perfCollectCounters {
                            activePerfStats?.fallbackFunctionInterfaceInsertCount += 1
                        }
                    }
                    if debugLogging {
                        print("   ✅ Added interface method '\(fnName)' to '\(iface.name)'")
                    }
                    recordFallbackFunctionAttribution(.modelInsertion, since: modelInsertionStart)
                    recordCaptureAttribution(.function, since: attributionStart)
                    continue
                }

                // For JS/TS, use capture name to determine if it's a method
                if isJSTS, cap.name == "method" {
                    // This is definitely a class method
                    let routingStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                    let boundary = enclosingBoundary(for: cap.range, line: lineNo)
                    recordFallbackFunctionAttribution(.routing, since: routingStart)
                    if let boundary {
                        if !classesByLine[boundary.startLine]!.methods.contains(where: { $0.definitionLine == decl }) {
                            classesByLine[boundary.startLine]?.methods.append(fnInfo)
                            if perfCollectCounters {
                                activePerfStats?.fallbackFunctionMethodInsertCount += 1
                            }
                            if debugLogging {
                                print("   ✅ JS/TS: Added method '\(fnName)' to class '\(boundary.name)'")
                            }
                        }
                    }
                } else if isJSTS {
                    // For JS/TS, all non-method functions are global
                    if !globalFunctions.contains(where: { $0.definitionLine == decl }) {
                        globalFunctions.append(fnInfo)
                        if perfCollectCounters {
                            activePerfStats?.fallbackFunctionGlobalInsertCount += 1
                        }
                        if debugLogging {
                            print("   ✅ JS/TS: Added global function '\(fnName)'")
                        }
                    }
                } else {
                    // Original logic for other languages
                    let routingStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                    let boundary = enclosingBoundary(for: cap.range, line: lineNo)
                    recordFallbackFunctionAttribution(.routing, since: routingStart)
                    if let boundary {
                        // Fix 4: Strip duplicates caused by overload sets
                        if !classesByLine[boundary.startLine]!.methods.contains(where: { $0.definitionLine == decl }) {
                            classesByLine[boundary.startLine]?.methods.append(fnInfo)
                            if perfCollectCounters {
                                activePerfStats?.fallbackFunctionMethodInsertCount += 1
                            }
                            if debugLogging {
                                print("   ✅ Added method '\(fnName)' to class '\(boundary.name)'")
                            }
                        } else if debugLogging {
                            print("   ⏭️  Skipped duplicate method: '\(decl)'")
                        }
                    } else {
                        // Fix 4: Strip duplicates caused by overload sets
                        if !globalFunctions.contains(where: { $0.definitionLine == decl }) {
                            globalFunctions.append(fnInfo)
                            if perfCollectCounters {
                                activePerfStats?.fallbackFunctionGlobalInsertCount += 1
                            }
                            if debugLogging {
                                print("   ✅ Added global function '\(fnName)'")
                            }
                        } else if debugLogging {
                            print("   ⏭️  Skipped duplicate global function: '\(decl)'")
                        }
                    }
                }
                recordFallbackFunctionAttribution(.modelInsertion, since: modelInsertionStart)
                recordCaptureAttribution(.function, since: attributionStart)

            // -------- variables / fields (generic, non-Swift) ----------------
            case "variable.global", "variable.field", "field",
                 "constant.global", "constant":
                // Skip legacy variable captures for Swift - we use SwiftCodeMapStrategy
                if supportedLanguage == .swift {
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                // Python: route Enum members to enum cases
                if supportedLanguage == .python, let enumName = pythonEnumName(containing: cap.range) {
                    let rawName = substring(content: content, range: cap.range)
                    if RegexCache.upperSnakeCase.wholeMatch(in: rawName) {
                        if currentEnum?.name != enumName {
                            if let e = currentEnum {
                                enums.append(e)
                            }
                            currentEnum = EnumInfo(name: enumName, cases: [])
                        }
                        if currentEnum != nil, !currentEnum!.cases.contains(rawName) {
                            currentEnum!.cases.append(rawName)
                        }
                        recordCaptureAttribution(.variable, since: attributionStart)
                        continue
                    }
                }

                // Skip for TS/TSX if using range containment and it's a field
                if isTSLike && usesTSRangeContainment && cap.name == "variable.field" {
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                // Check if this variable is on the same line as a function (arrow function)
                let lnRange = lineCache.range(for: cap.range.location)
                let capturedText = substring(content: content, range: cap.range)
                let simpleName = simpleIdentifier(from: capturedText)
                if processedFunctionLines.contains(lnRange.location) {
                    if debugLogging {
                        print("   ⏭️  Skipped variable on function line (likely arrow function)")
                    }
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                // 🔧 Fix 1: Capture the raw line first, keep its indent, and only then trim when we store it
                let rawLine = lineCache.line(for: cap.range.location) // keep spaces
                let trimmedLine = rawLine.trimmingCharacters(in: CharacterSet.whitespaces)

                // Use rawLine for indent detection
                let indent = rawLine.prefix { $0.isWhitespace }.count
                if supportedLanguage == .ts, indent > 0 { // interface / type-literal
                    if debugLogging { print("   ⏭️  Skipped interface member") }
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                // Now get the full declaration for storage (but use rawLine for indent detection above)
                let rawDecl = captureDeclaration(
                    nsContent: nsContent,
                    for: cap.range,
                    lineRange: lineCache.range(covering: cap.range),
                    terminator: terminator,
                    jsTsContext: nil,
                    returnRawJSTS: isJSTS,
                    perfStats: activePerfStats,
                    perfOptions: activePerfOptions
                )
                let fullDecl: String
                if isJSTS {
                    let context = jstsContextForVariableDecl(rawDecl)
                    var extracted = extractionMemo.jstsSignature(
                        from: rawDecl,
                        context: context,
                        perfStats: activePerfStats,
                        perfOptions: activePerfOptions
                    )
                    if context == .statementLike {
                        extracted = JSTSSignatureExtractor.extractVariableSignature(from: extracted)
                    }
                    fullDecl = extracted
                } else {
                    fullDecl = rawDecl
                }

                // Fix 2: Ignore lines that are obviously continuations
                let trimmed = fullDecl.trimmingCharacters(in: .whitespacesAndNewlines)

                // 🔧 Fix 2: Guard against type-alias lines that sneak in
                if supportedLanguage == .ts, trimmedLine.contains("="),
                   trimmedLine.hasSuffix(";"), !trimmedLine.contains(":")
                {
                    if debugLogging { print("   ⏭️  Skipped type-alias masquerading as variable") }
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                // ⛔ 2) Skip lines that start with "type " – they're aliases already captured
                if trimmed.hasPrefix("type ") {
                    if debugLogging {
                        print("   ⏭️  Skipped type-alias in variable capture: '\(trimmed)'")
                    }
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                // ⛔ 3) Skip union/intersection continuation lines ("… |" / "… &")
                if trimmed.hasPrefix("|") || trimmed.hasPrefix("&") {
                    if debugLogging {
                        print("   ⏭️  Skipped union/intersection fragment: '\(trimmed)'")
                    }
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                let junk = [":", ","]
                if junk.contains(trimmed) {
                    if debugLogging {
                        print("   ⏭️  Skipped continuation line: '\(trimmed)'")
                    }
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                // Fix 6: Filter empty / whitespace artifacts
                if trimmed.isEmpty {
                    if debugLogging {
                        print("   ⏭️  Skipped empty artifact")
                    }
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                if debugLogging {
                    print("   🏷️  Variable/field declaration: '\(fullDecl.prefix(100))\(fullDecl.count > 100 ? "..." : "")'")
                }

                if isLightweightLang {
                    let variableName: String
                    if supportedLanguage == .ruby {
                        let trimmedCaptured = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        variableName = trimmedCaptured.isEmpty ? (simpleName ?? fullDecl) : trimmedCaptured
                    } else if isJSTS, cap.name == "variable.global" {
                        variableName = extractJSTSVariableName(from: trimmedLine)
                            ?? extractJSTSVariableName(from: fullDecl)
                            ?? simpleName
                            ?? fullDecl
                    } else {
                        variableName = simpleName ?? fullDecl
                    }
                    var typeName: String? = nil
                    if isTSLike, let match = extractionMemo.matchVariableLine(fullDecl, language: supportedLanguage, stats: activePerfStats),
                       let vType = match["type"], !vType.isEmpty
                    {
                        typeName = vType
                        referencedTypes.insert(rawType: vType)
                    }
                    let info = VariableInfo(name: variableName, typeName: typeName, definitionLine: fullDecl)

                    let ifaceBoundary = (!isTSLike && supportedLanguage != .swift)
                        ? enclosingInterface(for: cap.range, line: lineNo)
                        : nil
                    if let iface = ifaceBoundary {
                        interfaceBoundaries[iface.startLine]?.properties.append(
                            PropertyInfo(name: info.name, typeName: info.typeName)
                        )
                        if debugLogging {
                            print("   ⚡️ Added interface property '\(fullDecl)' to '\(iface.name)'")
                        }
                        recordCaptureAttribution(.variable, since: attributionStart)
                        continue
                    }

                    // Special handling for JS/TS
                    if isJSTS {
                        // Generator-side fallback: detect HOC wrappers and Object.assign
                        // that should be functions, not globalVars
                        let isFunctionValued = trimmedLine.contains("= forwardRef") ||
                            trimmedLine.contains("= memo(") ||
                            trimmedLine.contains("= React.forwardRef") ||
                            trimmedLine.contains("= React.memo(") ||
                            trimmedLine.contains("= Object.assign(")

                        if isFunctionValued, cap.name == "variable.global" {
                            // Extract the variable name from the declaration
                            // Pattern: (export )?(const|let|var) Name = ...
                            let fnName: String = if let match = firstRegexGroup(RegexCache.jstsVarNameExtract, in: trimmedLine) {
                                match
                            } else {
                                fullDecl
                            }

                            let fnLine = lineNo
                            let fnInfo = FunctionInfo(
                                name: fnName,
                                parameters: [],
                                returnType: nil,
                                definitionLine: fullDecl,
                                lineNumber: fnLine
                            )
                            if !globalFunctions.contains(where: { $0.definitionLine == fullDecl }) {
                                globalFunctions.append(fnInfo)
                                if debugLogging {
                                    print("   ⚡️ JS/TS: Reclassified HOC/Object.assign '\(fnName)' as function")
                                }
                            }
                            recordCaptureAttribution(.variable, since: attributionStart)
                            continue
                        }

                        // For JS/TS, only add to class if it's a field (variable.field capture)
                        if cap.name == "variable.field" {
                            if let bound = enclosingBoundary(for: cap.range, line: lineNo) {
                                classesByLine[bound.startLine]?.properties.append(
                                    PropertyInfo(name: info.name, typeName: info.typeName)
                                )
                                if debugLogging {
                                    print("   ⚡️ JS/TS: Added field '\(fullDecl)' to class '\(bound.name)'")
                                }
                            }
                        } else {
                            // All other variables are global
                            globalVariables.append(info)
                            if debugLogging {
                                print("   ⚡️ JS/TS: Added global variable '\(fullDecl)'")
                            }
                        }
                    } else {
                        // Original logic for other languages
                        if let bound = enclosingBoundary(for: cap.range, line: lineNo) {
                            classesByLine[bound.startLine]?.properties.append(
                                PropertyInfo(name: info.name, typeName: nil)
                            )
                            if debugLogging {
                                print("   ⚡️ Lightweight: Added property '\(fullDecl)' to class '\(bound.name)'")
                            }
                        } else {
                            globalVariables.append(info)
                            if debugLogging {
                                print("   ⚡️ Lightweight: Added global variable '\(fullDecl)'")
                            }
                        }
                    }
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                if supportedLanguage == .go || supportedLanguage == .c {
                    let keyName = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = "\(lnRange.location):\(keyName)"
                    if processedMultiVarKeys.contains(key) {
                        if debugLogging {
                            print("   ⏭️  Skipped already processed variable: '\(keyName)'")
                        }
                        recordCaptureAttribution(.variable, since: attributionStart)
                        continue
                    }
                    processedMultiVarKeys.insert(key)
                } else {
                    if processedVarLines.contains(lnRange.location) {
                        if debugLogging {
                            print("   ⏭️  Skipped already processed variable line")
                        }
                        recordCaptureAttribution(.variable, since: attributionStart)
                        continue
                    }
                    processedVarLines.insert(lnRange.location)
                }

                var matchedName: String? = nil
                if let match = extractionMemo.matchVariableLine(fullDecl, language: supportedLanguage, stats: activePerfStats) {
                    matchedName = match["name"]
                    if let vType = match["type"] {
                        referencedTypes.insert(rawType: vType)
                        if debugLogging {
                            print("   🔍 Heavyweight parsing extracted type: '\(vType)'")
                        }
                    }
                } else if debugLogging {
                    print("   ⚠️  Heavyweight variable regex parsing failed for: '\(fullDecl)'")
                }

                let variableName: String = if isJSTS, cap.name == "variable.global" {
                    extractJSTSVariableName(from: trimmedLine)
                        ?? extractJSTSVariableName(from: fullDecl)
                        ?? simpleName
                        ?? matchedName
                        ?? fullDecl
                } else if supportedLanguage == .go {
                    Self.extractGoVariableName(captureText: capturedText, decl: fullDecl)
                        ?? matchedName
                        ?? simpleName
                        ?? fullDecl
                } else if supportedLanguage == .c {
                    Self.extractCVariableName(captureText: capturedText, decl: fullDecl)
                        ?? matchedName
                        ?? simpleName
                        ?? fullDecl
                } else {
                    matchedName ?? simpleName ?? fullDecl
                }
                let varInfo = VariableInfo(name: variableName, typeName: "", definitionLine: fullDecl)
                let ifaceBoundary = (!isTSLike && supportedLanguage != .swift)
                    ? enclosingInterface(for: cap.range, line: lineNo)
                    : nil
                if let iface = ifaceBoundary {
                    interfaceBoundaries[iface.startLine]?.properties.append(
                        PropertyInfo(name: varInfo.name, typeName: varInfo.typeName)
                    )
                    if debugLogging {
                        print("   ✅ Added interface property '\(varInfo.name)' to '\(iface.name)'")
                    }
                    recordCaptureAttribution(.variable, since: attributionStart)
                    continue
                }

                // Special handling for JS/TS (heavyweight path)
                if isJSTS {
                    // For JS/TS, only add to class if it's a field (variable.field capture)
                    if cap.name == "variable.field" {
                        if let bound = enclosingBoundary(for: cap.range, line: lineNo) {
                            classesByLine[bound.startLine]?.properties.append(
                                PropertyInfo(name: varInfo.name, typeName: varInfo.typeName)
                            )
                            if debugLogging {
                                print("   ✅ JS/TS: Added field '\(varInfo.name)' to class '\(bound.name)'")
                            }
                        }
                    } else {
                        // All other variables are global
                        globalVariables.append(varInfo)
                        if debugLogging {
                            print("   ✅ JS/TS: Added global variable '\(varInfo.name)'")
                        }
                    }
                } else {
                    // Original logic for other languages
                    if let bound = enclosingBoundary(for: cap.range, line: lineNo) {
                        classesByLine[bound.startLine]?.properties.append(
                            PropertyInfo(name: varInfo.name, typeName: varInfo.typeName)
                        )
                        if debugLogging {
                            print("   ✅ Added property '\(varInfo.name)' to class '\(bound.name)'")
                        }
                    } else {
                        globalVariables.append(varInfo)
                        if debugLogging {
                            print("   ✅ Added global variable '\(varInfo.name)'")
                        }
                    }
                }
                recordCaptureAttribution(.variable, since: attributionStart)

            // -------- macros -----------------------------------------------
            case "macro":
                let macroText = substring(content: content, range: cap.range)
                macros.append(macroText)
                if debugLogging {
                    print("   ✅ Added macro: '\(macroText)'")
                }
                recordCaptureAttribution(.enumMacro, since: attributionStart)

            default:
                if debugLogging {
                    print("   ⏭️  Skipped unhandled capture type: '\(cap.name)'")
                }
                recordCaptureAttribution(.skipped, since: attributionStart)
                continue
            }
        }
        if perfEnabled {
            activePerfStats?.captureLoopDuration += (CFAbsoluteTimeGetCurrent() - loopStart)
        }
        Signpost.end("codemap.capture_loop", loopToken)
        if let e = currentEnum {
            enums.append(e)
            if debugLogging {
                print("📦 Finalized final enum: '\(e.name)' with \(e.cases.count) cases")
            }
        }

        let typeFinalizeToken = Signpost.begin("codemap.referenced_types")
        let typeFinalizeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let finalReferences = referencedTypes.finalizeSorted()
        if perfEnabled {
            activePerfStats?.referencedTypesFinalizeDuration += (CFAbsoluteTimeGetCurrent() - typeFinalizeStart)
        }
        Signpost.end("codemap.referenced_types", typeFinalizeToken)

        return GenerationOutput(
            imports: imports,
            exports: exports,
            enums: enums,
            aliases: aliases,
            literalUnions: literalUnions,
            macros: macros,
            referencedTypes: finalReferences,
            globalFunctions: globalFunctions,
            globalVariables: globalVariables,
            classesByLine: classesByLine,
            interfacesByLine: interfaceBoundaries
        )
    }

    private static func makeSyntaxArtifact(from output: GenerationOutput) -> CodeMapSyntaxArtifact? {
        let classes = finalizedClasses(output.classesByLine)
        let interfaces = finalizedInterfaces(output.interfacesByLine)
        guard hasMeaningfulContent(
            output: output,
            classes: classes,
            interfaces: interfaces,
            functions: output.globalFunctions,
            globalVars: output.globalVariables
        ) else {
            return nil
        }

        return CodeMapSyntaxArtifact(
            imports: output.imports,
            exports: output.exports,
            classes: classes,
            interfaces: interfaces,
            aliases: output.aliases,
            literalUnions: output.literalUnions,
            functions: output.globalFunctions,
            enums: output.enums,
            globalVars: output.globalVariables,
            macros: output.macros,
            referencedTypes: output.referencedTypes
        )
    }

    private static func finalizedClasses(_ classesByLine: [Int: ClassInfo]) -> [ClassInfo] {
        classesByLine.keys.sorted().compactMap { classesByLine[$0] }
            .filter { !$0.methods.isEmpty || !$0.properties.isEmpty }
    }

    private static func finalizedInterfaces(_ interfacesByLine: [Int: InterfaceInfo]) -> [InterfaceInfo] {
        interfacesByLine.keys.sorted().compactMap { interfacesByLine[$0] }
            .filter { !$0.methods.isEmpty || !$0.properties.isEmpty }
    }

    private static func hasMeaningfulContent(
        output: GenerationOutput,
        classes: [ClassInfo],
        interfaces: [InterfaceInfo],
        functions: [FunctionInfo],
        globalVars: [VariableInfo]
    ) -> Bool {
        !output.imports.isEmpty || !output.exports.isEmpty || !classes.isEmpty ||
            !functions.isEmpty || !globalVars.isEmpty || !output.enums.isEmpty ||
            !output.macros.isEmpty || !interfaces.isEmpty || !output.aliases.isEmpty ||
            !output.literalUnions.isEmpty
    }

    // MARK: - Optimized Helpers

    private static func binarySearchFirstFalse(count: Int, predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(mid) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func isBetterRange(_ candidate: NSRange, than current: NSRange) -> Bool {
        if candidate.length != current.length {
            return candidate.length < current.length
        }
        return candidate.location < current.location
    }

    /// Precomputes the starting indices of each line in the content.
    /// Matches read_file semantics by treating \r, \n, and \r\n as line endings.
    static func computeLineBoundaries(content: String) -> [Int] {
        let utf16 = content.utf16
        var boundaries = [0]
        var idx = utf16.startIndex
        var offset = 0
        while idx < utf16.endIndex {
            let unit = utf16[idx]
            if unit == 13 { // \r
                let next = utf16.index(after: idx)
                if next < utf16.endIndex, utf16[next] == 10 {
                    // CRLF
                    idx = utf16.index(after: next)
                    offset += 2
                } else {
                    idx = next
                    offset += 1
                }
                boundaries.append(offset)
                continue
            } else if unit == 10 { // \n
                idx = utf16.index(after: idx)
                offset += 1
                boundaries.append(offset)
                continue
            }
            idx = utf16.index(after: idx)
            offset += 1
        }
        return boundaries
    }

    /// Returns the 0-indexed line index for a given location using precomputed boundaries.
    private static func lineIndex(for location: Int, using boundaries: [Int]) -> Int {
        var low = 0
        var high = boundaries.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if boundaries[mid] <= location {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Returns the 1-indexed line number for a given location using precomputed boundaries.
    static func lineNumber(for location: Int, using boundaries: [Int]) -> Int {
        lineIndex(for: location, using: boundaries) + 1
    }

    private static func jstsContextForVariableDecl(_ decl: String) -> JSTSSignatureContext {
        let trimmed = decl.trimmingCharacters(in: .whitespacesAndNewlines)
        if TopLevelScanner.containsTopLevel("=>", in: trimmed, track: .all) {
            return .functionLike
        }
        return .statementLike
    }

    /// Returns the full declaration line (plus any indented continuations) for a capture.
    /// For TS/TSX, use context-aware signature extraction that handles type literals correctly.
    private static func captureDeclaration(
        nsContent: NSString,
        for range: NSRange,
        lineRange: NSRange,
        terminator: Character,
        jsTsContext: JSTSSignatureContext? = nil,
        returnRawJSTS: Bool = false,
        perfStats: CodeMapPerfStats? = nil,
        perfOptions: CodeMapPerfOptions = .disabled
    ) -> String {
        let activePerfOptions = CodeMapPerfRuntime.activeOptions(perfOptions)
        let activePerfStats = CodeMapPerfRuntime.activeStats(perfStats)
        let perfEnabled = activePerfOptions.enabled
        let perfCollectCounters = activePerfOptions.collectCounters
        if perfCollectCounters {
            activePerfStats?.captureDeclarationCalls += 1
        }
        let start = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        defer {
            if perfEnabled {
                activePerfStats?.captureDeclarationDuration += (CFAbsoluteTimeGetCurrent() - start)
            }
        }
        let currentLineRange = lineRange
        var declaration = nsContent.substring(with: currentLineRange)
        let trimmedDeclaration = declaration.trimmingCharacters(in: .whitespaces)
        let isJSTS = returnRawJSTS || (jsTsContext != nil)
        if isJSTS {
            let context = jsTsContext ?? .statementLike
            let assembled = captureJSTSDeclaration(
                nsContent: nsContent,
                startRange: currentLineRange,
                context: context
            )
            if let context = jsTsContext, !returnRawJSTS {
                return JSTSSignatureExtractor.extract(
                    from: assembled,
                    context: context,
                    perfStats: activePerfStats,
                    perfOptions: activePerfOptions
                )
            }
            return assembled
        }

        // For Ruby, keep declaration to a single line (no multiline continuation).
        if terminator == "\0" {
            return declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // For Python function definitions (a "def " line with a ":" terminator),
        // find the matching closing parenthesis and then the colon.
        if terminator == ":", trimmedDeclaration.hasPrefix("def ") || trimmedDeclaration.hasPrefix("async def ") {
            if let parenStart = declaration.firstIndex(of: "("),
               let matchingParen = findMatchingParenthesis(in: declaration, startingAt: parenStart)
            {
                let searchRange = declaration.index(after: matchingParen) ..< declaration.endIndex
                if let colonIndex = declaration[searchRange].firstIndex(of: ":") {
                    declaration = String(declaration[..<colonIndex]) + ":"
                    return declaration.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Fallback: if the terminator exists anywhere in the line, truncate there.
        // NOTE: JS/TS use JSTSSignatureExtractor above, so this fallback is for other languages.
        // We do NOT use the semicolon heuristic here - that was JS/TS-specific and caused body
        // leakage in languages like Swift, C#, etc. where semicolons appear in string literals.
        if !isJSTS {
            let termIndex = (terminator == "{")
                ? findTopLevelBrace(in: declaration)
                : declaration.firstIndex(of: terminator)
            if let termIndex {
                // Truncate at the terminator (don't include `{` for brace-delimited languages)
                if terminator == "{" {
                    declaration = String(declaration[..<termIndex])
                } else {
                    declaration = String(declaration[..<termIndex]) + String(terminator)
                }
                return declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Fix 1: Capture multiline declarations correctly
        // After we've grabbed the current line, extend across indented continuation lines.
        let baseIndent = declaration.prefix(while: { $0.isWhitespace }).count
        var nextLocation = currentLineRange.upperBound

        while nextLocation < nsContent.length {
            let nextLineRange = nsContent.lineRange(for: NSRange(location: nextLocation, length: 0))
            let nextLine = nsContent.substring(with: nextLineRange)
            let trimmedNext = nextLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedNext.isEmpty || (trimmedNext.first == terminator) { break }
            if trimmedNext.first == ":", declaration.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(")") {
                break
            }

            if !isJSTS, terminator == "{" {
                let state = parenState(in: declaration)
                if state.sawParen, state.depth == 0 {
                    break
                }
            }

            let nextIndent = nextLine.prefix(while: { $0.isWhitespace }).count
            if nextIndent > baseIndent {
                if isJSTS {
                    declaration += "\n" + trimmedNext
                } else {
                    declaration += " " + trimmedNext
                }
                if !isJSTS {
                    let termIndex = (terminator == "{")
                        ? findTopLevelBrace(in: declaration)
                        : declaration.firstIndex(of: terminator)
                    if let termIndex {
                        // For TypeScript/JavaScript, don't include the opening brace
                        if terminator == "{" {
                            declaration = String(declaration[..<termIndex])
                        } else {
                            declaration = String(declaration[..<termIndex]) + String(terminator)
                        }
                        break
                    }
                }
                nextLocation = nextLineRange.upperBound
            } else {
                break
            }
        }

        return declaration.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func captureJSTSDeclaration(
        nsContent: NSString,
        startRange: NSRange,
        context: JSTSSignatureContext
    ) -> String {
        var declaration = nsContent.substring(with: startRange)
        let baseIndent = declaration.prefix(while: { $0.isWhitespace }).count
        var nextLocation = startRange.upperBound
        var linesAdded = 0

        while nextLocation < nsContent.length, linesAdded < jstsMaxAppendedContinuationLines {
            let trimmedDecl = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            switch context {
            case .functionLike:
                if isJSTSFunctionSignatureComplete(trimmedDecl) { return trimmedDecl }
            case .statementLike:
                break
            }

            let nextLineRange = nsContent.lineRange(for: NSRange(location: nextLocation, length: 0))
            let nextLine = nsContent.substring(with: nextLineRange)
            let trimmedNext = nextLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedNext.isEmpty { break }
            let nextIndent = nextLine.prefix(while: { $0.isWhitespace }).count

            if context == .statementLike {
                let needsBraceContinuation = jstsNeedsBraceContinuation(trimmedDecl)
                if nextIndent <= baseIndent, !needsBraceContinuation { break }
            }

            declaration += "\n" + trimmedNext
            nextLocation = nextLineRange.upperBound
            linesAdded += 1
        }

        return declaration.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isJSTSFunctionSignatureComplete(_ declaration: String) -> Bool {
        let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let hasAssignment = jstsTopLevelAssignmentIndex(in: trimmed) != nil
        let looksLikeVarDecl = jstsLooksLikeVariableDecl(trimmed)
        if TopLevelScanner.containsTopLevel("=>", in: trimmed, track: .all) {
            return true
        }
        if hasAssignment || looksLikeVarDecl {
            if TopLevelScanner.firstTopLevelIndex(of: ";", in: trimmed, track: .all) != nil {
                return true
            }
            return false
        }
        if let returnType = LanguageTypeExtractor.TS.extractReturnType(from: trimmed),
           returnType.hasPrefix("{"),
           !returnType.hasSuffix("}")
        {
            return false
        }
        if TopLevelScanner.firstTopLevelIndex(of: "{", in: trimmed, track: .all) != nil {
            return true
        }
        if TopLevelScanner.firstTopLevelIndex(of: ";", in: trimmed, track: .all) != nil {
            return true
        }
        return false
    }

    private static func jstsLooksLikeVariableDecl(_ declaration: String) -> Bool {
        var trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["export default ", "export ", "declare "]
        for prefix in prefixes {
            if trimmed.hasPrefix(prefix) {
                trimmed = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return trimmed.hasPrefix("const ") || trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ")
    }

    private static func jstsNeedsBraceContinuation(_ declaration: String) -> Bool {
        let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        return jstsTopLevelBraceDepth(in: Substring(trimmed)) > 0
    }

    private static func jstsTopLevelAssignmentIndex(in text: String) -> String.Index? {
        var angleDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            switch ch {
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            case "[": bracketDepth += 1
            case "]": bracketDepth = max(0, bracketDepth - 1)
            case "=":
                if angleDepth == 0, parenDepth == 0, braceDepth == 0, bracketDepth == 0 {
                    let next = text.index(after: i)
                    if next < text.endIndex {
                        let nextChar = text[next]
                        if nextChar == ">" || nextChar == "=" {
                            i = next
                            continue
                        }
                    }
                    return i
                }
            default: break
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func jstsTopLevelBraceDepth(in text: Substring) -> Int {
        var angleDepth = 0
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            switch ch {
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "[": bracketDepth += 1
            case "]": bracketDepth = max(0, bracketDepth - 1)
            case "{":
                if angleDepth == 0, parenDepth == 0, bracketDepth == 0 { braceDepth += 1 }
            case "}":
                if angleDepth == 0, parenDepth == 0, bracketDepth == 0, braceDepth > 0 {
                    braceDepth -= 1
                }
            default: break
            }
            i = text.index(after: i)
        }
        return braceDepth
    }

    private static func findMatchingParenthesis(in string: String, startingAt start: String.Index) -> String.Index? {
        var count = 0
        var index = start
        while index < string.endIndex {
            let ch = string[index]
            if ch == "(" {
                count += 1
            } else if ch == ")" {
                count -= 1
                if count == 0 { return index }
            }
            index = string.index(after: index)
        }
        return nil
    }

    private static func findTopLevelBrace(in string: String) -> String.Index? {
        var parenDepth = 0
        var bracketDepth = 0
        var inString: Character? = nil
        var escaped = false
        var inBlockComment = false
        var index = string.startIndex

        while index < string.endIndex {
            let ch = string[index]

            if inBlockComment {
                if ch == "*" {
                    let nextIndex = string.index(after: index)
                    if nextIndex < string.endIndex, string[nextIndex] == "/" {
                        inBlockComment = false
                        index = string.index(after: nextIndex)
                        continue
                    }
                }
                index = string.index(after: index)
                continue
            }

            if let stringDelimiter = inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == stringDelimiter {
                    inString = nil
                }
                index = string.index(after: index)
                continue
            }

            if ch == "\"" || ch == "'" {
                inString = ch
                index = string.index(after: index)
                continue
            }

            if ch == "/" {
                let nextIndex = string.index(after: index)
                if nextIndex < string.endIndex {
                    let nextChar = string[nextIndex]
                    if nextChar == "/" {
                        break
                    }
                    if nextChar == "*" {
                        inBlockComment = true
                        index = string.index(after: nextIndex)
                        continue
                    }
                }
            }

            switch ch {
            case "(":
                parenDepth += 1
            case ")":
                parenDepth = max(0, parenDepth - 1)
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                if parenDepth == 0, bracketDepth == 0 {
                    return index
                }
            default:
                break
            }
            index = string.index(after: index)
        }

        return nil
    }

    private static func parenState(in string: String) -> (depth: Int, sawParen: Bool) {
        var parenDepth = 0
        var sawParen = false
        var inString: Character? = nil
        var escaped = false
        var inBlockComment = false
        var index = string.startIndex

        while index < string.endIndex {
            let ch = string[index]

            if inBlockComment {
                if ch == "*" {
                    let nextIndex = string.index(after: index)
                    if nextIndex < string.endIndex, string[nextIndex] == "/" {
                        inBlockComment = false
                        index = string.index(after: nextIndex)
                        continue
                    }
                }
                index = string.index(after: index)
                continue
            }

            if let stringDelimiter = inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == stringDelimiter {
                    inString = nil
                }
                index = string.index(after: index)
                continue
            }

            if ch == "\"" || ch == "'" {
                inString = ch
                index = string.index(after: index)
                continue
            }

            if ch == "/" {
                let nextIndex = string.index(after: index)
                if nextIndex < string.endIndex {
                    let nextChar = string[nextIndex]
                    if nextChar == "/" {
                        break
                    }
                    if nextChar == "*" {
                        inBlockComment = true
                        index = string.index(after: nextIndex)
                        continue
                    }
                }
            }

            switch ch {
            case "(":
                parenDepth += 1
                sawParen = true
            case ")":
                parenDepth = max(0, parenDepth - 1)
                sawParen = true
            default:
                break
            }

            index = string.index(after: index)
        }

        return (depth: parenDepth, sawParen: sawParen)
    }

    /// Extracts a substring from content using an NSRange.
    private static func substring(content: String, range: NSRange) -> String {
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: content) else { return "" }
        return String(content[swiftRange])
    }

    /// Helper to map file extensions to our SupportedLang enum.
    private static func supportedLang(for fileExtension: String) -> LanguageType? {
        switch fileExtension {
        case "swift": .swift
        case "cs": .c_sharp
        case "java": .java
        case "dart": .dart
        case "c": .c
        case "cpp": .cpp
        case "py": .python
        case "js": .js
        case "go": .go
        case "rs": .rust
        case "ts": .ts
        case "tsx": .tsx
        case "php": .php
        case "rb": .ruby
        default: nil
        }
    }

    /// Extracts a clean function name for TS/TSX from the capture text or declaration.
    /// Handles: identifiers, member expressions (Tabs.List), const/let/var declarations, function declarations.
    private static func extractJSTSFunctionName(captureText: String, decl: String) -> String {
        let cap = captureText.trimmingCharacters(in: .whitespacesAndNewlines)

        // If capture is already a clean identifier or dotted member expression, use it directly
        if let _ = firstRegexGroup(RegexCache.jstsIdentifierOrMember, in: cap) {
            return cap
        }

        // const/let/var Name = ... or const/let/var Name: Type = ...
        if let name = firstRegexGroup(RegexCache.jstsVarDeclName, in: decl) {
            return name
        }

        // function Name(...) or async function Name(...)
        if let name = firstRegexGroup(RegexCache.jstsFunctionDeclName, in: decl) {
            return name
        }

        // Tabs.List = ... (property assignment)
        if let name = firstRegexGroup(RegexCache.jstsPropAssignmentName, in: decl) {
            return name
        }

        // Fallback: return the full declaration
        return decl
    }

    /// Extracts a clean variable name for JS/TS global variables.
    private static func extractJSTSVariableName(from decl: String) -> String? {
        let trimmed = decl.trimmingCharacters(in: .whitespacesAndNewlines)
        // const/let/var Name ... (unicode-friendly)
        if let name = firstRegexGroup(RegexCache.jstsGlobalVarName, in: trimmed) {
            return name
        }
        return nil
    }

    /// Extracts a clean variable name for Go global variables.
    private static func extractGoVariableName(captureText: String, decl: String) -> String? {
        let cap = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cap.isEmpty, !containsWhitespace(cap) {
            return cap
        }
        if let name = firstRegexGroup(RegexCache.cOrGoVarName, in: decl) {
            return name
        }
        return nil
    }

    /// Extracts a clean variable name for C global variables.
    private static func extractCVariableName(captureText: String, decl: String) -> String? {
        let cap = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cap.isEmpty, !containsWhitespace(cap) {
            return cap
        }
        if let name = firstRegexGroup(RegexCache.cOrGoVarName, in: decl) {
            return name
        }
        return nil
    }

    // MARK: - PCRE2 Regex Cache

    /// Cached PCRE2 patterns for identifier and declaration extraction.
    /// Uses Unicode character classes for broad language support.
    private enum RegexCache {
        /// Matches a simple identifier: starts with letter/underscore/$, followed by alphanumerics.
        static let simpleIdentifier = CodeMapPCRE2Pattern(#"^([\p{L}_$][\p{L}\p{N}_$]*)$"#)

        /// Matches Go receiver type: func (receiver) methodName.
        static let goReceiverType = CodeMapPCRE2Pattern(#"func\s*\(([^)]*)\)\s+[\p{L}_][\p{L}\p{N}_]*"#)

        /// Matches JS/TS identifier or member expression: foo or foo.bar.baz.
        static let jstsIdentifierOrMember = CodeMapPCRE2Pattern(#"^([\p{L}_$][\p{L}\p{N}_$]*(?:\.[\p{L}_$][\p{L}\p{N}_$]*)*)$"#)

        /// Matches JS/TS variable declaration name: (export)? (default)? (const|let|var) Name.
        static let jstsVarDeclName = CodeMapPCRE2Pattern(#"(?:export\s+)?(?:default\s+)?(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#)

        /// Matches JS/TS function declaration name: (export)? (default)? (async)? function Name.
        static let jstsFunctionDeclName = CodeMapPCRE2Pattern(#"(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+([\p{L}_$][\p{L}\p{N}_$]*)"#)

        /// Matches JS/TS property assignment: Foo.Bar.Baz =.
        static let jstsPropAssignmentName = CodeMapPCRE2Pattern(#"^([\p{L}_$][\p{L}\p{N}_$]*(?:\.[\p{L}_$][\p{L}\p{N}_$]*)+)\s*="#)

        /// Matches JS/TS global variable name: (export)? (declare)? (const|let|var) Name.
        static let jstsGlobalVarName = CodeMapPCRE2Pattern(#"(?:^|\s)(?:export\s+)?(?:declare\s+)?(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#)

        /// Matches C/Go variable name at start of string.
        /// Note: Intentionally ASCII-only - C/Go identifiers are ASCII by language spec.
        static let cOrGoVarName = CodeMapPCRE2Pattern(#"^([A-Za-z_][A-Za-z0-9_]*)"#)

        /// Matches Python enum base classes.
        static let pythonEnumClass = CodeMapPCRE2Pattern(#"\b(Enum|IntEnum|StrEnum)\b"#)

        /// Matches uppercase snake case (for Python enum members).
        static let upperSnakeCase = CodeMapPCRE2Pattern(#"^[A-Z][A-Z0-9_]*$"#)

        /// Matches JS/TS variable name extraction: (export)? (const|let|var) Name.
        static let jstsVarNameExtract = CodeMapPCRE2Pattern(#"(?:export\s+)?(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)"#)
    }

    /// Returns the first capture group from a PCRE2 match, or nil if no match.
    @inline(__always)
    private static func firstRegexGroup(_ regex: CodeMapPCRE2Pattern, in text: String) -> String? {
        regex.firstCapture(1, in: text)
    }

    /// Checks if text contains any whitespace characters.
    @inline(__always)
    private static func containsWhitespace(_ text: String) -> Bool {
        text.contains(where: \.isWhitespace)
    }
}
