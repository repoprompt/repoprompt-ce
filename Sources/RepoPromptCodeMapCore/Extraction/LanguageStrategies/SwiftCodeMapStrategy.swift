//
//  SwiftCodeMapStrategy.swift
//  RepoPrompt
//
//  Created by Claude on 2026-01-29.
//

import Foundation

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
        var functionCaptures: [CodeMapIndexedCapture] = []
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
        boundaries: [Int],
        performanceCollector: CodeMapPerformanceCollector? = nil
    ) -> Context {
        var ctx = Context()
        let nsContent = content as NSString

        func mapNamesToSmallestContainingDecl(
            nameCaps: [CodeMapIndexedCapture],
            declCaps: [CodeMapIndexedCapture]
        ) -> [NSRange: String] {
            var mapping: [NSRange: String] = [:]
            guard !nameCaps.isEmpty, !declCaps.isEmpty else { return mapping }

            var stack: [CodeMapIndexedCapture] = []
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
                var bestDecl: CodeMapIndexedCapture? = nil
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
        performanceCollector?.swiftTypeDeclarationCount += typeDeclCaps.count
        let typeMappingStart = performanceCollector.map { _ in CFAbsoluteTimeGetCurrent() }
        ctx.typeNamesByRange = mapNamesToSmallestContainingDecl(
            nameCaps: typeNameCaps,
            declCaps: typeDeclCaps
        )
        if let typeMappingStart {
            performanceCollector?.swiftTypeNameMappingDuration +=
                CFAbsoluteTimeGetCurrent() - typeMappingStart
        }

        // Second pass: build boundaries with full ranges
        let typeBoundaryStart = performanceCollector.map { _ in CFAbsoluteTimeGetCurrent() }
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

        if let typeBoundaryStart {
            performanceCollector?.swiftBoundaryConstructionDuration +=
                CFAbsoluteTimeGetCurrent() - typeBoundaryStart
        }

        // Also collect protocols
        let protocolDeclCaps = index.captures(named: "swift.protocol.decl")
        let protocolNameCaps = index.captures(named: "swift.protocol.name")
        performanceCollector?.swiftProtocolDeclarationCount += protocolDeclCaps.count
        let protocolMappingStart = performanceCollector.map { _ in CFAbsoluteTimeGetCurrent() }
        ctx.protocolNamesByRange = mapNamesToSmallestContainingDecl(
            nameCaps: protocolNameCaps,
            declCaps: protocolDeclCaps
        )

        if let protocolMappingStart {
            performanceCollector?.swiftProtocolNameMappingDuration +=
                CFAbsoluteTimeGetCurrent() - protocolMappingStart
        }

        let protocolBoundaryStart = performanceCollector.map { _ in CFAbsoluteTimeGetCurrent() }
        for cap in protocolDeclCaps {
            if let name = ctx.protocolNamesByRange[cap.range] {
                let lineNo = lineNumber(for: cap.range.location, using: boundaries)
                ctx.typeBoundaries.append(TypeBoundary(kind: .protocol, name: name, range: cap.range, startLine: lineNo))
            }
        }

        if let protocolBoundaryStart {
            performanceCollector?.swiftBoundaryConstructionDuration +=
                CFAbsoluteTimeGetCurrent() - protocolBoundaryStart
        }

        let functionAssemblyStart = performanceCollector.map { _ in CFAbsoluteTimeGetCurrent() }
        let topLevelFunctionCaps = index.captures(named: "swift.function.toplevel")
        let methodFunctionCaps = index.captures(named: "swift.function.method")
        let protocolFunctionCaps = index.captures(named: "swift.protocol.method")
        performanceCollector?.swiftTopLevelFunctionCount += topLevelFunctionCaps.count
        performanceCollector?.swiftMethodFunctionCount += methodFunctionCaps.count
        performanceCollector?.swiftProtocolMethodCount += protocolFunctionCaps.count
        performanceCollector?.swiftParameterNodeCount += index.captures(named: "swift.param.node").count
        performanceCollector?.swiftPropertyDeclarationCount += index.captures(named: "swift.property.decl").count
        performanceCollector?.swiftProtocolPropertyDeclarationCount +=
            index.captures(named: "swift.protocol.property.decl").count
        performanceCollector?.swiftPropertyIdentifierCount +=
            index.captures(named: "swift.property.toplevel").count +
            index.captures(named: "swift.property.member").count +
            index.captures(named: "swift.protocol.property").count
        ctx.functionCaptures.reserveCapacity(
            topLevelFunctionCaps.count + methodFunctionCaps.count + protocolFunctionCaps.count
        )
        ctx.functionCaptures.append(contentsOf: topLevelFunctionCaps)
        ctx.functionCaptures.append(contentsOf: methodFunctionCaps)
        ctx.functionCaptures.append(contentsOf: protocolFunctionCaps)
        ctx.functionCaptures.sort { $0.range.location < $1.range.location }

        // Sort boundaries by range location
        ctx.typeBoundaries.sort { $0.range.location < $1.range.location }
        if let functionAssemblyStart {
            performanceCollector?.swiftFunctionCaptureAssemblyDuration +=
                CFAbsoluteTimeGetCurrent() - functionAssemblyStart
            performanceCollector?.swiftTypeBoundaryCount += ctx.typeBoundaries.count
        }

        return ctx
    }

    // MARK: - Swift Signature Extraction

    private struct SwiftFunctionSignature {
        let definitionLine: String
        let signatureEnd: Int
    }

    static func normalizeSwiftSignatureWhitespace(
        _ trimmed: String,
        performanceCollector: CodeMapPerformanceCollector?
    ) -> String {
        var needsRewrite = false
        var previousWasWhitespace = false
        var asciiByteCount = 0

        for byte in trimmed.utf8 {
            if byte >= 0x80 {
                let normalized = trimmed.replacing(#/\s+/#, with: " ")
                if let performanceCollector {
                    performanceCollector.swiftSignatureNormalizationUnicodeFallbackCount += 1
                    performanceCollector.swiftSignatureNormalizationInputUTF8ByteCount += trimmed.utf8.count
                    performanceCollector.swiftSignatureNormalizationOutputUTF8ByteCount += normalized.utf8.count
                }
                return normalized
            }

            asciiByteCount += 1
            let isWhitespace = byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
            if isWhitespace {
                if byte != 0x20 || previousWasWhitespace {
                    needsRewrite = true
                }
                previousWasWhitespace = true
            } else {
                previousWasWhitespace = false
            }
        }

        guard needsRewrite else {
            if let performanceCollector {
                performanceCollector.swiftSignatureNormalizationASCIINoOpCount += 1
                performanceCollector.swiftSignatureNormalizationInputUTF8ByteCount += asciiByteCount
                performanceCollector.swiftSignatureNormalizationOutputUTF8ByteCount += asciiByteCount
            }
            return trimmed
        }

        var normalizedUTF8: [UInt8] = []
        normalizedUTF8.reserveCapacity(asciiByteCount)
        var isCollapsingWhitespace = false
        for byte in trimmed.utf8 {
            let isWhitespace = byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
            if isWhitespace {
                if !isCollapsingWhitespace {
                    normalizedUTF8.append(0x20)
                    isCollapsingWhitespace = true
                }
            } else {
                normalizedUTF8.append(byte)
                isCollapsingWhitespace = false
            }
        }

        let normalized = String(decoding: normalizedUTF8, as: UTF8.self)
        if let performanceCollector {
            performanceCollector.swiftSignatureNormalizationASCIIRewriteCount += 1
            performanceCollector.swiftSignatureNormalizationInputUTF8ByteCount += asciiByteCount
            performanceCollector.swiftSignatureNormalizationOutputUTF8ByteCount += normalizedUTF8.count
        }
        return normalized
    }

    /// Extracts only the function signature (up to but not including `{`) from a Swift function capture range.
    /// Uses `signatureEndLocation` to correctly handle strings, comments, and nesting.
    private static func extractSwiftFunctionSignature(
        from functionRange: NSRange,
        nsContent: NSString,
        boundaries: [Int],
        performanceCollector: CodeMapPerformanceCollector?
    ) -> SwiftFunctionSignature {
        let scanStart = performanceCollector.map { _ in CFAbsoluteTimeGetCurrent() }
        let signatureEnd = signatureEndLocation(
            forFunctionRange: functionRange,
            nsContent: nsContent,
            performanceCollector: performanceCollector
        )
        if let scanStart {
            performanceCollector?.swiftSignatureEndScanDuration +=
                CFAbsoluteTimeGetCurrent() - scanStart
        }
        let signatureLength = signatureEnd - functionRange.location
        let signatureRange = NSRange(location: functionRange.location, length: signatureLength)

        // Get the signature text
        let normalizationStart = performanceCollector.map { _ in CFAbsoluteTimeGetCurrent() }
        let trimmedSignature = nsContent.substring(with: signatureRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize whitespace (collapse multiple whitespace to single space)
        let signature = normalizeSwiftSignatureWhitespace(
            trimmedSignature,
            performanceCollector: performanceCollector
        )
        if let normalizationStart {
            performanceCollector?.swiftSignatureNormalizationDuration +=
                CFAbsoluteTimeGetCurrent() - normalizationStart
        }

        return SwiftFunctionSignature(definitionLine: signature, signatureEnd: signatureEnd)
    }

    // MARK: - Capture Handling

    /// Handles a Swift-specific capture. Returns true if handled, false to fall through to default handling.
    static func handleCapture(
        _ cap: CodeMapIndexedCapture,
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
			let signature = extractSwiftFunctionSignature(
				from: cap.range,
				nsContent: nsContent,
				boundaries: boundaries,
				performanceCollector: activePerfStats
			)
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
                referencedTypes: &referencedTypes,
                performanceCollector: activePerfStats
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

            if !containsFunction(
                    in: globalFunctions,
                    definitionLine: decl,
                    performanceCollector: activePerfStats
                ) {
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
			let signature = extractSwiftFunctionSignature(
				from: cap.range,
				nsContent: nsContent,
				boundaries: boundaries,
				performanceCollector: activePerfStats
			)
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
                referencedTypes: &referencedTypes,
                performanceCollector: activePerfStats
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
			let resolvedEnclosingType = enclosingType(
				for: cap.range,
				in: context.typeBoundaries,
				performanceCollector: activePerfStats
			)
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
                if !containsFunction(
                    in: classesByLine[lineNo]!.methods,
                    definitionLine: decl,
                    performanceCollector: activePerfStats
                ) {
                    classesByLine[lineNo]?.methods.append(fnInfo)
                }
            } else {
                // Fallback: treat as global if no enclosing type found
                if !containsFunction(
                    in: globalFunctions,
                    definitionLine: decl,
                    performanceCollector: activePerfStats
                ) {
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
			let signature = extractSwiftFunctionSignature(
				from: cap.range,
				nsContent: nsContent,
				boundaries: boundaries,
				performanceCollector: activePerfStats
			)
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
                referencedTypes: &referencedTypes,
                performanceCollector: activePerfStats
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
			let resolvedEnclosingProto = enclosingType(
				for: cap.range,
				in: context.typeBoundaries,
				performanceCollector: activePerfStats
			)
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
			let fullDecl = extractSwiftPropertyDeclaration(
				from: cap.range,
				index: index,
				nsContent: nsContent,
				performanceCollector: activePerfStats,
				fallback: {
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

            if !containsVariable(
                    in: globalVariables,
                    definitionLine: fullDecl,
                    performanceCollector: activePerfStats
                ) {
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
			let fullDecl = extractSwiftPropertyDeclaration(
				from: cap.range,
				index: index,
				nsContent: nsContent,
				performanceCollector: activePerfStats,
				fallback: {
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
			let resolvedEnclosingType = enclosingType(
				for: cap.range,
				in: context.typeBoundaries,
				performanceCollector: activePerfStats
			)
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
                if !containsProperty(
                    in: classesByLine[lineNo]!.properties,
                    name: fullDecl,
                    performanceCollector: activePerfStats
                ) {
                    classesByLine[lineNo]?.properties.append(propInfo)
                }
            } else {
                // Fallback: treat as global if no enclosing type found
                let varInfo = VariableInfo(name: fullDecl, typeName: propType, definitionLine: fullDecl)
                if !containsVariable(
                    in: globalVariables,
                    definitionLine: fullDecl,
                    performanceCollector: activePerfStats
                ) {
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
			let fullDecl = extractSwiftPropertyDeclaration(
				from: cap.range,
				index: index,
				nsContent: nsContent,
				performanceCollector: activePerfStats,
				fallback: {
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
			let resolvedEnclosingProto = enclosingType(
				for: cap.range,
				in: context.typeBoundaries,
				performanceCollector: activePerfStats
			)
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

	private static func containsFunction(
		in functions: [FunctionInfo],
		definitionLine: String,
		performanceCollector: CodeMapPerformanceCollector?
	) -> Bool {
		guard let performanceCollector else {
			return functions.contains { $0.definitionLine == definitionLine }
		}
		performanceCollector.swiftFunctionDuplicateCheckCount += 1
		for function in functions {
			performanceCollector.swiftFunctionDuplicateCandidateVisits += 1
			if function.definitionLine == definitionLine { return true }
		}
		return false
	}

	private static func containsVariable(
		in variables: [VariableInfo],
		definitionLine: String,
		performanceCollector: CodeMapPerformanceCollector?
	) -> Bool {
		guard let performanceCollector else {
			return variables.contains { $0.definitionLine == definitionLine }
		}
		performanceCollector.swiftPropertyDuplicateCheckCount += 1
		for variable in variables {
			performanceCollector.swiftPropertyDuplicateCandidateVisits += 1
			if variable.definitionLine == definitionLine { return true }
		}
		return false
	}

	private static func containsProperty(
		in properties: [PropertyInfo],
		name: String,
		performanceCollector: CodeMapPerformanceCollector?
	) -> Bool {
		guard let performanceCollector else {
			return properties.contains { $0.name == name }
		}
		performanceCollector.swiftPropertyDuplicateCheckCount += 1
		for property in properties {
			performanceCollector.swiftPropertyDuplicateCandidateVisits += 1
			if property.name == name { return true }
		}
		return false
	}

    /// Extracts Swift parameters from a function capture range
    private static func extractSwiftParameters(
        from functionRange: NSRange,
        signatureEnd: Int,
        context: Context,
        index: CodeMapCaptureIndex,
        nsContent: NSString,
        referencedTypes: inout ReferencedTypesAccumulator,
        performanceCollector: CodeMapPerformanceCollector?
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
            if let enclosingFn = smallestContainingRange(
                in: context.functionCaptures,
                for: paramNode.range,
                performanceCollector: performanceCollector
            ),
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
            let parameterTypeResolutionStart = performanceCollector == nil ? 0 : CFAbsoluteTimeGetCurrent()
            if let typeCap = index.firstCapture(named: "swift.param.type", containedIn: paramNode.range) {
                performanceCollector?.swiftParameterTypeDirectCaptureCount += 1
                type = nsContent.substring(with: typeCap.range)
            } else if let parsedType = extractSwiftParamType(
                from: paramText,
                performanceCollector: performanceCollector
            ) {
                type = parsedType
            }
            if let performanceCollector {
                performanceCollector.swiftParameterTypeResolutionDuration +=
                    CFAbsoluteTimeGetCurrent() - parameterTypeResolutionStart
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

	private static func signatureEndLocation(
		forFunctionRange functionRange: NSRange,
		nsContent: NSString,
		performanceCollector: CodeMapPerformanceCollector?
	) -> Int {
        let end = NSMaxRange(functionRange)
		var i = functionRange.location
		defer {
			let visited = max(0, min(i, end) - functionRange.location + (i < end ? 1 : 0))
			performanceCollector?.swiftSignatureCodeUnitVisits += visited
		}
        var parenDepth = 0
        var inString = false
        var escapeNext = false
        var inLineComment = false
        var inBlockComment = false

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

    static func extractSwiftParamType(
        from paramText: String,
        performanceCollector: CodeMapPerformanceCollector? = nil
    ) -> String? {
        var inputUTF8ByteCount = 0
        var containsNonASCII = false
        for byte in paramText.utf8 {
            inputUTF8ByteCount += 1
            if byte >= 0x80 {
                containsNonASCII = true
            }
        }

        performanceCollector?.swiftParameterTypeFallbackParserCount += 1
        performanceCollector?.swiftParameterTypeInputUTF8ByteCount += inputUTF8ByteCount

        if containsNonASCII {
            performanceCollector?.swiftParameterTypeUnicodeLegacyFallbackCount += 1
            let legacyStart = performanceCollector == nil ? 0 : CFAbsoluteTimeGetCurrent()
            let result = extractSwiftParamTypeLegacy(from: paramText)
            if let performanceCollector {
                performanceCollector.swiftParameterTypeLegacyFallbackDuration +=
                    CFAbsoluteTimeGetCurrent() - legacyStart
            }
            return result
        }

        performanceCollector?.swiftParameterTypeASCIIFastPathCount += 1
        let utf8 = paramText.utf8
        guard let colonIndex = firstTopLevelASCIISwiftDelimiter(
            0x3A,
            in: utf8,
            from: utf8.startIndex
        ) else { return nil }
        let afterColonStart = utf8.index(after: colonIndex)
        let afterColon: Substring
        if let equalIndex = firstTopLevelASCIISwiftDelimiter(
            0x3D,
            in: utf8,
            from: afterColonStart
        ) {
            afterColon = paramText[afterColonStart ..< equalIndex]
        } else {
            afterColon = paramText[afterColonStart...]
        }
        let trimmed = afterColon.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func extractSwiftParamTypeLegacy(from paramText: String) -> String? {
        let parameter = paramText[...]
        guard let colonIndex = firstTopLevelSwiftDelimiter(":", in: parameter) else { return nil }
        var afterColon = parameter[parameter.index(after: colonIndex)...]
        if let eqIndex = firstTopLevelSwiftDelimiter("=", in: afterColon) {
            afterColon = afterColon[..<eqIndex]
        }
        let trimmed = afterColon.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstTopLevelASCIISwiftDelimiter(
        _ target: UInt8,
        in utf8: String.UTF8View,
        from startIndex: String.UTF8View.Index
    ) -> String.UTF8View.Index? {
        var delimiterStack: [UInt8] = []
        var stringDelimiter: (pounds: Int, quotes: Int)?
        var index = startIndex

        while index < utf8.endIndex {
            if let activeStringDelimiter = stringDelimiter {
                if utf8[index] == 0x5C, activeStringDelimiter.pounds == 0 {
                    index = utf8.index(after: index)
                    if index < utf8.endIndex {
                        index = utf8.index(after: index)
                    }
                    continue
                }

                var terminatorEnd = index
                var isTerminator = true
                for _ in 0 ..< activeStringDelimiter.quotes {
                    guard terminatorEnd < utf8.endIndex, utf8[terminatorEnd] == 0x22 else {
                        isTerminator = false
                        break
                    }
                    terminatorEnd = utf8.index(after: terminatorEnd)
                }
                if isTerminator {
                    for _ in 0 ..< activeStringDelimiter.pounds {
                        guard terminatorEnd < utf8.endIndex, utf8[terminatorEnd] == 0x23 else {
                            isTerminator = false
                            break
                        }
                        terminatorEnd = utf8.index(after: terminatorEnd)
                    }
                }
                if isTerminator {
                    index = terminatorEnd
                    stringDelimiter = nil
                    continue
                }

                index = utf8.index(after: index)
                continue
            }

            var quoteIndex = index
            var poundCount = 0
            while quoteIndex < utf8.endIndex, utf8[quoteIndex] == 0x23 {
                poundCount += 1
                quoteIndex = utf8.index(after: quoteIndex)
            }
            if quoteIndex < utf8.endIndex, utf8[quoteIndex] == 0x22 {
                var openerEnd = utf8.index(after: quoteIndex)
                var quoteCount = 1
                if openerEnd < utf8.endIndex, utf8[openerEnd] == 0x22 {
                    let thirdQuoteIndex = utf8.index(after: openerEnd)
                    if thirdQuoteIndex < utf8.endIndex, utf8[thirdQuoteIndex] == 0x22 {
                        quoteCount = 3
                        openerEnd = utf8.index(after: thirdQuoteIndex)
                    }
                }
                stringDelimiter = (poundCount, quoteCount)
                index = openerEnd
                continue
            }

            let byte = utf8[index]
            switch byte {
            case 0x28, 0x5B, 0x7B:
                delimiterStack.append(byte)
            case 0x29:
                if delimiterStack.last == 0x28 { delimiterStack.removeLast() }
            case 0x5D:
                if delimiterStack.last == 0x5B { delimiterStack.removeLast() }
            case 0x7D:
                if delimiterStack.last == 0x7B { delimiterStack.removeLast() }
            default:
                if byte == target, delimiterStack.isEmpty {
                    return index
                }
            }
            index = utf8.index(after: index)
        }

        return nil
    }

	private static func firstTopLevelSwiftDelimiter(
		_ target: Character,
		in text: Substring
	) -> String.Index? {
		let characters = Array(text)
		var delimiterStack: [Character] = []
		var stringDelimiter: (pounds: Int, quotes: Int)?
		var offset = 0

		while offset < characters.count {
			if let activeStringDelimiter = stringDelimiter {
				if characters[offset] == "\\", activeStringDelimiter.pounds == 0 {
					offset = min(offset + 2, characters.count)
					continue
				}
				if isSwiftStringTerminator(
					at: offset,
					characters: characters,
					delimiter: activeStringDelimiter
				) {
					offset += activeStringDelimiter.quotes + activeStringDelimiter.pounds
					stringDelimiter = nil
					continue
				}
				offset += 1
				continue
			}

			if let opening = swiftStringDelimiterStarting(at: offset, characters: characters) {
				stringDelimiter = (opening.pounds, opening.quotes)
				offset += opening.pounds + opening.quotes
				continue
			}

			let character = characters[offset]
			switch character {
			case "(", "[", "{":
				delimiterStack.append(character)
			case ")":
				if delimiterStack.last == "(" { delimiterStack.removeLast() }
			case "]":
				if delimiterStack.last == "[" { delimiterStack.removeLast() }
			case "}":
				if delimiterStack.last == "{" { delimiterStack.removeLast() }
			default:
				if character == target, delimiterStack.isEmpty {
					return text.index(text.startIndex, offsetBy: offset)
				}
			}
			offset += 1
		}

		return nil
	}

	private static func swiftStringDelimiterStarting(
		at offset: Int,
		characters: [Character]
	) -> (pounds: Int, quotes: Int)? {
		var quoteOffset = offset
		while quoteOffset < characters.count, characters[quoteOffset] == "#" {
			quoteOffset += 1
		}
		guard quoteOffset < characters.count, characters[quoteOffset] == "\"" else { return nil }
		let quoteCount = quoteOffset + 2 < characters.count &&
			characters[quoteOffset + 1] == "\"" && characters[quoteOffset + 2] == "\"" ? 3 : 1
		return (quoteOffset - offset, quoteCount)
	}

	private static func isSwiftStringTerminator(
		at offset: Int,
		characters: [Character],
		delimiter: (pounds: Int, quotes: Int)
	) -> Bool {
		guard offset + delimiter.quotes + delimiter.pounds <= characters.count else { return false }
		for quoteOffset in 0 ..< delimiter.quotes where characters[offset + quoteOffset] != "\"" {
			return false
		}
		for poundOffset in 0 ..< delimiter.pounds
		where characters[offset + delimiter.quotes + poundOffset] != "#" {
			return false
		}
		return true
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

	enum SwiftASCIIPropertyTypeResolution: Equatable {
		case type(String)
		case noType
		case fallback
	}

	private static let swiftPropertyModifierKeywords = [
		"private(set)", "public", "private", "internal", "fileprivate", "open",
		"class", "static", "final", "lazy", "override", "mutating", "actor", "inout",
		"required", "convenience", "indirect", "weak", "unowned", "dynamic", "distributed", "isolated",
	]

	static func extractSwiftPropertyType(
		from declaration: String,
		perfStats: CodeMapPerformanceCollector? = nil
	) -> String? {
		let resolutionStart = perfStats == nil ? 0 : CFAbsoluteTimeGetCurrent()
		perfStats?.swiftPropertyTypeResolutionCount += 1
		defer {
			if let perfStats {
				perfStats.swiftPropertyTypeResolutionDuration +=
					CFAbsoluteTimeGetCurrent() - resolutionStart
			}
		}

		var inputUTF8ByteCount = 0
		var containsNonASCII = false
		for byte in declaration.utf8 {
			inputUTF8ByteCount += 1
			if byte >= 0x80 {
				containsNonASCII = true
			}
		}
		perfStats?.swiftPropertyTypeInputUTF8ByteCount += inputUTF8ByteCount

		if containsNonASCII {
			perfStats?.swiftPropertyTypeLegacyFallbackCount += 1
			perfStats?.swiftPropertyTypeUnicodeLegacyFallbackCount += 1
			let legacyStart = perfStats == nil ? 0 : CFAbsoluteTimeGetCurrent()
			let result = extractSwiftPropertyTypeLegacy(from: declaration, perfStats: perfStats)
			if let perfStats {
				perfStats.swiftPropertyTypeLegacyFallbackDuration +=
					CFAbsoluteTimeGetCurrent() - legacyStart
			}
			return result
		}

		let fastPathStart = perfStats == nil ? 0 : resolutionStart
		let resolution = resolveSwiftASCIIPropertyType(in: declaration.utf8)
		if let perfStats {
			perfStats.swiftPropertyTypeASCIIFastPathDuration +=
				CFAbsoluteTimeGetCurrent() - fastPathStart
		}

		switch resolution {
		case let .type(type):
			perfStats?.swiftPropertyTypeASCIIDirectTypeCount += 1
			return type
		case .noType:
			perfStats?.swiftPropertyTypeASCIIDirectNilCount += 1
			return nil
		case .fallback:
			perfStats?.swiftPropertyTypeLegacyFallbackCount += 1
			perfStats?.swiftPropertyTypeASCIIIneligibleFallbackCount += 1
			let legacyStart = perfStats == nil ? 0 : CFAbsoluteTimeGetCurrent()
			let result = extractSwiftPropertyTypeLegacy(from: declaration, perfStats: perfStats)
			if let perfStats {
				perfStats.swiftPropertyTypeLegacyFallbackDuration +=
					CFAbsoluteTimeGetCurrent() - legacyStart
			}
			return result
		}
	}

	static func extractSwiftPropertyTypeLegacy(
		from declaration: String,
		perfStats: CodeMapPerformanceCollector? = nil
	) -> String? {
        if let match = LanguageTypeExtractor.matchAnyVariableLine(declaration, language: .swift, stats: perfStats),
           let propType = match["type"],
           !propType.isEmpty
        {
            return propType.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

	static func resolveSwiftASCIIPropertyType(
		in utf8: String.UTF8View
	) -> SwiftASCIIPropertyTypeResolution {
		var index = utf8.startIndex
		let end = utf8.endIndex

		for byte in utf8 where byte >= 0x80 {
			return .fallback
		}
		if containsAmbiguousSwiftPropertyByteSequence(in: utf8) {
			return .fallback
		}

		if index < end, utf8[index] == 0x2D || utf8[index] == 0x2A {
			index = utf8.index(after: index)
		}
		skipASCIIWhitespace(in: utf8, index: &index)

		while index < end, utf8[index] == 0x40 {
			index = utf8.index(after: index)
			guard index < end, isASCIIIdentifierStart(utf8[index]) else { return .fallback }
			index = utf8.index(after: index)
			while index < end, isASCIIIdentifierContinuation(utf8[index]) {
				index = utf8.index(after: index)
			}
			if index < end, utf8[index] == 0x28 {
				index = utf8.index(after: index)
				while index < end, utf8[index] != 0x29 {
					let byte = utf8[index]
					if byte == 0x28 || !isSafeASCIIAttributeArgumentByte(byte) {
						return .fallback
					}
					index = utf8.index(after: index)
				}
				guard index < end else { return .fallback }
				index = utf8.index(after: index)
			}
			skipASCIIWhitespace(in: utf8, index: &index)
		}

		while true {
			if let afterKeyword = matchingASCIIKeyword("var", in: utf8, at: index),
				afterKeyword < end,
				isASCIIWhitespace(utf8[afterKeyword])
			{
				index = afterKeyword
				skipASCIIWhitespace(in: utf8, index: &index)
				break
			}
			if let afterKeyword = matchingASCIIKeyword("let", in: utf8, at: index),
				afterKeyword < end,
				isASCIIWhitespace(utf8[afterKeyword])
			{
				index = afterKeyword
				skipASCIIWhitespace(in: utf8, index: &index)
				break
			}

			var matchedModifier = false
			for modifier in swiftPropertyModifierKeywords {
				guard let afterModifier = matchingASCIIKeyword(modifier, in: utf8, at: index),
						afterModifier < end,
						isASCIIWhitespace(utf8[afterModifier])
				else { continue }
				index = afterModifier
				skipASCIIWhitespace(in: utf8, index: &index)
				matchedModifier = true
				break
			}
			if !matchedModifier {
				return .fallback
			}
		}

		guard index < end, isASCIIIdentifierStart(utf8[index]) else { return .fallback }
		index = utf8.index(after: index)
		while index < end, isASCIIIdentifierContinuation(utf8[index]) {
			index = utf8.index(after: index)
		}
		skipASCIIWhitespace(in: utf8, index: &index)
		guard index < end else { return .noType }
		guard utf8[index] == 0x3A else { return .fallback }
		index = utf8.index(after: index)
		let afterColon = index
		skipASCIIWhitespace(in: utf8, index: &index)
		if index == end {
			return afterColon == end ? .noType : .fallback
		}

		let typeStart = index
		var typeEnd = end
		var delimiters: [UInt8] = []
		var sawLineBreak = false
		while index < end {
			let byte = utf8[index]
			if sawLineBreak, !isASCIIWhitespace(byte) {
				return .fallback
			}
			if byte == 0x0A || byte == 0x0D {
				sawLineBreak = true
			}

			switch byte {
			case 0x28, 0x5B, 0x3C:
				delimiters.append(byte)
			case 0x29:
				guard delimiters.last == 0x28 else { return .fallback }
				delimiters.removeLast()
			case 0x5D:
				guard delimiters.last == 0x5B else { return .fallback }
				delimiters.removeLast()
			case 0x3E:
				let previous = index > typeStart ? utf8[utf8.index(before: index)] : 0
				if previous != 0x2D {
					guard delimiters.last == 0x3C else { return .fallback }
					delimiters.removeLast()
				}
			case 0x3D:
				guard delimiters.isEmpty else { return .fallback }
				let next = utf8.index(after: index)
				guard next == end || utf8[next] != 0x3D else { return .fallback }
				typeEnd = index
				index = end
				continue
			case 0x2C:
				guard !delimiters.isEmpty else { return .fallback }
			default:
				guard isSafeASCIIPropertyTypeByte(byte) else { return .fallback }
			}
			index = utf8.index(after: index)
		}
		guard delimiters.isEmpty else { return .fallback }

		let type = String(decoding: utf8[typeStart ..< typeEnd], as: UTF8.self)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return type.isEmpty ? .noType : .type(type)
	}

	private static func containsAmbiguousSwiftPropertyByteSequence(
		in utf8: String.UTF8View
	) -> Bool {
		var index = utf8.startIndex
		while index < utf8.endIndex {
			switch utf8[index] {
			case 0x22, 0x23, 0x5C, 0x7B, 0x7D:
				return true
			case 0x2F:
				return true
			default:
				index = utf8.index(after: index)
			}
		}
		return false
	}

	private static func skipASCIIWhitespace(
		in utf8: String.UTF8View,
		index: inout String.UTF8View.Index
	) {
		while index < utf8.endIndex, isASCIIWhitespace(utf8[index]) {
			index = utf8.index(after: index)
		}
	}

	private static func matchingASCIIKeyword(
		_ keyword: String,
		in utf8: String.UTF8View,
		at start: String.UTF8View.Index
	) -> String.UTF8View.Index? {
		var index = start
		for expected in keyword.utf8 {
			guard index < utf8.endIndex, utf8[index] == expected else { return nil }
			index = utf8.index(after: index)
		}
		return index
	}

	private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
		byte == 0x20 || (0x09 ... 0x0D).contains(byte)
	}

	private static func isASCIIIdentifierStart(_ byte: UInt8) -> Bool {
		byte == 0x5F || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
	}

	private static func isASCIIIdentifierContinuation(_ byte: UInt8) -> Bool {
		isASCIIIdentifierStart(byte) || (0x30 ... 0x39).contains(byte)
	}

	private static func isSafeASCIIAttributeArgumentByte(_ byte: UInt8) -> Bool {
		isASCIIIdentifierContinuation(byte) || isASCIIWhitespace(byte) || [
			0x2C, 0x2E, 0x2D, 0x2B, 0x3A, 0x3D, 0x3F, 0x21, 0x26, 0x3C, 0x3E,
			0x5B, 0x5D,
		].contains(byte)
	}

	private static func isSafeASCIIPropertyTypeByte(_ byte: UInt8) -> Bool {
		isASCIIIdentifierContinuation(byte) || isASCIIWhitespace(byte) || [
			0x2E, 0x3F, 0x21, 0x3A, 0x26, 0x2D, 0x40,
		].contains(byte)
	}

    private static func extractSwiftPropertyDeclaration(
        from identifierRange: NSRange,
        index: CodeMapCaptureIndex,
		nsContent: NSString,
		performanceCollector: CodeMapPerformanceCollector?,
        fallback: () -> String
    ) -> String {
		let lookupStart = performanceCollector.map { _ in CFAbsoluteTimeGetCurrent() }
        let declCap = index.smallestCapture(
            named: "swift.property.decl",
            containing: identifierRange
        ) ?? index.smallestCapture(
            named: "swift.protocol.property.decl",
            containing: identifierRange
        )
		if let lookupStart {
			performanceCollector?.swiftPropertyDeclarationLookupDuration +=
				CFAbsoluteTimeGetCurrent() - lookupStart
		}
        if let cap = declCap {
			let substringStart = performanceCollector.map { _ in CFAbsoluteTimeGetCurrent() }
            var decl = nsContent.substring(with: cap.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let braceIndex = decl.firstIndex(of: "{") {
                decl = String(decl[..<braceIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
			if let substringStart {
				performanceCollector?.swiftPropertyDeclarationSubstringDuration +=
					CFAbsoluteTimeGetCurrent() - substringStart
			}
			let initializerStart = performanceCollector.map { _ in CFAbsoluteTimeGetCurrent() }
            decl = stripSwiftInitializer(decl)
			if let initializerStart {
				performanceCollector?.swiftPropertyInitializerStripDuration +=
					CFAbsoluteTimeGetCurrent() - initializerStart
			}
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

    private static func smallestContainingRange(
        in ranges: [CodeMapIndexedCapture],
		for target: NSRange,
		performanceCollector: CodeMapPerformanceCollector?
    ) -> CodeMapIndexedCapture? {
		performanceCollector?.swiftNestedFunctionContainmentLookupCount += 1
        let endIdx = ranges.binarySearch { $0.range.location <= target.location }
		performanceCollector?.swiftNestedFunctionContainmentCandidateVisits += endIdx
        guard endIdx > 0 else { return nil }

        var best: CodeMapIndexedCapture? = nil
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
	private static func enclosingType(
		for range: NSRange,
		in typeBoundaries: [TypeBoundary],
		performanceCollector: CodeMapPerformanceCollector?
	) -> TypeBoundary? {
        let endIdx = typeBoundaries.binarySearch { $0.range.location <= range.location }
		performanceCollector?.swiftEnclosingTypeCandidateVisits += endIdx
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
