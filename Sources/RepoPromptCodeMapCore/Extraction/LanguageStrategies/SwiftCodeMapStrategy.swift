//
//  SwiftCodeMapStrategy.swift
//  RepoPrompt
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import SwiftTreeSitter

/// Swift-specific code map generation strategy.
/// Handles Swift type declarations, protocols, functions, and properties using range-based containment.
enum SwiftCodeMapStrategy {
    // MARK: - Swift Type Boundary

    /// Represents a Swift type container (class, struct, enum, actor, extension, protocol) with its full range
    struct TypeBoundary {
        enum Kind: String { case `class`, `struct`, `enum`, actor, `extension`, `protocol` }
        let kind: Kind
        let name: String
        let range: NSRange
        let isProtocol: Bool
        let startLine: Int

        init(kind: Kind, name: String, range: NSRange, startLine: Int) {
            self.kind = kind
            self.name = name
            self.range = range
            isProtocol = (kind == .protocol)
            self.startLine = startLine
        }
    }

    // MARK: - Context

    /// Context built during the pre-pass phase
    struct Context {
        var typeBoundaries: [TypeBoundary] = []
        var typeNamesByRange: [NSRange: String] = [:]
        var protocolNamesByRange: [NSRange: String] = [:]
        var functionCaptures: [NamedRange] = []
    }

    private enum SwiftStrategyAttributionCategory {
        case functionSignature
        case functionNameLookup
        case parameterExtraction
        case returnTypeExtraction
        case propertyDeclaration
        case propertyTypeExtraction
        case enclosingTypeLookup
        case modelInsertion
        case contextOnly
    }

    private static func record(
        _ category: SwiftStrategyAttributionCategory,
        duration: TimeInterval,
        count: Int = 1,
		perfStats: CodeMapPerformanceCollector?
    ) {
        guard let perfStats else { return }
        switch category {
        case .functionSignature:
            perfStats.swiftStrategyFunctionSignatureDuration += duration
            perfStats.swiftStrategyFunctionSignatureCount += count
        case .functionNameLookup:
            perfStats.swiftStrategyFunctionNameLookupDuration += duration
            perfStats.swiftStrategyFunctionNameLookupCount += count
        case .parameterExtraction:
            perfStats.swiftStrategyParameterExtractionDuration += duration
            perfStats.swiftStrategyParameterExtractionCount += count
        case .returnTypeExtraction:
            perfStats.swiftStrategyReturnTypeExtractionDuration += duration
            perfStats.swiftStrategyReturnTypeExtractionCount += count
        case .propertyDeclaration:
            perfStats.swiftStrategyPropertyDeclarationDuration += duration
            perfStats.swiftStrategyPropertyDeclarationCount += count
        case .propertyTypeExtraction:
            perfStats.swiftStrategyPropertyTypeExtractionDuration += duration
            perfStats.swiftStrategyPropertyTypeExtractionCount += count
        case .enclosingTypeLookup:
            perfStats.swiftStrategyEnclosingTypeLookupDuration += duration
            perfStats.swiftStrategyEnclosingTypeLookupCount += count
        case .modelInsertion:
            perfStats.swiftStrategyModelInsertionDuration += duration
            perfStats.swiftStrategyModelInsertionCount += count
        case .contextOnly:
            perfStats.swiftStrategyContextOnlyDuration += duration
            perfStats.swiftStrategyContextOnlyCount += count
        }
    }

    // MARK: - Pre-pass: Build Type Boundaries

    /// Builds Swift type boundaries from captures using the capture index
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

            var stack: [NamedRange] = []
            var declIndex = 0

            for nameCap in nameCaps {
                let name = nsContent.substring(with: nameCap.range)

                while declIndex < declCaps.count,
                      declCaps[declIndex].range.location <= nameCap.range.location
                {
                    stack.append(declCaps[declIndex])
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
                for decl in declCaps where rangeContains(decl.range, nameCap.range) {
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

        // First pass: collect type names
        let typeDeclCaps = index.captures(named: "swift.type.decl")
        let typeNameCaps = index.captures(named: "swift.type.name")
        ctx.typeNamesByRange = mapNamesToSmallestContainingDecl(
            nameCaps: typeNameCaps,
            declCaps: typeDeclCaps
        )

        // Second pass: build boundaries with full ranges
        for cap in typeDeclCaps {
            if let name = ctx.typeNamesByRange[cap.range] {
                let declText = nsContent.substring(with: cap.range)
                let kind: TypeBoundary.Kind

                    // Determine kind by checking declaration text
                    = if declText.hasPrefix("enum ") || declText.contains(" enum ")
                {
                    .enum
                } else if declText.hasPrefix("struct ") || declText.contains(" struct ") {
                    .struct
                } else if declText.hasPrefix("actor ") || declText.contains(" actor ") {
                    .actor
                } else if declText.hasPrefix("extension ") || declText.contains(" extension ") {
                    .extension
                } else if declText.hasPrefix("protocol ") || declText.contains(" protocol ") {
                    .protocol
                } else {
                    .class
                }

                let lineNo = lineNumber(for: cap.range.location, using: boundaries)
                ctx.typeBoundaries.append(TypeBoundary(kind: kind, name: name, range: cap.range, startLine: lineNo))
            }
        }

        // Also collect protocols
        let protocolDeclCaps = index.captures(named: "swift.protocol.decl")
        let protocolNameCaps = index.captures(named: "swift.protocol.name")
        ctx.protocolNamesByRange = mapNamesToSmallestContainingDecl(
            nameCaps: protocolNameCaps,
            declCaps: protocolDeclCaps
        )

        for cap in protocolDeclCaps {
            if let name = ctx.protocolNamesByRange[cap.range] {
                let lineNo = lineNumber(for: cap.range.location, using: boundaries)
                ctx.typeBoundaries.append(TypeBoundary(kind: .protocol, name: name, range: cap.range, startLine: lineNo))
            }
        }

        let topLevelFunctionCaps = index.captures(named: "swift.function.toplevel")
        let methodFunctionCaps = index.captures(named: "swift.function.method")
        let protocolFunctionCaps = index.captures(named: "swift.protocol.method")
        ctx.functionCaptures.reserveCapacity(
            topLevelFunctionCaps.count + methodFunctionCaps.count + protocolFunctionCaps.count
        )
        ctx.functionCaptures.append(contentsOf: topLevelFunctionCaps)
        ctx.functionCaptures.append(contentsOf: methodFunctionCaps)
        ctx.functionCaptures.append(contentsOf: protocolFunctionCaps)
        ctx.functionCaptures.sort { $0.range.location < $1.range.location }

        // Sort boundaries by range location
        ctx.typeBoundaries.sort { $0.range.location < $1.range.location }

        return ctx
    }

    // MARK: - Swift Signature Extraction

    private struct SwiftFunctionSignature {
        let definitionLine: String
        let signatureEnd: Int
    }

    /// Extracts only the function signature (up to but not including `{`) from a Swift function capture range.
    /// Uses `signatureEndLocation` to correctly handle strings, comments, and nesting.
    private static func extractSwiftFunctionSignature(
        from functionRange: NSRange,
        nsContent: NSString,
        boundaries: [Int]
    ) -> SwiftFunctionSignature {
        let signatureEnd = signatureEndLocation(forFunctionRange: functionRange, nsContent: nsContent)
        let signatureLength = signatureEnd - functionRange.location
        let signatureRange = NSRange(location: functionRange.location, length: signatureLength)

        // Get the signature text
        var signature = nsContent.substring(with: signatureRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize whitespace (collapse multiple whitespace to single space)
        signature = signature.replacing(#/\s+/#, with: " ")

        return SwiftFunctionSignature(definitionLine: signature, signatureEnd: signatureEnd)
    }

    // MARK: - Capture Handling

    /// Handles a Swift-specific capture. Returns true if handled, false to fall through to default handling.
    static func handleCapture(
        _ cap: NamedRange,
        context: Context,
        index: CodeMapCaptureIndex,
        content: String,
        nsContent: NSString,
        boundaries: [Int],
        lineNo: Int,
        classesByLine: inout [Int: ClassInfo],
        interfaceBoundaries: inout [Int: InterfaceInfo],
        globalFunctions: inout [FunctionInfo],
        globalVariables: inout [VariableInfo],
        referencedTypes: inout ReferencedTypesAccumulator,
        captureDeclaration: (NSRange, Character) -> String,
		perfStats: CodeMapPerformanceCollector? = nil
    ) -> Bool {
		let activePerfStats = perfStats
        let perfEnabled = activePerfStats != nil

        switch cap.name {
		// MARK: Swift Functions

        case "swift.function.toplevel":
            // Top-level Swift functions go directly to globalFunctions
            // Use Swift-specific signature extraction to avoid semicolon heuristic issues
            let signatureStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let signature = extractSwiftFunctionSignature(from: cap.range, nsContent: nsContent, boundaries: boundaries)
            if perfEnabled {
                record(.functionSignature, duration: CFAbsoluteTimeGetCurrent() - signatureStart, perfStats: activePerfStats)
            }
            let decl = signature.definitionLine

            // Find the function name from swift.function.name capture
            let nameLookupStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            var fnName = decl
            if let nameCap = index.firstCapture(named: "swift.function.name", containedIn: cap.range) {
                fnName = nsContent.substring(with: nameCap.range)
            }
            if perfEnabled {
                record(.functionNameLookup, duration: CFAbsoluteTimeGetCurrent() - nameLookupStart, perfStats: activePerfStats)
            }

            // Build parameters from swift.param.* captures
            let parameterStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let params = extractSwiftParameters(
                from: cap.range,
                signatureEnd: signature.signatureEnd,
                context: context,
                index: index,
                nsContent: nsContent,
                referencedTypes: &referencedTypes
            )
            if perfEnabled {
                record(.parameterExtraction, duration: CFAbsoluteTimeGetCurrent() - parameterStart, perfStats: activePerfStats)
            }

            let returnTypeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let returnType = extractSwiftReturnType(from: decl, perfStats: activePerfStats)
            if let typeName = returnType {
                referencedTypes.insert(rawType: typeName)
            }
            if perfEnabled {
                record(.returnTypeExtraction, duration: CFAbsoluteTimeGetCurrent() - returnTypeStart, perfStats: activePerfStats)
            }
            let modelInsertionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let fnInfo = FunctionInfo(
                name: fnName,
                parameters: params,
                returnType: returnType,
                definitionLine: decl,
                lineNumber: lineNo
            )

            if !globalFunctions.contains(where: { $0.definitionLine == decl }) {
                globalFunctions.append(fnInfo)
            }
            if perfEnabled {
                record(.modelInsertion, duration: CFAbsoluteTimeGetCurrent() - modelInsertionStart, perfStats: activePerfStats)
            }
            if let activePerfStats {
                activePerfStats.swiftStrategyHandledFunctionCount += 1
            }
            return true

        case "swift.function.method":
            // Swift methods - use range-based containment to find enclosing type
            // Use Swift-specific signature extraction to avoid semicolon heuristic issues
            let signatureStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let signature = extractSwiftFunctionSignature(from: cap.range, nsContent: nsContent, boundaries: boundaries)
            if perfEnabled {
                record(.functionSignature, duration: CFAbsoluteTimeGetCurrent() - signatureStart, perfStats: activePerfStats)
            }
            let decl = signature.definitionLine

            // Find the function name
            let nameLookupStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            var fnName = decl
            if let nameCap = index.firstCapture(named: "swift.function.name", containedIn: cap.range) {
                fnName = nsContent.substring(with: nameCap.range)
            }
            if perfEnabled {
                record(.functionNameLookup, duration: CFAbsoluteTimeGetCurrent() - nameLookupStart, perfStats: activePerfStats)
            }

            // Build parameters
            let parameterStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let params = extractSwiftParameters(
                from: cap.range,
                signatureEnd: signature.signatureEnd,
                context: context,
                index: index,
                nsContent: nsContent,
                referencedTypes: &referencedTypes
            )
            if perfEnabled {
                record(.parameterExtraction, duration: CFAbsoluteTimeGetCurrent() - parameterStart, perfStats: activePerfStats)
            }

            let returnTypeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let returnType = extractSwiftReturnType(from: decl, perfStats: activePerfStats)
            if let typeName = returnType {
                referencedTypes.insert(rawType: typeName)
            }
            if perfEnabled {
                record(.returnTypeExtraction, duration: CFAbsoluteTimeGetCurrent() - returnTypeStart, perfStats: activePerfStats)
            }
            // Find enclosing type by range containment
            let enclosingTypeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let resolvedEnclosingType = enclosingType(for: cap.range, in: context.typeBoundaries)
            if perfEnabled {
                record(.enclosingTypeLookup, duration: CFAbsoluteTimeGetCurrent() - enclosingTypeStart, perfStats: activePerfStats)
            }
            let modelInsertionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let fnInfo = FunctionInfo(
                name: fnName,
                parameters: params,
                returnType: returnType,
                definitionLine: decl,
                lineNumber: lineNo
            )

            if let enclosingType = resolvedEnclosingType {
                let lineNo = enclosingType.startLine
                if classesByLine[lineNo] == nil {
                    classesByLine[lineNo] = ClassInfo(name: enclosingType.name, methods: [], properties: [])
                }
                if !classesByLine[lineNo]!.methods.contains(where: { $0.definitionLine == decl }) {
                    classesByLine[lineNo]?.methods.append(fnInfo)
                }
            } else {
                // Fallback: treat as global if no enclosing type found
                if !globalFunctions.contains(where: { $0.definitionLine == decl }) {
                    globalFunctions.append(fnInfo)
                }
            }
            if perfEnabled {
                record(.modelInsertion, duration: CFAbsoluteTimeGetCurrent() - modelInsertionStart, perfStats: activePerfStats)
            }
            if let activePerfStats {
                activePerfStats.swiftStrategyHandledFunctionCount += 1
            }
            return true

        case "swift.protocol.method":
            // Protocol methods go to interfaces
            // Use Swift-specific signature extraction to avoid semicolon heuristic issues
            let signatureStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let signature = extractSwiftFunctionSignature(from: cap.range, nsContent: nsContent, boundaries: boundaries)
            if perfEnabled {
                record(.functionSignature, duration: CFAbsoluteTimeGetCurrent() - signatureStart, perfStats: activePerfStats)
            }
            let decl = signature.definitionLine
            let nameLookupStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            var fnName = decl
            if let nameCap = index.firstCapture(named: "swift.function.name", containedIn: cap.range) {
                fnName = nsContent.substring(with: nameCap.range)
            }
            if perfEnabled {
                record(.functionNameLookup, duration: CFAbsoluteTimeGetCurrent() - nameLookupStart, perfStats: activePerfStats)
            }

            let parameterStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let params = extractSwiftParameters(
                from: cap.range,
                signatureEnd: signature.signatureEnd,
                context: context,
                index: index,
                nsContent: nsContent,
                referencedTypes: &referencedTypes
            )
            if perfEnabled {
                record(.parameterExtraction, duration: CFAbsoluteTimeGetCurrent() - parameterStart, perfStats: activePerfStats)
            }
            let returnTypeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let returnType = extractSwiftReturnType(from: decl, perfStats: activePerfStats)
            if let typeName = returnType {
                referencedTypes.insert(rawType: typeName)
            }
            if perfEnabled {
                record(.returnTypeExtraction, duration: CFAbsoluteTimeGetCurrent() - returnTypeStart, perfStats: activePerfStats)
            }
            // Find enclosing protocol
            let enclosingTypeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let resolvedEnclosingProto = enclosingType(for: cap.range, in: context.typeBoundaries)
            if perfEnabled {
                record(.enclosingTypeLookup, duration: CFAbsoluteTimeGetCurrent() - enclosingTypeStart, perfStats: activePerfStats)
            }
            let modelInsertionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let fnInfo = FunctionInfo(
                name: fnName,
                parameters: params,
                returnType: returnType,
                definitionLine: decl,
                lineNumber: lineNo
            )

            if let enclosingProto = resolvedEnclosingProto, enclosingProto.isProtocol {
                let lineNo = enclosingProto.startLine
                if interfaceBoundaries[lineNo] == nil {
                    interfaceBoundaries[lineNo] = InterfaceInfo(name: enclosingProto.name, properties: [], methods: [])
                }
                interfaceBoundaries[lineNo]?.methods.append(fnInfo)
            }
            if perfEnabled {
                record(.modelInsertion, duration: CFAbsoluteTimeGetCurrent() - modelInsertionStart, perfStats: activePerfStats)
            }
            if let activePerfStats {
                activePerfStats.swiftStrategyHandledFunctionCount += 1
            }
            return true

		// MARK: Swift Properties

        case "swift.property.toplevel":
            // Top-level Swift properties go to globalVariables
            let propertyDeclarationStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let fullDecl = extractSwiftPropertyDeclaration(from: cap.range, index: index, nsContent: nsContent, fallback: {
                captureDeclaration(cap.range, "{")
            })
            if perfEnabled {
                record(.propertyDeclaration, duration: CFAbsoluteTimeGetCurrent() - propertyDeclarationStart, perfStats: activePerfStats)
            }
            let propertyTypeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let propType = extractSwiftPropertyType(from: fullDecl, perfStats: activePerfStats)
            if let typeName = propType {
                referencedTypes.insert(rawType: typeName)
            }
            if perfEnabled {
                record(.propertyTypeExtraction, duration: CFAbsoluteTimeGetCurrent() - propertyTypeStart, perfStats: activePerfStats)
            }
            let modelInsertionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let varInfo = VariableInfo(name: fullDecl, typeName: propType, definitionLine: fullDecl)

            if !globalVariables.contains(where: { $0.definitionLine == fullDecl }) {
                globalVariables.append(varInfo)
            }
            if perfEnabled {
                record(.modelInsertion, duration: CFAbsoluteTimeGetCurrent() - modelInsertionStart, perfStats: activePerfStats)
            }
            if let activePerfStats {
                activePerfStats.swiftStrategyHandledPropertyCount += 1
            }
            return true

        case "swift.property.member":
            // Swift member properties - use range-based containment
            let propertyDeclarationStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let fullDecl = extractSwiftPropertyDeclaration(from: cap.range, index: index, nsContent: nsContent, fallback: {
                captureDeclaration(cap.range, "{")
            })
            if perfEnabled {
                record(.propertyDeclaration, duration: CFAbsoluteTimeGetCurrent() - propertyDeclarationStart, perfStats: activePerfStats)
            }
            let propertyTypeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let propType = extractSwiftPropertyType(from: fullDecl, perfStats: activePerfStats)
            if let typeName = propType {
                referencedTypes.insert(rawType: typeName)
            }
            if perfEnabled {
                record(.propertyTypeExtraction, duration: CFAbsoluteTimeGetCurrent() - propertyTypeStart, perfStats: activePerfStats)
            }

            let enclosingTypeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let resolvedEnclosingType = enclosingType(for: cap.range, in: context.typeBoundaries)
            if perfEnabled {
                record(.enclosingTypeLookup, duration: CFAbsoluteTimeGetCurrent() - enclosingTypeStart, perfStats: activePerfStats)
            }
            let modelInsertionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            if let enclosingType = resolvedEnclosingType {
                let lineNo = enclosingType.startLine
                if classesByLine[lineNo] == nil {
                    classesByLine[lineNo] = ClassInfo(name: enclosingType.name, methods: [], properties: [])
                }
                let propInfo = PropertyInfo(name: fullDecl, typeName: propType)
                if !classesByLine[lineNo]!.properties.contains(where: { $0.name == fullDecl }) {
                    classesByLine[lineNo]?.properties.append(propInfo)
                }
            } else {
                // Fallback: treat as global if no enclosing type found
                let varInfo = VariableInfo(name: fullDecl, typeName: propType, definitionLine: fullDecl)
                if !globalVariables.contains(where: { $0.definitionLine == fullDecl }) {
                    globalVariables.append(varInfo)
                }
            }
            if perfEnabled {
                record(.modelInsertion, duration: CFAbsoluteTimeGetCurrent() - modelInsertionStart, perfStats: activePerfStats)
            }
            if let activePerfStats {
                activePerfStats.swiftStrategyHandledPropertyCount += 1
            }
            return true

        case "swift.protocol.property":
            // Protocol properties go to interfaces
            let propertyDeclarationStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let fullDecl = extractSwiftPropertyDeclaration(from: cap.range, index: index, nsContent: nsContent, fallback: {
                captureDeclaration(cap.range, "{")
            })
            if perfEnabled {
                record(.propertyDeclaration, duration: CFAbsoluteTimeGetCurrent() - propertyDeclarationStart, perfStats: activePerfStats)
            }
            let propertyTypeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let propType = extractSwiftPropertyType(from: fullDecl, perfStats: activePerfStats)
            if let typeName = propType {
                referencedTypes.insert(rawType: typeName)
            }
            if perfEnabled {
                record(.propertyTypeExtraction, duration: CFAbsoluteTimeGetCurrent() - propertyTypeStart, perfStats: activePerfStats)
            }

            let enclosingTypeStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let resolvedEnclosingProto = enclosingType(for: cap.range, in: context.typeBoundaries)
            if perfEnabled {
                record(.enclosingTypeLookup, duration: CFAbsoluteTimeGetCurrent() - enclosingTypeStart, perfStats: activePerfStats)
            }
            let modelInsertionStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            if let enclosingProto = resolvedEnclosingProto, enclosingProto.isProtocol {
                let lineNo = enclosingProto.startLine
                if interfaceBoundaries[lineNo] == nil {
                    interfaceBoundaries[lineNo] = InterfaceInfo(name: enclosingProto.name, properties: [], methods: [])
                }
                let propInfo = PropertyInfo(name: fullDecl, typeName: propType)
                interfaceBoundaries[lineNo]?.properties.append(propInfo)
            }
            if perfEnabled {
                record(.modelInsertion, duration: CFAbsoluteTimeGetCurrent() - modelInsertionStart, perfStats: activePerfStats)
            }
            if let activePerfStats {
                activePerfStats.swiftStrategyHandledPropertyCount += 1
            }
            return true

		// MARK: Swift Type Declarations (skip - handled in buildContext)

        case "swift.type.decl", "swift.type.name", "swift.protocol.decl", "swift.protocol.name",
             "swift.function.name", "swift.param.node", "swift.param.external", "swift.param.local", "swift.param.type":
            // These are handled during context building or parameter extraction
            let contextOnlyStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            if perfEnabled {
                record(.contextOnly, duration: CFAbsoluteTimeGetCurrent() - contextOnlyStart, perfStats: activePerfStats)
            }
            return true

        default:
            return false
        }
    }

    // MARK: - Helpers

    /// Extracts Swift parameters from a function capture range
    private static func extractSwiftParameters(
        from functionRange: NSRange,
        signatureEnd: Int,
        context: Context,
        index: CodeMapCaptureIndex,
        nsContent: NSString,
        referencedTypes: inout ReferencedTypesAccumulator
    ) -> [ParameterInfo] {
        var params: [ParameterInfo] = []

        // Collect param nodes within this function
        let paramNodes = index.captures(named: "swift.param.node", containedIn: functionRange)

        for paramNode in paramNodes {
            // Ignore params that appear after the function signature (e.g., nested local functions)
            if paramNode.range.location >= signatureEnd {
                continue
            }
            // Exclude params from nested functions inside this function range
            if let enclosingFn = smallestContainingRange(in: context.functionCaptures, for: paramNode.range),
               !NSEqualRanges(enclosingFn.range, functionRange)
            {
                continue
            }
            var external: String? = nil
            var local: String? = nil
            var type: String? = nil

            // Get details from captures within this param node
            if let extCap = index.firstCapture(named: "swift.param.external", containedIn: paramNode.range) {
                external = nsContent.substring(with: extCap.range)
            }
            if let locCap = index.firstCapture(named: "swift.param.local", containedIn: paramNode.range) {
                local = nsContent.substring(with: locCap.range)
            }
            let paramText = nsContent.substring(with: paramNode.range)
            if let typeCap = index.firstCapture(named: "swift.param.type", containedIn: paramNode.range) {
                type = nsContent.substring(with: typeCap.range)
            } else if let parsedType = extractSwiftParamType(from: paramText) {
                type = parsedType
            }

            if let localName = local {
                let ext = (external == "_") ? "_" : external
                params.append(ParameterInfo(externalName: ext, localName: localName, typeName: type))
                if let typeName = type {
                    referencedTypes.insert(rawType: typeName)
                }
            }
        }

        return params
    }

    private static func signatureEndLocation(forFunctionRange functionRange: NSRange, nsContent: NSString) -> Int {
        let end = NSMaxRange(functionRange)
        var parenDepth = 0
        var inString = false
        var escapeNext = false
        var inLineComment = false
        var inBlockComment = false
        var i = functionRange.location

        while i < end {
            let ch = nsContent.character(at: i)

            if inLineComment {
                if ch == 0x0A { // \n
                    inLineComment = false
                }
                i += 1
                continue
            }

            if inBlockComment {
                if ch == 0x2A, i + 1 < end, nsContent.character(at: i + 1) == 0x2F { // */
                    inBlockComment = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if inString {
                if escapeNext {
                    escapeNext = false
                    i += 1
                    continue
                }
                if ch == 0x5C { // \\
                    escapeNext = true
                    i += 1
                    continue
                }
                if ch == 0x22 { // "
                    inString = false
                }
                i += 1
                continue
            }

            if ch == 0x22 { // "
                inString = true
                i += 1
                continue
            }

            if ch == 0x2F, i + 1 < end {
                let next = nsContent.character(at: i + 1)
                if next == 0x2F { // //
                    inLineComment = true
                    i += 2
                    continue
                }
                if next == 0x2A { // /*
                    inBlockComment = true
                    i += 2
                    continue
                }
            }

            if ch == 0x28 { // (
                parenDepth += 1
            } else if ch == 0x29 { // )
                if parenDepth > 0 {
                    parenDepth -= 1
                }
            } else if ch == 0x7B, parenDepth == 0 { // {
                return i
            }

            i += 1
        }

        return end
    }

    private static func extractSwiftParamType(from paramText: String) -> String? {
        guard let colonIndex = paramText.firstIndex(of: ":") else { return nil }
        var afterColon = paramText[paramText.index(after: colonIndex)...]
        if let eqIndex = afterColon.firstIndex(of: "=") {
            afterColon = afterColon[..<eqIndex]
        }
        let trimmed = afterColon.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

	private static func extractSwiftReturnType(from signature: String, perfStats: CodeMapPerformanceCollector? = nil) -> String? {
        if let fast = SwiftSignatureParser.extractReturnType(from: signature) {
            perfStats?.swiftReturnTypeFastPathHits += 1
            return fast
        }
        if let match = LanguageTypeExtractor.matchAnyFunctionLine(signature, language: .swift, stats: perfStats),
           let returnType = match["returnType"],
           !returnType.isEmpty
        {
            return returnType.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

	private static func extractSwiftPropertyType(from declaration: String, perfStats: CodeMapPerformanceCollector? = nil) -> String? {
        if let match = LanguageTypeExtractor.matchAnyVariableLine(declaration, language: .swift, stats: perfStats),
           let propType = match["type"],
           !propType.isEmpty
        {
            return propType.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractSwiftPropertyDeclaration(
        from identifierRange: NSRange,
        index: CodeMapCaptureIndex,
		nsContent: NSString,
        fallback: () -> String
    ) -> String {
        let declCap = index.smallestCapture(
            named: "swift.property.decl",
            containing: identifierRange
        ) ?? index.smallestCapture(
            named: "swift.protocol.property.decl",
            containing: identifierRange
        )
        if let cap = declCap {
            var decl = nsContent.substring(with: cap.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let braceIndex = decl.firstIndex(of: "{") {
                decl = String(decl[..<braceIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            decl = stripSwiftInitializer(decl)
            return decl
        }
        return fallback()
    }

    private static func stripSwiftInitializer(_ declaration: String) -> String {
        let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eqIndex = TopLevelScanner.firstTopLevelIndex(of: "=", in: trimmed, track: .all) {
            return String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func smallestContainingRange(in ranges: [NamedRange], for target: NSRange) -> NamedRange? {
        let endIdx = ranges.binarySearch { $0.range.location <= target.location }
        guard endIdx > 0 else { return nil }

        var best: NamedRange? = nil
        for i in stride(from: endIdx - 1, through: 0, by: -1) {
            let candidate = ranges[i]
            if rangeContains(candidate.range, target),
               best == nil || isBetter(candidate.range, than: best!.range)
            {
                best = candidate
            }
        }
        return best
    }

    /// Finds the smallest enclosing type boundary for a given range
    private static func enclosingType(for range: NSRange, in typeBoundaries: [TypeBoundary]) -> TypeBoundary? {
        let endIdx = typeBoundaries.binarySearch { $0.range.location <= range.location }
        guard endIdx > 0 else { return nil }

        var smallestContaining: TypeBoundary? = nil
        for i in stride(from: endIdx - 1, through: 0, by: -1) {
            let boundary = typeBoundaries[i]
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
