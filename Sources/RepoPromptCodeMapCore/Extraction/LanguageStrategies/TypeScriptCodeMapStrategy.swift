//
//  TypeScriptCodeMapStrategy.swift
//  RepoPrompt
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import SwiftTreeSitter

/// TypeScript/TSX-specific code map generation strategy.
/// Handles TS class/interface declarations and members using range-based containment.
/// Note: This strategy is for TS/TSX only - JS uses the default/legacy path.
enum TypeScriptCodeMapStrategy {
    // MARK: - TS Container Boundary

    /// Represents a TS container (class, interface) with its full range
    struct ContainerBoundary {
        enum Kind { case `class`, interface }
        let kind: Kind
        let name: String
        let range: NSRange
        let startLine: Int
    }

    // MARK: - Context

    /// Context built during the pre-pass phase
    struct Context {
        var containerBoundaries: [ContainerBoundary] = []
    }

    // MARK: - Pre-pass: Build Container Boundaries

    /// Builds TS container boundaries from captures using the capture index
    static func buildContext(
        index: CodeMapCaptureIndex,
        content: String,
        boundaries: [Int]
    ) -> Context {
        var ctx = Context()
        let nsContent = content as NSString

        func mapNamesToSmallestContainingDecl(
            nameCaps: [NamedRange],
            declCaps: [NamedRange]
        ) -> [NSRange: String] {
            var mapping: [NSRange: String] = [:]
            guard !nameCaps.isEmpty, !declCaps.isEmpty else { return mapping }

            let sortedDecls = declCaps.sorted { $0.range.location < $1.range.location }
            let sortedNames = nameCaps.sorted { $0.range.location < $1.range.location }

            var stack: [NamedRange] = []
            var declIndex = 0

            for nameCap in sortedNames {
                let name = nsContent.substring(with: nameCap.range)

                while declIndex < sortedDecls.count,
                      sortedDecls[declIndex].range.location <= nameCap.range.location
                {
                    stack.append(sortedDecls[declIndex])
                    declIndex += 1
                }

                while let last = stack.last,
                      NSMaxRange(last.range) <= nameCap.range.location
                {
                    stack.removeLast()
                }

                if let candidate = stack.last, rangeContains(candidate.range, nameCap.range) {
                    mapping[candidate.range] = name
                    continue
                }

                // Fallback scan (should be rare if ranges are nested)
                var bestDecl: NamedRange? = nil
                for decl in sortedDecls where rangeContains(decl.range, nameCap.range) {
                    if bestDecl == nil || decl.range.length < bestDecl!.range.length {
                        bestDecl = decl
                    }
                }
                if let decl = bestDecl {
                    mapping[decl.range] = name
                }
            }

            return mapping
        }

        // Collect class containers from ts.class.decl
        let classDeclCaps = index.captures(named: "ts.class.decl")
        let classNameCaps = index.captures(named: "type.class")
        let classNamesByRange = mapNamesToSmallestContainingDecl(
            nameCaps: classNameCaps,
            declCaps: classDeclCaps
        )
        for cap in classDeclCaps {
            if let className = classNamesByRange[cap.range] {
                let lineNo = lineNumber(for: cap.range.location, using: boundaries)
                ctx.containerBoundaries.append(ContainerBoundary(
                    kind: .class,
                    name: className,
                    range: cap.range,
                    startLine: lineNo
                ))
            }
        }

        // Collect interface containers from ts.interface.decl
        let ifaceDeclCaps = index.captures(named: "ts.interface.decl")
        let ifaceNameCaps = index.captures(named: "interface")
        let ifaceNamesByRange = mapNamesToSmallestContainingDecl(
            nameCaps: ifaceNameCaps,
            declCaps: ifaceDeclCaps
        )
        for cap in ifaceDeclCaps {
            if let ifaceName = ifaceNamesByRange[cap.range] {
                let lineNo = lineNumber(for: cap.range.location, using: boundaries)
                ctx.containerBoundaries.append(ContainerBoundary(
                    kind: .interface,
                    name: ifaceName,
                    range: cap.range,
                    startLine: lineNo
                ))
            }
        }

        // Sort by range location
        ctx.containerBoundaries.sort { $0.range.location < $1.range.location }

        return ctx
    }

    /// Checks if TS range containment should be used (has container boundaries)
    static func useRangeContainment(_ context: Context) -> Bool {
        !context.containerBoundaries.isEmpty
    }

    // MARK: - Capture Handling

    /// Handles a TS-specific capture. Returns true if handled, false to fall through to default handling.
    static func handleCapture(
        _ cap: NamedRange,
        context: Context,
        index: CodeMapCaptureIndex,
        content: String,
        nsContent: NSString,
        boundaries: [Int],
        lineNo: Int,
        language: LanguageType,
        getTrimmedLine: (NSRange) -> String,
        classesByLine: inout [Int: ClassInfo],
        interfaceBoundaries: inout [Int: InterfaceInfo],
        globalFunctions: inout [FunctionInfo],
        globalVariables: inout [VariableInfo],
        referencedTypes: inout ReferencedTypesAccumulator,
        extractionMemo: inout CodeMapExtractionMemo,
		perfStats: CodeMapPerformanceCollector? = nil,
        perfOptions: CodeMapPerfOptions = .disabled
    ) -> Bool {
		let activePerfStats = perfStats
		let activePerfOptions = perfOptions

        switch cap.name {
		// MARK: TS Class Members

        case "method":
            // TS class methods - use range-based containment
            let methodName = nsContent.substring(with: cap.range)
            let fullLine = getTrimmedLine(cap.range)
            let signatureLine = normalizeSignatureLine(fullLine, context: .functionLike, extractionMemo: &extractionMemo, perfStats: activePerfStats, perfOptions: activePerfOptions)
            let effectiveLine = signatureLine.isEmpty ? fullLine : signatureLine
            let parsed = parseFunctionInfo(effectiveLine, fallbackName: methodName, language: language, referencedTypes: &referencedTypes, extractionMemo: &extractionMemo, perfStats: activePerfStats)

            // Find enclosing class by range containment
            if let enclosingClass = enclosingContainer(for: cap.range, in: context.containerBoundaries, kind: .class) {
                ensureClassEntry(enclosingClass, classesByLine: &classesByLine)
                let fnInfo = FunctionInfo(
                    name: parsed.name,
                    parameters: parsed.parameters,
                    returnType: parsed.returnType,
                    definitionLine: effectiveLine,
                    lineNumber: lineNo
                )
                // BUG FIX #3: Dedupe by definitionLine (not name) to preserve TS overloads
                if !classesByLine[enclosingClass.startLine]!.methods.contains(where: { $0.definitionLine == effectiveLine }) {
                    classesByLine[enclosingClass.startLine]?.methods.append(fnInfo)
                }
            }
            // Note: If no enclosing class, don't add - let it fall through or be ignored
            return true

        case "variable.field":
            // TS class fields - use range-based containment
            let fullLine = getTrimmedLine(cap.range)
            let signatureLine = normalizeSignatureLine(fullLine, context: .statementLike, extractionMemo: &extractionMemo, perfStats: activePerfStats, perfOptions: activePerfOptions)
            let effectiveLine = stripTSInitializer(signatureLine.isEmpty ? fullLine : signatureLine)
            let propType = parsePropertyType(effectiveLine, language: language, referencedTypes: &referencedTypes, extractionMemo: &extractionMemo, perfStats: activePerfStats)

            // Find enclosing class by range containment
            if let enclosingClass = enclosingContainer(for: cap.range, in: context.containerBoundaries, kind: .class) {
                let propInfo = PropertyInfo(name: effectiveLine, typeName: propType)
                ensureClassEntry(enclosingClass, classesByLine: &classesByLine)
                if !classesByLine[enclosingClass.startLine]!.properties.contains(where: { $0.name == effectiveLine }) {
                    classesByLine[enclosingClass.startLine]?.properties.append(propInfo)
                }
            }
            return true

		// MARK: TS Interface Members

        case "method_signature":
            // TS interface method - use range-based containment
            let methodName = nsContent.substring(with: cap.range)
            let fullLine = getTrimmedLine(cap.range)
            let signatureLine = normalizeSignatureLine(fullLine, context: .functionLike, extractionMemo: &extractionMemo, perfStats: activePerfStats, perfOptions: activePerfOptions)
            let effectiveLine = signatureLine.isEmpty ? fullLine : signatureLine
            let parsed = parseFunctionInfo(effectiveLine, fallbackName: methodName, language: language, referencedTypes: &referencedTypes, extractionMemo: &extractionMemo, perfStats: activePerfStats)

            if let enclosingIface = enclosingContainer(for: cap.range, in: context.containerBoundaries, kind: .interface) {
                let fnInfo = FunctionInfo(
                    name: parsed.name,
                    parameters: parsed.parameters,
                    returnType: parsed.returnType,
                    definitionLine: effectiveLine,
                    lineNumber: lineNo
                )
                ensureInterfaceEntry(enclosingIface, interfaceBoundaries: &interfaceBoundaries)
                if !interfaceBoundaries[enclosingIface.startLine]!.methods.contains(where: { $0.definitionLine == effectiveLine }) {
                    interfaceBoundaries[enclosingIface.startLine]?.methods.append(fnInfo)
                }
            }
            return true

        case "property_signature":
            // TS interface property - use range-based containment
            let fullLine = getTrimmedLine(cap.range)
            let signatureLine = normalizeSignatureLine(fullLine, context: .statementLike, extractionMemo: &extractionMemo, perfStats: activePerfStats, perfOptions: activePerfOptions)
            let effectiveLine = stripTSInitializer(signatureLine.isEmpty ? fullLine : signatureLine)
            let propType = parsePropertyType(effectiveLine, language: language, referencedTypes: &referencedTypes, extractionMemo: &extractionMemo, perfStats: activePerfStats)

            if let enclosingIface = enclosingContainer(for: cap.range, in: context.containerBoundaries, kind: .interface) {
                // Use fullLine for the name to capture the full property signature
                let propInfo = PropertyInfo(name: effectiveLine, typeName: propType)
                ensureInterfaceEntry(enclosingIface, interfaceBoundaries: &interfaceBoundaries)
                if !interfaceBoundaries[enclosingIface.startLine]!.properties.contains(where: { $0.name == effectiveLine }) {
                    interfaceBoundaries[enclosingIface.startLine]?.properties.append(propInfo)
                }
            }
            return true

        case "call_signature", "construct_signature", "index_signature":
            // TS interface signatures - use range-based containment
            let fullLine = getTrimmedLine(cap.range)
            let signatureLine = normalizeSignatureLine(fullLine, context: .functionLike, extractionMemo: &extractionMemo, perfStats: activePerfStats, perfOptions: activePerfOptions)
            let effectiveLine = signatureLine.isEmpty ? fullLine : signatureLine
            let fallbackName: String = switch cap.name {
            case "call_signature":
                "call"
            case "construct_signature":
                "new"
            case "index_signature":
                "index"
            default:
                nsContent.substring(with: cap.range)
            }
            let parsed = parseFunctionInfo(effectiveLine, fallbackName: fallbackName, language: language, referencedTypes: &referencedTypes, extractionMemo: &extractionMemo, perfStats: activePerfStats)

            if let enclosingIface = enclosingContainer(for: cap.range, in: context.containerBoundaries, kind: .interface) {
                let fnInfo = FunctionInfo(
                    name: parsed.name,
                    parameters: parsed.parameters,
                    returnType: parsed.returnType,
                    definitionLine: effectiveLine,
                    lineNumber: lineNo
                )
                ensureInterfaceEntry(enclosingIface, interfaceBoundaries: &interfaceBoundaries)
                if !interfaceBoundaries[enclosingIface.startLine]!.methods.contains(where: { $0.definitionLine == effectiveLine }) {
                    interfaceBoundaries[enclosingIface.startLine]?.methods.append(fnInfo)
                }
            }
            return true

	// MARK: TS Container Declarations (skip - handled in buildContext)

        case "ts.class.decl", "ts.interface.decl":
            let declLine = getTrimmedLine(cap.range)
            let heritageTypes = extractTSHeritageTypes(from: declLine)
            if !heritageTypes.isEmpty {
                referencedTypes.insertMany(rawTypes: heritageTypes)
            }
            return true

        default:
            return false
        }
    }

    // MARK: - Helpers

    /// Finds the smallest enclosing container for a given range
    private static func enclosingContainer(
        for range: NSRange,
        in containerBoundaries: [ContainerBoundary],
        kind: ContainerBoundary.Kind? = nil
    ) -> ContainerBoundary? {
        let endIdx = containerBoundaries.binarySearch { $0.range.location <= range.location }
        guard endIdx > 0 else { return nil }

        var smallestContaining: ContainerBoundary? = nil
        for i in stride(from: endIdx - 1, through: 0, by: -1) {
            let boundary = containerBoundaries[i]
            if let k = kind, boundary.kind != k { continue }
            if rangeContains(boundary.range, range),
               smallestContaining == nil || isBetter(boundary.range, than: smallestContaining!.range)
            {
                smallestContaining = boundary
            }
        }
        return smallestContaining
    }

    private static func isBetter(_ candidate: NSRange, than current: NSRange) -> Bool {
        if candidate.length != current.length {
			return candidate.length < current.length
        }
        return candidate.location < current.location
    }

    /// Checks if inner range is fully contained within outer range
    private static func rangeContains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location &&
            NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// Returns the 1-indexed line number for a given location using precomputed boundaries
    private static func lineNumber(for location: Int, using boundaries: [Int]) -> Int {
        CodeMapGenerator.lineNumber(for: location, using: boundaries)
    }

    private static func ensureClassEntry(_ boundary: ContainerBoundary, classesByLine: inout [Int: ClassInfo]) {
        if classesByLine[boundary.startLine] == nil {
            classesByLine[boundary.startLine] = ClassInfo(name: boundary.name, methods: [], properties: [])
        }
    }

    private static func ensureInterfaceEntry(_ boundary: ContainerBoundary, interfaceBoundaries: inout [Int: InterfaceInfo]) {
        if interfaceBoundaries[boundary.startLine] == nil {
            interfaceBoundaries[boundary.startLine] = InterfaceInfo(name: boundary.name, properties: [], methods: [])
        }
    }

    private static func parseFunctionInfo(
        _ line: String,
        fallbackName: String,
        language: LanguageType,
        referencedTypes: inout ReferencedTypesAccumulator,
        extractionMemo: inout CodeMapExtractionMemo,
		perfStats: CodeMapPerformanceCollector? = nil
    ) -> (name: String, parameters: [ParameterInfo], returnType: String?) {
		let activePerfStats = perfStats
        guard let match = extractionMemo.matchFunctionLineParsed(line, language: language, stats: activePerfStats) else {
            return (fallbackName, [], nil)
        }

        let name = match.name?.isEmpty == false ? match.name! : fallbackName
        let returnType = match.returnType
        if let rt = returnType, !rt.isEmpty {
            referencedTypes.insert(rawType: rt)
        }

        let types = match.parameterTypes ?? []
        let parameters = types.enumerated().map {
            ParameterInfo(
                externalName: nil,
                localName: "param\($0.offset)",
                typeName: $0.element
            )
        }
        referencedTypes.insertMany(rawTypes: types)

        return (name, parameters, returnType)
    }

    private static func parsePropertyType(
        _ line: String,
        language: LanguageType,
        referencedTypes: inout ReferencedTypesAccumulator,
        extractionMemo: inout CodeMapExtractionMemo,
		perfStats: CodeMapPerformanceCollector? = nil
    ) -> String? {
		let activePerfStats = perfStats
        if language == .ts || language == .tsx {
            if let typeName = extractionMemo.tsTypeAnnotation(from: line, stats: activePerfStats) {
                activePerfStats?.tsTypeAnnotationFastPathHits += 1
                referencedTypes.insert(rawType: typeName)
                return typeName
            }
        }
        guard let match = extractionMemo.matchVariableLine(line, language: language, stats: activePerfStats),
              let typeName = match["type"],
              !typeName.isEmpty
        else {
            return nil
        }
        referencedTypes.insert(rawType: typeName)
        return typeName
    }

    private static func normalizeSignatureLine(
        _ line: String,
        context: JSTSSignatureContext,
        extractionMemo: inout CodeMapExtractionMemo,
		perfStats: CodeMapPerformanceCollector? = nil,
        perfOptions: CodeMapPerfOptions = .disabled
    ) -> String {
		let activePerfStats = perfStats
		let activePerfOptions = perfOptions
        let extracted = extractionMemo.jstsSignature(
            from: line,
            context: context,
            perfStats: activePerfStats,
            perfOptions: activePerfOptions
        )
        return extracted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTSInitializer(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eqIndex = findTopLevelAssignmentEquals(in: trimmed) {
            return String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func stripTSParamLabelAndDefault(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("...") {
            cleaned = cleaned.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let eqIndex = findTopLevelAssignmentEquals(in: cleaned) {
            cleaned = String(cleaned[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let colonIndex = findTopLevelChar(in: cleaned, char: ":") {
            if let questionIndex = findTopLevelChar(in: cleaned, char: "?"),
               questionIndex < colonIndex,
               cleaned.index(after: questionIndex) != colonIndex
            {
                // Likely a conditional type - keep as-is.
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

    private static func splitTopLevelCommas(_ input: String) -> [String] {
        TopLevelScanner
            .splitTopLevel(input, separator: ",", track: .all)
            .map { input[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func findTopLevelAssignmentEquals(in input: String) -> String.Index? {
        var angleDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var squareDepth = 0
        var i = input.startIndex
        while i < input.endIndex {
            let ch = input[i]
            switch ch {
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            case "[": squareDepth += 1
            case "]": squareDepth = max(0, squareDepth - 1)
            case "=":
                if angleDepth == 0, parenDepth == 0, braceDepth == 0, squareDepth == 0 {
                    let next = input.index(after: i)
					if next < input.endIndex {
                        let nextChar = input[next]
                        if nextChar == ">" || nextChar == "=" {
                            i = next
                            continue
                        }
                    }
                    return i
                }
            default: break
            }
            i = input.index(after: i)
        }
        return nil
    }

    private static func extractTSHeritageTypes(from declLine: String) -> [String] {
        let trimmed = declLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let head: String = if let braceIndex = TopLevelScanner.firstTopLevelIndex(of: "{", in: trimmed, track: .all) {
            String(trimmed[..<braceIndex])
        } else {
            trimmed
        }
        var results: [String] = []
        var angleDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var squareDepth = 0
        var segmentStart: String.Index? = nil
        var i = head.startIndex

        func flushSegment(_ end: String.Index) {
            guard let startIndex = segmentStart else { return }
            let segment = head[startIndex ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                results.append(contentsOf: splitTopLevelCommas(String(segment)))
            }
            segmentStart = nil
        }

        func matchKeyword(_ keyword: String, at index: String.Index) -> Bool {
            guard head[index...].hasPrefix(keyword) else { return false }
            if index > head.startIndex {
                let before = head[head.index(before: index)]
                if !before.isWhitespace { return false }
            }
            let endIndex = head.index(index, offsetBy: keyword.count)
            if endIndex < head.endIndex {
                let after = head[endIndex]
                if !after.isWhitespace { return false }
            }
            return true
        }

        func skipWhitespace(from index: String.Index) -> String.Index {
            var cursor = index
            while cursor < head.endIndex, head[cursor].isWhitespace {
                cursor = head.index(after: cursor)
            }
            return cursor
        }

        while i < head.endIndex {
            let ch = head[i]
            switch ch {
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            case "[": squareDepth += 1
            case "]": squareDepth = max(0, squareDepth - 1)
            default: break
            }

            if angleDepth == 0, parenDepth == 0, braceDepth == 0, squareDepth == 0 {
                let isExtends = matchKeyword("extends", at: i)
                let isImplements = !isExtends && matchKeyword("implements", at: i)
                if isExtends || isImplements {
                    if segmentStart != nil {
                        flushSegment(i)
                    }
                    let keywordLength = isExtends ? "extends".count : "implements".count
                    let afterKeyword = head.index(i, offsetBy: keywordLength)
                    segmentStart = skipWhitespace(from: afterKeyword)
                    i = afterKeyword
                    continue
                }
            }
            i = head.index(after: i)
        }

        flushSegment(head.endIndex)
        return results
    }

    private static func findTopLevelChar(in input: String, char: Character) -> String.Index? {
        TopLevelScanner.firstTopLevelIndex(of: char, in: input, track: .all)
    }
}

private extension Array {
    /// Returns the index of the first element where the predicate returns false.
    func binarySearch(predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
