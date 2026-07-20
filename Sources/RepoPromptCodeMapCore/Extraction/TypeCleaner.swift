//
//  TypeCleaner.swift
//  RepoPrompt
//
//  Enhanced to handle TypeScript/TSX container types like Promise, Record, etc.
//  and to ensure we skip ephemeral/builtin references more effectively.
//  Now also removes method‑invocation suffixes (e.g. .withSettings()) and
//  container types (Promise, Record, etc.) within extractBaseTypes() itself.
//

import Foundation

enum TypeCleaner {
    struct TypeCleanerCacheKey: Hashable {
        let language: LanguageType
        let raw: String
    }

    private enum TypeCleanerPhase {
        case preclean
        case tsLogic
        case nonTSLogic
        case tsObjectLiteral
        case filter
        case dedup
    }

    private enum TypeCleanerSets {
        static let swiftPrims: Set<String> = [
            "int", "int8", "int16", "int32", "int64",
            "uint", "uint8", "uint16", "uint32", "uint64",
            "float", "float32", "float64", "double",
            "bool", "boolean", "character", "string", "view", "void"
        ]
        static let csharpPrims: Set<String> = [
            "int", "float", "double", "bool", "boolean",
            "string", "char", "decimal", "long", "short", "byte", "object", "dynamic", "void"
        ]
        static let javaPrims: Set<String> = [
            "int", "float", "double", "boolean", "char", "short", "long", "byte", "string", "void"
        ]
        static let dartPrims: Set<String> = [
            "int", "double", "bool", "boolean", "num", "string", "object", "dynamic"
        ]
        static let cPrims: Set<String> = [
            "int", "char", "short", "long", "bool", "float", "double", "void", "size_t", "wchar_t"
        ]
        static let rustPrims: Set<String> = [
            "u8", "u16", "u32", "u64", "u128",
            "i8", "i16", "i32", "i64", "i128",
            "f32", "f64", "bool", "char", "str"
        ]
        static let goPrims: Set<String> = [
            "int", "int8", "int16", "int32", "int64",
            "uint", "uint8", "uint16", "uint32", "uint64",
            "float32", "float64", "bool", "byte", "rune",
            "string", "complex64", "complex128"
        ]
        static let phpPrims: Set<String> = [
            "int", "integer", "float", "double", "bool", "boolean",
            "string", "array", "object", "resource", "null",
            "mixed", "void", "never", "callable", "iterable",
            "true", "false", "self", "parent", "static"
        ]
        static let tsPrims: Set<String> = [
            "any", "unknown", "never", "void",
            "null", "undefined", "object",
            "boolean", "number", "bigint", "string", "symbol"
        ]
        static let pythonPrims: Set<String> = [
            "none", "int", "float", "bool", "str", "list", "dict", "tuple", "set"
        ]

        static let universalContainers: Set<String> = [
            "array", "map", "list", "set", "dictionary", "hashmap", "hashset", "vector"
        ]
        static let tsContainers: Set<String> = [
            "array", "map", "set", "weakmap", "weakset", "readonlyarray", "promise", "record",
            "readonlymap", "readonlyset", "iterable", "iterator", "asynciterator", "generator", "readonly"
        ]
        static let csharpContainers: Set<String> = [
            "list", "dictionary", "hashset", "sortedlist", "queue", "stack"
        ]
        static let javaContainers: Set<String> = [
            "list", "arraylist", "map", "hashmap", "set", "hashset", "linkedlist", "queue"
        ]
        static let cppContainers: Set<String> = [
            "vector", "map", "unordered_map", "set", "unordered_set", "deque", "queue", "stack"
        ]
        static let rustContainers: Set<String> = [
            "vec", "hashmap", "hashset", "btreemap", "btreeset"
        ]
        static let swiftContainers: Set<String> = [
            "array", "dictionary", "set", "optional"
        ]
        static let swiftSpecialTypes: Set<String> = [
            "sendable", "error", "codable", "anyobject"
        ]
    }

    /// Returns one or more atomic type names for a raw type string.
    /// TS/TSX types are routed through TS-specific logic.
    static func extractBaseTypes(from rawType: String, language: LanguageType) -> [String] {
        switch language {
        case .ts, .tsx:
            extractBaseTypesTS(rawType, language: language)
        default:
            extractBaseTypesNonTS(rawType, language: language)
        }
    }

    /// Cached variant to avoid repeated parsing within a file.
    static func extractBaseTypes(
        from rawType: String,
        language: LanguageType,
        cache: inout [TypeCleanerCacheKey: [String]],
        stats: CodeMapPerformanceCollector? = nil
    ) -> [String] {
        extractBaseTypesCached(from: rawType, language: language, cache: &cache, stats: stats)
    }

    private static func extractBaseTypesCached(
        from rawType: String,
        language: LanguageType,
        cache: inout [TypeCleanerCacheKey: [String]],
        stats: CodeMapPerformanceCollector? = nil
    ) -> [String] {
        let activeStats = stats
        let key = TypeCleanerCacheKey(language: language, raw: rawType)
        activeStats?.typeCleanerExtractCalls += 1
        if let cached = cache[key] {
            activeStats?.typeCleanerCacheHits += 1
            return cached
        }
        activeStats?.typeCleanerCacheMisses += 1
        let languageStart = activeStats == nil ? 0 : CFAbsoluteTimeGetCurrent()
        let result: [String] = switch language {
        case .ts, .tsx:
            extractBaseTypesTSCached(rawType, language: language, cache: &cache, stats: activeStats)
        default:
            extractBaseTypesNonTSCached(rawType, language: language, cache: &cache, stats: activeStats)
        }
        if let activeStats {
            recordTypeCleanerLanguage(language, duration: CFAbsoluteTimeGetCurrent() - languageStart, stats: activeStats)
        }
        cache[key] = result
        return result
    }

    private static func recordTypeCleanerLanguage(
        _ language: LanguageType,
        duration: TimeInterval,
        stats: CodeMapPerformanceCollector
    ) {
        switch language {
        case .swift:
            stats.typeCleanerSwiftDuration += duration
            stats.typeCleanerSwiftCalls += 1
        case .ts:
            stats.typeCleanerTSDuration += duration
            stats.typeCleanerTSCalls += 1
        case .tsx:
            stats.typeCleanerTSXDuration += duration
            stats.typeCleanerTSXCalls += 1
        case .js:
            stats.typeCleanerJSDuration += duration
            stats.typeCleanerJSCalls += 1
        default:
            stats.typeCleanerOtherLanguageDuration += duration
            stats.typeCleanerOtherLanguageCalls += 1
        }
    }

    private static func recordTypeCleanerPhase(
        _ phase: TypeCleanerPhase,
        duration: TimeInterval,
        stats: CodeMapPerformanceCollector
    ) {
        switch phase {
        case .preclean:
            stats.typeCleanerPrecleanDuration += duration
            stats.typeCleanerPrecleanCount += 1
        case .tsLogic:
            stats.typeCleanerTSLogicDuration += duration
            stats.typeCleanerTSLogicCount += 1
        case .nonTSLogic:
            stats.typeCleanerNonTSLogicDuration += duration
            stats.typeCleanerNonTSLogicCount += 1
        case .tsObjectLiteral:
            stats.typeCleanerTSObjectLiteralDuration += duration
            stats.typeCleanerTSObjectLiteralCount += 1
        case .filter:
            stats.typeCleanerFilterDuration += duration
            stats.typeCleanerFilterCount += 1
        case .dedup:
            stats.typeCleanerDedupDuration += duration
            stats.typeCleanerDedupCount += 1
        }
    }

    // MARK: - Non‑TypeScript/TSX Logic

    static func extractBaseTypesNonTS(_ rawType: String, language: LanguageType) -> [String] {
        var type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        type = removeComments(from: type, language: language)
        if language == .swift {
            type = removeOpaqueTypeKeyword(from: type, language: language)
            type = normalizeSwiftType(type)
        }

        // Remove any trailing `.methodCall(...)` or `.property` patterns (including optional generics)
        type = removeMethodCalls(type)

        // Remove unmatched < or >
        type = stripUnmatchedAngleBrackets(type)
        type = stripUnbalancedParens(type)
        type = stripSurroundingParenPairs(type)
        type = stripTrailingBracesAndParens(type)

        if language == .swift {
            let intersections = splitSwiftIntersections(type)
            if intersections.count > 1 {
                let extracted = intersections.flatMap { extractBaseTypesNonTS($0, language: language) }
                let deduped = Array(Set(extracted.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
                return filterOutPrimitiveAndSpecialTypes(deduped, language: language)
            }
        }

        var results: [String] = []

        // 1) Swift closure / function-type => (A, B) -> C
        if let arrowIndex = findTopLevelString(in: type, needle: "->") {
            let paramPart = String(type[..<arrowIndex]).trimmingCharacters(in: .whitespaces)
            let returnPart = String(type[arrowIndex...].dropFirst(2)).trimmingCharacters(in: .whitespaces)

            let paramInner = stripSurroundingParenPairs(paramPart)
            let paramTypes = splitByTopLevelCommas(paramInner)
                .flatMap { extractBaseTypes(from: $0, language: language) }
            let retTypes = extractBaseTypes(from: returnPart, language: language)
            results = paramTypes + retTypes
        }
        // 2) Repeatedly peel off top-level generics with <...>
        else {
            var workingType = type
            var didExtractGeneric = false

            repeat {
                didExtractGeneric = false
                if let ltIndex = findTopLevelChar(in: workingType, char: "<"),
                   let gtIndex = findMatchingAngleBracket(in: workingType, startIndex: ltIndex)
                {
                    let before = String(workingType[..<ltIndex]).trimmingCharacters(in: .whitespaces)
                    let inside = String(workingType[workingType.index(after: ltIndex) ..< gtIndex])

                    let outsideCleaned = stripPointerOptional(before, language: language)
                    let insideSplit = splitByTopLevelCommas(inside)
                        .flatMap { extractBaseTypes(from: $0, language: language) }

                    results.append(contentsOf: [outsideCleaned] + insideSplit)

                    // Move on to any remainder after the matching '>'
                    let remainder = workingType[gtIndex...].dropFirst().trimmingCharacters(in: .whitespaces)
                    workingType = remainder
                    didExtractGeneric = true
                }
            } while didExtractGeneric && !workingType.isEmpty

            // If nothing got extracted via generics, or there's leftover
            if !didExtractGeneric {
                // Check parentheses or bracket forms
                if let parenIndex = findTopLevelChar(in: workingType, char: "("),
                   let closeIndex = findMatchingParenthesis(in: workingType, startIndex: parenIndex)
                {
                    let inside = String(workingType[workingType.index(after: parenIndex) ..< closeIndex])
                    let subSplit = splitByTopLevelCommas(inside)
                        .flatMap { extractBaseTypes(from: $0, language: language) }
                    results = subSplit.isEmpty ? [workingType] : subSplit
                } else if let sqIndex = findTopLevelChar(in: workingType, char: "["),
                          let closeSqIndex = findMatchingSquareBracket(in: workingType, startIndex: sqIndex)
                {
                    let inside = String(workingType[workingType.index(after: sqIndex) ..< closeSqIndex])
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    // dictionary style => [K: V]
                    if findTopLevelChar(in: inside, char: ":") != nil {
                        let dictParts = splitByTopLevelColon(inside)
                        let keySide = dictParts.first ?? ""
                        let valSide = dictParts.count > 1 ? dictParts[1] : ""

                        let keyTypes = extractBaseTypes(from: keySide, language: language)
                        let valTypes = extractBaseTypes(from: valSide, language: language)
                        results = keyTypes + valTypes
                    } else {
                        // array style => [T]
                        results = extractBaseTypes(from: inside, language: language)
                    }
                } else {
                    // fallback
                    let final = stripPointerOptional(workingType, language: language)
                    let cleaned = removeTrailingStandaloneBrackets(final)
                    results = [cleaned.trimmingCharacters(in: .whitespacesAndNewlines)]
                }
            } else {
                // We did parse out some generics. The leftover workingType might still contain more.
                if !workingType.isEmpty {
                    // Recurse the leftover string
                    let leftoverTypes = extractBaseTypesNonTS(workingType, language: language)
                    results.append(contentsOf: leftoverTypes)
                }
            }
        }

        let deduped = Array(Set(results.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
        return filterOutPrimitiveAndSpecialTypes(deduped, language: language)
    }

    private static func extractBaseTypesNonTSCached(
        _ rawType: String,
        language: LanguageType,
        cache: inout [TypeCleanerCacheKey: [String]],
        stats: CodeMapPerformanceCollector?
    ) -> [String] {
        let precleanStart = stats == nil ? 0 : CFAbsoluteTimeGetCurrent()
        var type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        type = removeComments(from: type, language: language)
        if language == .swift {
            type = removeOpaqueTypeKeyword(from: type, language: language)
            type = normalizeSwiftType(type)
        }

        // Remove any trailing `.methodCall(...)` or `.property` patterns (including optional generics)
        type = removeMethodCalls(type)

        // Remove unmatched < or >
        type = stripUnmatchedAngleBrackets(type)
        type = stripUnbalancedParens(type)
        type = stripSurroundingParenPairs(type)
        type = stripTrailingBracesAndParens(type)
        if let stats {
            recordTypeCleanerPhase(.preclean, duration: CFAbsoluteTimeGetCurrent() - precleanStart, stats: stats)
        }

        let logicStart = stats == nil ? 0 : CFAbsoluteTimeGetCurrent()
        defer {
            if let stats {
                recordTypeCleanerPhase(.nonTSLogic, duration: CFAbsoluteTimeGetCurrent() - logicStart, stats: stats)
            }
        }

        if language == .swift {
            let intersections = splitSwiftIntersections(type)
            if intersections.count > 1 {
                let extracted = intersections.flatMap {
                    extractBaseTypesCached(from: $0, language: language, cache: &cache, stats: stats)
                }
                let deduped = Array(Set(extracted.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
                return filterOutPrimitiveAndSpecialTypesCached(deduped, language: language, cache: &cache, stats: stats)
            }
        }

        var results: [String] = []

        // 1) Swift closure / function-type => (A, B) -> C
        if let arrowIndex = findTopLevelString(in: type, needle: "->") {
            let paramPart = String(type[..<arrowIndex]).trimmingCharacters(in: .whitespaces)
            let returnPart = String(type[arrowIndex...].dropFirst(2)).trimmingCharacters(in: .whitespaces)

            let paramInner = stripSurroundingParenPairs(paramPart)
            let paramTypes = splitByTopLevelCommas(paramInner)
                .flatMap { extractBaseTypesCached(from: $0, language: language, cache: &cache, stats: stats) }
            let retTypes = extractBaseTypesCached(from: returnPart, language: language, cache: &cache, stats: stats)
            results = paramTypes + retTypes
        }
        // 2) Repeatedly peel off top-level generics with <...>
        else {
            var workingType = type
            var didExtractGeneric = false

            repeat {
                didExtractGeneric = false
                if let ltIndex = findTopLevelChar(in: workingType, char: "<"),
                   let gtIndex = findMatchingAngleBracket(in: workingType, startIndex: ltIndex)
                {
                    let before = String(workingType[..<ltIndex]).trimmingCharacters(in: .whitespaces)
                    let inside = String(workingType[workingType.index(after: ltIndex) ..< gtIndex])

                    let outsideCleaned = stripPointerOptional(before, language: language)
                    let insideSplit = splitByTopLevelCommas(inside)
                        .flatMap { extractBaseTypesCached(from: $0, language: language, cache: &cache, stats: stats) }

                    results.append(contentsOf: [outsideCleaned] + insideSplit)

                    // Move on to any remainder after the matching '>'
                    let remainder = workingType[gtIndex...].dropFirst().trimmingCharacters(in: .whitespaces)
                    workingType = remainder
                    didExtractGeneric = true
                }
            } while didExtractGeneric && !workingType.isEmpty

            // If nothing got extracted via generics, or there's leftover
            if !didExtractGeneric {
                // Check parentheses or bracket forms
                if let parenIndex = findTopLevelChar(in: workingType, char: "("),
                   let closeIndex = findMatchingParenthesis(in: workingType, startIndex: parenIndex)
                {
                    let inside = String(workingType[workingType.index(after: parenIndex) ..< closeIndex])
                    let subSplit = splitByTopLevelCommas(inside)
                        .flatMap { extractBaseTypesCached(from: $0, language: language, cache: &cache, stats: stats) }
                    results = subSplit.isEmpty ? [workingType] : subSplit
                } else if let sqIndex = findTopLevelChar(in: workingType, char: "["),
                          let closeSqIndex = findMatchingSquareBracket(in: workingType, startIndex: sqIndex)
                {
                    let inside = String(workingType[workingType.index(after: sqIndex) ..< closeSqIndex])
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    // dictionary style => [K: V]
                    if findTopLevelChar(in: inside, char: ":") != nil {
                        let dictParts = splitByTopLevelColon(inside)
                        let keySide = dictParts.first ?? ""
                        let valSide = dictParts.count > 1 ? dictParts[1] : ""

                        let keyTypes = extractBaseTypesCached(from: keySide, language: language, cache: &cache, stats: stats)
                        let valTypes = extractBaseTypesCached(from: valSide, language: language, cache: &cache, stats: stats)
                        results = keyTypes + valTypes
                    } else {
                        // array style => [T]
                        results = extractBaseTypesCached(from: inside, language: language, cache: &cache, stats: stats)
                    }
                } else {
                    // fallback
                    let final = stripPointerOptional(workingType, language: language)
                    let cleaned = removeTrailingStandaloneBrackets(final)
                    results = [cleaned.trimmingCharacters(in: .whitespacesAndNewlines)]
                }
            } else {
                // We did parse out some generics. The leftover workingType might still contain more.
                if !workingType.isEmpty {
                    // Recurse the leftover string
                    let leftoverTypes = extractBaseTypesCached(from: workingType, language: language, cache: &cache, stats: stats)
                    results.append(contentsOf: leftoverTypes)
                }
            }
        }

        let deduped = Array(Set(results.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
        return filterOutPrimitiveAndSpecialTypesCached(deduped, language: language, cache: &cache, stats: stats)
    }

    // MARK: - TypeScript/TSX

    static func extractBaseTypesTS(_ rawType: String, language: LanguageType) -> [String] {
        var trimmed = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = removeComments(from: trimmed, language: language)
        trimmed = removeMethodCalls(trimmed)
        trimmed = stripUnmatchedAngleBrackets(trimmed)
        if trimmed.hasSuffix("?") {
            trimmed.removeLast()
        }

        // Remove TS type operators like 'keyof' and 'typeof'
        trimmed = regexReplace(RegexCache.tsKeyof, in: trimmed)
        trimmed = regexReplace(RegexCache.tsTypeof, in: trimmed)
        trimmed = regexReplace(RegexCache.tsReadonly, in: trimmed)

        // Handle TS function types at top level: (A, B) => C
        if let arrowIndex = findTopLevelString(in: trimmed, needle: "=>") {
            let paramPart = String(trimmed[..<arrowIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let returnPart = String(trimmed[trimmed.index(arrowIndex, offsetBy: 2)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let paramInner = stripSurroundingParenPairs(paramPart)
            let paramChunks = splitByTopLevelCommas(paramInner)
            var extracted: [String] = []
            for chunk in paramChunks {
                let normalized = stripTSParamLabelAndDefault(chunk)
                if !normalized.isEmpty {
                    extracted.append(contentsOf: extractBaseTypesTS(normalized, language: language))
                }
            }
            if !returnPart.isEmpty {
                extracted.append(contentsOf: extractBaseTypesTS(returnPart, language: language))
            }
            let filtered = filterOutPrimitiveAndSpecialTypes(extracted, language: language)
            return Array(Set(filtered))
        }

        // Handle TS object literal types: { a: T; b: U }
        if trimmed.hasPrefix("{") {
            let extracted = extractTSObjectLiteralTypes(from: trimmed, language: language)
            let filtered = filterOutPrimitiveAndSpecialTypes(extracted, language: language)
            return Array(Set(filtered))
        }

        // Split top-level '|' or '&'
        let splitted = splitTSUnionsAndIntersections(trimmed)

        var finalTypes = [String]()
        for piece in splitted {
            let trimmedPiece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPiece.hasPrefix("{") {
                let extracted = extractTSObjectLiteralTypes(from: trimmedPiece, language: language)
                finalTypes.append(contentsOf: extracted)
            } else {
                let subTypes = extractBaseTypesNonTS(trimmedPiece, language: language)
                finalTypes.append(contentsOf: subTypes)
            }
        }

        let filtered = filterOutPrimitiveAndSpecialTypes(finalTypes, language: language)
        return Array(Set(filtered))
    }

    private static func extractBaseTypesTSCached(
        _ rawType: String,
        language: LanguageType,
        cache: inout [TypeCleanerCacheKey: [String]],
        stats: CodeMapPerformanceCollector?
    ) -> [String] {
        let precleanStart = stats == nil ? 0 : CFAbsoluteTimeGetCurrent()
        var trimmed = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = removeComments(from: trimmed, language: language)
        trimmed = removeMethodCalls(trimmed)
        trimmed = stripUnmatchedAngleBrackets(trimmed)
        if trimmed.hasSuffix("?") {
            trimmed.removeLast()
        }

        // Remove TS type operators like 'keyof' and 'typeof'
        trimmed = regexReplace(RegexCache.tsKeyof, in: trimmed)
        trimmed = regexReplace(RegexCache.tsTypeof, in: trimmed)
        trimmed = regexReplace(RegexCache.tsReadonly, in: trimmed)
        if let stats {
            recordTypeCleanerPhase(.preclean, duration: CFAbsoluteTimeGetCurrent() - precleanStart, stats: stats)
        }

        let logicStart = stats == nil ? 0 : CFAbsoluteTimeGetCurrent()
        defer {
            if let stats {
                recordTypeCleanerPhase(.tsLogic, duration: CFAbsoluteTimeGetCurrent() - logicStart, stats: stats)
            }
        }

        // Handle TS function types at top level: (A, B) => C
        if let arrowIndex = findTopLevelString(in: trimmed, needle: "=>") {
            let paramPart = String(trimmed[..<arrowIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let returnPart = String(trimmed[trimmed.index(arrowIndex, offsetBy: 2)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let paramInner = stripSurroundingParenPairs(paramPart)
            let paramChunks = splitByTopLevelCommas(paramInner)
            var extracted: [String] = []
            for chunk in paramChunks {
                let normalized = stripTSParamLabelAndDefault(chunk)
                if !normalized.isEmpty {
                    extracted.append(contentsOf: extractBaseTypesCached(from: normalized, language: language, cache: &cache, stats: stats))
                }
            }
            if !returnPart.isEmpty {
                extracted.append(contentsOf: extractBaseTypesCached(from: returnPart, language: language, cache: &cache, stats: stats))
            }
            let filtered = filterOutPrimitiveAndSpecialTypesCached(extracted, language: language, cache: &cache, stats: stats)
            return Array(Set(filtered))
        }

        // Handle TS object literal types: { a: T; b: U }
        if trimmed.hasPrefix("{") {
            let extracted = extractTSObjectLiteralTypesCached(from: trimmed, language: language, cache: &cache, stats: stats)
            let filtered = filterOutPrimitiveAndSpecialTypesCached(extracted, language: language, cache: &cache, stats: stats)
            return Array(Set(filtered))
        }

        // Split top-level '|' or '&'
        let splitted = splitTSUnionsAndIntersections(trimmed)
        let shouldCacheSplitPieces = splitted.count > 1

        var finalTypes = [String]()
        for piece in splitted {
            let trimmedPiece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPiece.hasPrefix("{") {
                let extracted: [String] = if shouldCacheSplitPieces {
                    extractBaseTypesCached(from: trimmedPiece, language: language, cache: &cache, stats: stats)
                } else {
                    extractTSObjectLiteralTypesCached(from: trimmedPiece, language: language, cache: &cache, stats: stats)
                }
                finalTypes.append(contentsOf: extracted)
            } else {
                let subTypes: [String] = if shouldCacheSplitPieces {
                    extractBaseTypesCached(from: trimmedPiece, language: language, cache: &cache, stats: stats)
                } else {
                    extractBaseTypesNonTSCached(trimmedPiece, language: language, cache: &cache, stats: stats)
                }
                finalTypes.append(contentsOf: subTypes)
            }
        }

        let filtered = filterOutPrimitiveAndSpecialTypesCached(finalTypes, language: language, cache: &cache, stats: stats)
        return Array(Set(filtered))
    }

    // MARK: - Method Call Removal Fix

    /// Updated so that it also removes optional `<...>` generics: e.g. `.withSettings<T>(...)`.
    private static func removeMethodCalls(_ raw: String) -> String {
        // Pattern:
        //  1) A literal dot
        //  2) A valid identifier `[A-Za-z_] \w*`
        //  3) (optional) `<...>` generics
        //  4) (optional) `(...)` call
        regexReplace(RegexCache.methodCall, in: raw)
    }

    // — everything below is the same as before, except we keep the new loop approach above —

    private static func removeTrailingStandaloneBrackets(_ str: String) -> String {
        var cleaned = str
        while let last = cleaned.last, "<[(:".contains(last) {
            cleaned.removeLast()
        }
        while let first = cleaned.first, ">])".contains(first) {
            cleaned.removeFirst()
        }
        return cleaned
    }

    private static func stripUnmatchedAngleBrackets(_ str: String) -> String {
        var cleaned = str.trimmingCharacters(in: .whitespacesAndNewlines)

        // Preserve prior behavior for clearly unmatched cases
        while cleaned.hasSuffix(">"), !cleaned.contains("<") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while cleaned.hasPrefix("<"), !cleaned.contains(">") {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // NEW: If we have an unclosed '<', truncate at the outermost unmatched '<'
        var depth = 0
        var outermostUnclosedAtDepth0: String.Index? = nil

        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let ch = cleaned[i]

            if ch == "<" {
                if depth == 0 {
                    outermostUnclosedAtDepth0 = i
                }
                depth += 1
            } else if ch == ">" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        // Closed the outermost generic; reset.
                        outermostUnclosedAtDepth0 = nil
                    }
                }
                // Unmatched '>' at top level — ignore (do not go negative).
            }

            i = cleaned.index(after: i)
        }

        if depth > 0, let cut = outermostUnclosedAtDepth0 {
            cleaned = String(cleaned[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
    }

    private static func stripPointerOptional(_ type: String, language: LanguageType) -> String {
        var cleaned = type
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "[]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if language != .swift {
            cleaned = cleaned.replacingOccurrences(of: "&", with: "")
        }
        return cleaned
    }

    private static func stripUnbalancedParens(_ type: String) -> String {
        var cleaned = type
        while cleaned.hasPrefix("("), !cleaned.contains(")") {
            cleaned.removeFirst()
        }
        while cleaned.hasSuffix(")"), !cleaned.contains("(") {
            cleaned.removeLast()
        }
        return cleaned
    }

    private static func stripSurroundingParenPairs(_ type: String) -> String {
        var result = type.trimmingCharacters(in: .whitespacesAndNewlines)

        while result.hasPrefix("("), result.hasSuffix(")") {
            var depth = 0
            var isPerfectPair = false
            for (idx, ch) in result.enumerated() {
                if ch == "(" {
                    depth += 1
                } else if ch == ")" {
                    depth -= 1
                    if depth == 0, idx < result.count - 1 {
                        isPerfectPair = false
                        break
                    }
                    if idx == result.count - 1, depth == 0 {
                        isPerfectPair = true
                    }
                }
            }

            if isPerfectPair {
                result.removeFirst()
                result.removeLast()
            } else {
                break
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    private static func stripTrailingBracesAndParens(_ type: String) -> String {
        var cleaned = type
        while cleaned.hasSuffix("{") || cleaned.hasSuffix("}") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while cleaned.hasSuffix(")"), !cleaned.contains("(") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    // MARK: - Comments

    private static func removeComments(from type: String, language: LanguageType) -> String {
        var cleaned = type
        switch language {
        case .swift, .js, .c_sharp, .c, .rust, .cpp, .go, .java, .dart, .ts, .tsx, .php:
            cleaned = removeBlockComments(from: cleaned)
        case .python, .ruby:
            break
        }
        return removeInlineComments(from: cleaned, language: language)
    }

    private static func removeBlockComments(from type: String) -> String {
        var result = type
        while let start = result.range(of: "/*"),
              let end = result.range(of: "*/", range: start.upperBound ..< result.endIndex)
        {
            result.removeSubrange(start.lowerBound ..< end.upperBound)
        }
        return result
    }

    private static func removeInlineComments(from type: String, language: LanguageType) -> String {
        switch language {
        case .python, .ruby:
            if let range = type.range(of: "#") {
                return String(type[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return type
        case .php:
            let slashIndex = type.range(of: "//")?.lowerBound
            let hashIndex = type.range(of: "#")?.lowerBound
            if let cutIndex = [slashIndex, hashIndex].compactMap(\.self).min() {
                return String(type[..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return type
        default:
            if let range = type.range(of: "//") {
                return String(type[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return type
        }
    }

    // MARK: - find matching pairs

    private static func findTopLevelString(in type: String, needle: String) -> String.Index? {
        guard !needle.isEmpty, type.contains(needle) else { return nil }
        let chars = Array(type)
        let needleChars = Array(needle)
        let needleCount = needleChars.count

        var bracketDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var i = 0

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "<": bracketDepth += 1
            case ">": bracketDepth = max(0, bracketDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            default: break
            }
            if bracketDepth == 0, parenDepth == 0, braceDepth == 0 {
                if i + needleCount <= chars.count {
                    let slice = chars[i ..< (i + needleCount)]
                    if slice.elementsEqual(needleChars) {
                        return type.index(type.startIndex, offsetBy: i)
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private static func findTopLevelChar(in type: String, char: Character) -> String.Index? {
        TopLevelScanner.firstTopLevelIndex(of: char, in: type, track: .all)
    }

    private static func findMatchingAngleBracket(in type: String, startIndex: String.Index) -> String.Index? {
        var count = 0
        var i = startIndex
        while i < type.endIndex {
            if type[i] == "<" {
                count += 1
            } else if type[i] == ">" {
                count -= 1
                if count == 0 {
                    return i
                }
            }
            i = type.index(after: i)
        }
        return nil
    }

    private static func findMatchingParenthesis(in type: String, startIndex: String.Index) -> String.Index? {
        var count = 0
        var i = startIndex
        while i < type.endIndex {
            if type[i] == "(" {
                count += 1
            } else if type[i] == ")" {
                count -= 1
                if count == 0 {
                    return i
                }
            }
            i = type.index(after: i)
        }
        return nil
    }

    private static func findMatchingSquareBracket(in type: String, startIndex: String.Index) -> String.Index? {
        var count = 0
        var i = startIndex
        while i < type.endIndex {
            if type[i] == "[" {
                count += 1
            } else if type[i] == "]" {
                count -= 1
                if count == 0 {
                    return i
                }
            }
            i = type.index(after: i)
        }
        return nil
    }

    // MARK: - Splitting

    private static func splitByTopLevelCommas(_ input: String) -> [String] {
        let ranges = TopLevelScanner.splitTopLevel(input, separator: ",", track: .all)
        return ranges.map {
            input[$0].trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func splitByTopLevelColon(_ input: String) -> [String] {
        let ranges = TopLevelScanner.splitTopLevel(input, separator: ":", track: .all)
        return ranges.map {
            input[$0].trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func splitSwiftIntersections(_ input: String) -> [String] {
        let ranges = TopLevelScanner.splitTopLevel(input, operators: ["&"], track: .all)
        return ranges.map {
            input[$0].trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    // MARK: - TS union & intersection splits

    private static func splitTSUnionsAndIntersections(_ input: String) -> [String] {
        let unionPieces = splitByTopLevelOperator(input, operators: ["|"])
        var result: [String] = []
        for piece in unionPieces {
            let intersectionPieces = splitByTopLevelOperator(piece, operators: ["&"])
            result.append(contentsOf: intersectionPieces)
        }
        return result
    }

    private static func splitByTopLevelOperator(_ input: String, operators: [Character]) -> [String] {
        let ranges = TopLevelScanner.splitTopLevel(
            input,
            operators: Set(operators),
            track: .all
        )
        return ranges.map {
            input[$0].trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    // MARK: - Opaque / ephemeral / container checks

    private static func removeOpaqueTypeKeyword(from type: String, language: LanguageType) -> String {
        guard language == .swift else { return type }
        return regexReplace(RegexCache.swiftOpaque, in: type).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeSwiftType(_ type: String) -> String {
        var cleaned = type
        cleaned = regexReplace(RegexCache.swiftAttributes, in: cleaned)
        cleaned = regexReplace(RegexCache.swiftKeywords, in: cleaned)
        cleaned = cleaned.replacingOccurrences(of: "...", with: "")
        cleaned = regexReplace(RegexCache.multiWhitespace, in: cleaned, with: " ")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - PCRE2 Regex Cache

    /// Cached PCRE2 patterns for type cleaning operations.
    private enum RegexCache {
        /// Matches method calls like `.foo()`, `.bar<T>()` (requires parens to avoid stripping namespaces).
        static let methodCall = CodeMapPCRE2Pattern(#"\.[A-Za-z_][A-Za-z0-9_]*(<[^>]*>)?\([^)]*\)"#)

        /// Matches Swift opaque type keywords: `some Type` or `any Type`.
        static let swiftOpaque = CodeMapPCRE2Pattern(#"^\s*(some|any)\s+"#, caseInsensitive: true)

        /// Matches Swift attributes like @escaping, @Sendable, @available(...).
        static let swiftAttributes = CodeMapPCRE2Pattern(#"@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?"#)

        /// Matches Swift keywords that can appear in type positions.
        static let swiftKeywords = CodeMapPCRE2Pattern(#"\b(?:async|throws|rethrows|inout|borrowing|consuming|isolated|nonisolated|some|any)\b"#)

        /// Matches multiple whitespace characters.
        static let multiWhitespace = CodeMapPCRE2Pattern(#"\s+"#)

        /// Matches TypeScript `keyof` operator.
        static let tsKeyof = CodeMapPCRE2Pattern(#"\bkeyof\s+"#)

        /// Matches TypeScript `typeof` operator.
        static let tsTypeof = CodeMapPCRE2Pattern(#"\btypeof\s+"#)

        /// Matches TypeScript `readonly` modifier.
        static let tsReadonly = CodeMapPCRE2Pattern(#"\breadonly\s+"#)
    }

    /// Replaces all matches of the regex in the text with the replacement string.
    private static func regexReplace(_ regex: CodeMapPCRE2Pattern, in text: String, with replacement: String = "") -> String {
        regex.replacingMatches(in: text, with: replacement)
    }

    static func filterOutPrimitiveAndSpecialTypes(_ extracted: [String], language: LanguageType) -> [String] {
        var results: [String] = []

        for raw in extracted {
            let subTypes = expandTupleTypes(raw)
            for s in subTypes {
                var cleaned = stripUnbalancedParens(s).trimmingCharacters(in: .whitespacesAndNewlines)
                if language == .swift {
                    cleaned = stripSwiftTupleLabel(cleaned)
                } else if language == .ts || language == .tsx {
                    cleaned = stripTSParamLabelAndDefault(cleaned)
                }

                if language == .ts || language == .tsx, isTSLiteralType(cleaned) {
                    continue
                }

                if language == .ts || language == .tsx, cleaned.hasPrefix("{") {
                    let extractedObjectTypes = extractTSObjectLiteralTypes(from: cleaned, language: language)
                    results.append(contentsOf: extractedObjectTypes)
                    continue
                }
                if cleaned.contains("{") || cleaned.contains("}") || cleaned.contains("\n") {
                    continue
                }

                // ephemeral for Swift
                if language == .swift, isEphemeralSwiftType(cleaned) {
                    continue
                }
                if language == .swift, isSwiftSpecialType(cleaned) {
                    continue
                }
                if isPrimitiveType(cleaned, language: language) {
                    continue
                }
                if isContainerType(cleaned, language: language) {
                    continue
                }
                if language == .ts || language == .tsx,
                   cleaned == "React.Component" || cleaned == "React.PureComponent"
                {
                    continue
                }
                if isGenericPlaceholder(cleaned, language: language) {
                    continue
                }

                let lower = cleaned.lowercased()
                if ["untyped", "varargs", "enum", "union"].contains(lower) {
                    continue
                }

                if cleaned.hasSuffix(":") {
                    cleaned.removeLast()
                    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if !cleaned.isEmpty {
                    results.append(cleaned)
                }
            }
        }
        return Array(Set(results))
    }

    private static func filterOutPrimitiveAndSpecialTypesCached(
        _ extracted: [String],
        language: LanguageType,
        cache: inout [TypeCleanerCacheKey: [String]],
        stats: CodeMapPerformanceCollector?
    ) -> [String] {
        let filterStart = stats == nil ? 0 : CFAbsoluteTimeGetCurrent()
        defer {
            if let stats {
                recordTypeCleanerPhase(.filter, duration: CFAbsoluteTimeGetCurrent() - filterStart, stats: stats)
            }
        }
        var results: [String] = []

        for raw in extracted {
            let subTypes = expandTupleTypes(raw)
            for s in subTypes {
                var cleaned = stripUnbalancedParens(s).trimmingCharacters(in: .whitespacesAndNewlines)
                if language == .swift {
                    cleaned = stripSwiftTupleLabel(cleaned)
                } else if language == .ts || language == .tsx {
                    cleaned = stripTSParamLabelAndDefault(cleaned)
                }

                if language == .ts || language == .tsx, isTSLiteralType(cleaned) {
                    continue
                }

                if language == .ts || language == .tsx, cleaned.hasPrefix("{") {
                    let extractedObjectTypes = extractTSObjectLiteralTypesCached(
                        from: cleaned,
                        language: language,
                        cache: &cache,
                        stats: stats
                    )
                    results.append(contentsOf: extractedObjectTypes)
                    continue
                }
                if cleaned.contains("{") || cleaned.contains("}") || cleaned.contains("\n") {
                    continue
                }

                // ephemeral for Swift
                if language == .swift, isEphemeralSwiftType(cleaned) {
                    continue
                }
                if language == .swift, isSwiftSpecialType(cleaned) {
                    continue
                }
                if isPrimitiveType(cleaned, language: language) {
                    continue
                }
                if isContainerType(cleaned, language: language) {
                    continue
                }
                if language == .ts || language == .tsx,
                   cleaned == "React.Component" || cleaned == "React.PureComponent"
                {
                    continue
                }
                if isGenericPlaceholder(cleaned, language: language) {
                    continue
                }

                let lower = cleaned.lowercased()
                if ["untyped", "varargs", "enum", "union"].contains(lower) {
                    continue
                }

                if cleaned.hasSuffix(":") {
                    cleaned.removeLast()
                    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if !cleaned.isEmpty {
                    results.append(cleaned)
                }
            }
        }
        let dedupStart = stats == nil ? 0 : CFAbsoluteTimeGetCurrent()
        let deduped = Array(Set(results))
        if let stats {
            recordTypeCleanerPhase(.dedup, duration: CFAbsoluteTimeGetCurrent() - dedupStart, stats: stats)
        }
        return deduped
    }

    private static func isGenericPlaceholder(_ typeName: String, language: LanguageType) -> Bool {
        switch language {
        case .swift, .ts, .tsx:
            let trimmed = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count == 1, let first = trimmed.first, first.isUppercase {
                return true
            }
            return ["T", "U", "V", "K", "E", "R", "S"].contains(trimmed)
        default:
            return false
        }
    }

    static func isGenericPlaceholderTypeName(_ typeName: String, language: LanguageType) -> Bool {
        isGenericPlaceholder(typeName, language: language)
    }

    private static func stripSwiftTupleLabel(_ typeName: String) -> String {
        guard findTopLevelChar(in: typeName, char: ":") != nil else { return typeName }
        let parts = splitByTopLevelColon(typeName)
        guard let last = parts.last else { return typeName }
        return last.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTSParamLabelAndDefault(_ typeName: String) -> String {
        var cleaned = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("...") {
            cleaned = cleaned.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let eqIndex = findTopLevelChar(in: cleaned, char: "=") {
            cleaned = String(cleaned[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let colonIndex = findTopLevelChar(in: cleaned, char: ":") {
            if let questionIndex = findTopLevelChar(in: cleaned, char: "?"),
               questionIndex < colonIndex,
               cleaned.index(after: questionIndex) != colonIndex
            {
                // Likely a conditional type (T extends U ? X : Y) - don't treat ':' as a label
            } else {
                cleaned = String(cleaned[cleaned.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if cleaned.hasSuffix("?") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private static func isTSLiteralType(_ typeName: String) -> Bool {
        let trimmed = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if ["true", "false"].contains(trimmed.lowercased()) { return true }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
            || (trimmed.hasPrefix("`") && trimmed.hasSuffix("`"))
        {
            return true
        }
        if trimmed.hasSuffix("n"), Int(trimmed.dropLast()) != nil {
            return true
        }
        if Double(trimmed) != nil {
            return true
        }
        return false
    }

    private static func extractTSObjectLiteralTypes(from typeName: String, language: LanguageType) -> [String] {
        var cleaned = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("{") else { return [] }
        if cleaned.hasSuffix(";") || cleaned.hasSuffix(",") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.hasPrefix("{") { cleaned.removeFirst() }
        if cleaned.hasSuffix("}") { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return [] }

        let members = splitByTopLevelOperator(cleaned, operators: [";", ","])
        var results: [String] = []
        for member in members {
            let trimmed = member.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            var signature = trimmed
            if signature.hasPrefix("<"),
               let gtIndex = findMatchingAngleBracket(in: signature, startIndex: signature.startIndex)
            {
                signature = String(signature[signature.index(after: gtIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let parenIndex = findTopLevelChar(in: signature, char: "("),
               let closeIndex = findMatchingParenthesis(in: signature, startIndex: parenIndex)
            {
                if let colonBeforeParen = findTopLevelChar(in: signature, char: ":"),
                   colonBeforeParen < parenIndex
                {
                    // Property signature with a function type on the RHS; fall through to colon logic.
                } else {
                    let paramInner = signature[signature.index(after: parenIndex) ..< closeIndex]
                    let params = splitByTopLevelCommas(String(paramInner))
                    for param in params {
                        let normalized = stripTSParamLabelAndDefault(param)
                        if !normalized.isEmpty {
                            results.append(contentsOf: extractBaseTypes(from: normalized, language: language))
                        }
                    }
                    let afterParen = signature[signature.index(after: closeIndex)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !afterParen.isEmpty {
                        let afterParenString = String(afterParen)
                        if let arrowIndex = findTopLevelString(in: afterParenString, needle: "=>") {
                            let returnStart = afterParenString.index(arrowIndex, offsetBy: 2)
                            let returnType = afterParenString[returnStart...]
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !returnType.isEmpty {
                                results.append(contentsOf: extractBaseTypes(from: String(returnType), language: language))
                            }
                        } else if let colonIndex = findTopLevelChar(in: afterParenString, char: ":") {
                            let returnType = afterParenString[afterParenString.index(after: colonIndex)...]
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !returnType.isEmpty {
                                results.append(contentsOf: extractBaseTypes(from: String(returnType), language: language))
                            }
                        }
                    }
                    continue
                }
            }
            if let colonIndex = findTopLevelChar(in: trimmed, char: ":") {
                let after = trimmed[trimmed.index(after: colonIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty {
                    results.append(contentsOf: extractBaseTypes(from: String(after), language: language))
                }
            }
        }
        return results
    }

    private static func extractTSObjectLiteralTypesCached(
        from typeName: String,
        language: LanguageType,
        cache: inout [TypeCleanerCacheKey: [String]],
        stats: CodeMapPerformanceCollector?
    ) -> [String] {
        let objectLiteralStart = stats == nil ? 0 : CFAbsoluteTimeGetCurrent()
        defer {
            if let stats {
                recordTypeCleanerPhase(.tsObjectLiteral, duration: CFAbsoluteTimeGetCurrent() - objectLiteralStart, stats: stats)
            }
        }
        var cleaned = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("{") else { return [] }
        if cleaned.hasSuffix(";") || cleaned.hasSuffix(",") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.hasPrefix("{") { cleaned.removeFirst() }
        if cleaned.hasSuffix("}") { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return [] }

        let members = splitByTopLevelOperator(cleaned, operators: [";", ","])
        var results: [String] = []
        for member in members {
            let trimmed = member.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            var signature = trimmed
            if signature.hasPrefix("<"),
               let gtIndex = findMatchingAngleBracket(in: signature, startIndex: signature.startIndex)
            {
                signature = String(signature[signature.index(after: gtIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let parenIndex = findTopLevelChar(in: signature, char: "("),
               let closeIndex = findMatchingParenthesis(in: signature, startIndex: parenIndex)
            {
                if let colonBeforeParen = findTopLevelChar(in: signature, char: ":"),
                   colonBeforeParen < parenIndex
                {
                    // Property signature with a function type on the RHS; fall through to colon logic.
                } else {
                    let paramInner = signature[signature.index(after: parenIndex) ..< closeIndex]
                    let params = splitByTopLevelCommas(String(paramInner))
                    for param in params {
                        let normalized = stripTSParamLabelAndDefault(param)
                        if !normalized.isEmpty {
                            results.append(contentsOf: extractBaseTypesCached(from: normalized, language: language, cache: &cache, stats: stats))
                        }
                    }
                    let afterParen = signature[signature.index(after: closeIndex)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !afterParen.isEmpty {
                        let afterParenString = String(afterParen)
                        if let arrowIndex = findTopLevelString(in: afterParenString, needle: "=>") {
                            let returnStart = afterParenString.index(arrowIndex, offsetBy: 2)
                            let returnType = afterParenString[returnStart...]
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !returnType.isEmpty {
                                results.append(contentsOf: extractBaseTypesCached(from: String(returnType), language: language, cache: &cache, stats: stats))
                            }
                        } else if let colonIndex = findTopLevelChar(in: afterParenString, char: ":") {
                            let returnType = afterParenString[afterParenString.index(after: colonIndex)...]
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !returnType.isEmpty {
                                results.append(contentsOf: extractBaseTypesCached(from: String(returnType), language: language, cache: &cache, stats: stats))
                            }
                        }
                    }
                    continue
                }
            }
            if let colonIndex = findTopLevelChar(in: trimmed, char: ":") {
                let after = trimmed[trimmed.index(after: colonIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty {
                    results.append(contentsOf: extractBaseTypesCached(from: String(after), language: language, cache: &cache, stats: stats))
                }
            }
        }
        return results
    }

    private static func expandTupleTypes(_ rawType: String) -> [String] {
        let t = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("("), t.hasSuffix(")"), t.count >= 2 else {
            return [t]
        }
        let inner = t.dropFirst().dropLast()
        let parts = inner.split(separator: ",")
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func isEphemeralSwiftType(_ type: String) -> Bool {
        let lower = type.lowercased()
        return lower == "()" ||
            lower == "void" ||
            lower == "never" ||
            lower == "any"
    }

    private static func isSwiftSpecialType(_ type: String) -> Bool {
        let lower = type.lowercased()
        let base = lower.split(separator: ".").last.map(String.init) ?? lower
        return TypeCleanerSets.swiftSpecialTypes.contains(base)
    }

    static func isSwiftSpecialTypeName(_ typeName: String) -> Bool {
        isSwiftSpecialType(typeName)
    }

    static func isPrimitiveType(_ typeName: String, language: LanguageType) -> Bool {
        let lower = typeName.lowercased()
        switch language {
        case .swift:
            return TypeCleanerSets.swiftPrims.contains(lower)

        case .c_sharp:
            return TypeCleanerSets.csharpPrims.contains(lower)

        case .java:
            return TypeCleanerSets.javaPrims.contains(lower)

        case .dart:
            return TypeCleanerSets.dartPrims.contains(lower)

        case .c, .cpp:
            return TypeCleanerSets.cPrims.contains(lower)

        case .python:
            let typeWithoutGeneric = lower.components(separatedBy: "[").first ?? lower
            return TypeCleanerSets.pythonPrims.contains(typeWithoutGeneric)

        case .rust:
            return TypeCleanerSets.rustPrims.contains(lower)

        case .go:
            return TypeCleanerSets.goPrims.contains(lower)

        case .js:
            // define if needed
            return false

        case .ruby:
            return false

        case .php: // ➜ NEW
            return TypeCleanerSets.phpPrims.contains(lower)

        case .ts, .tsx:
            return TypeCleanerSets.tsPrims.contains(lower)
        }
    }

    static func isContainerType(_ typeName: String, language: LanguageType) -> Bool {
        let lower = typeName.lowercased()

        switch language {
        case .ts, .tsx:
            return TypeCleanerSets.universalContainers.contains(lower) || TypeCleanerSets.tsContainers.contains(lower)

        case .c_sharp:
            return TypeCleanerSets.universalContainers.contains(lower) || TypeCleanerSets.csharpContainers.contains(lower)

        case .java:
            return TypeCleanerSets.universalContainers.contains(lower) || TypeCleanerSets.javaContainers.contains(lower)

        case .dart:
            return TypeCleanerSets.universalContainers.contains(lower) || ["map", "list", "set"].contains(lower)

        case .c, .cpp:
            return TypeCleanerSets.universalContainers.contains(lower) || TypeCleanerSets.cppContainers.contains(lower)

        case .python:
            return TypeCleanerSets.universalContainers.contains(lower) || ["list", "dict", "set"].contains(lower)

        case .rust:
            return TypeCleanerSets.universalContainers.contains(lower) || TypeCleanerSets.rustContainers.contains(lower)

        case .go:
            return TypeCleanerSets.universalContainers.contains(lower) || (lower == "map")

        case .swift:
            return TypeCleanerSets.universalContainers.contains(lower) || TypeCleanerSets.swiftContainers.contains(lower)

        case .js:
            return false

        case .php: // ➜ NEW
            return TypeCleanerSets.universalContainers.contains(lower)

        case .ruby:
            return TypeCleanerSets.universalContainers.contains(lower)
        }
    }
}
