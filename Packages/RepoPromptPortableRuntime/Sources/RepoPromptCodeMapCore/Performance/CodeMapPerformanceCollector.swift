import Foundation

public struct CodeMapPerfOptions: Sendable {
    public let enabled: Bool
    public let signposts: Bool
    public let collectCounters: Bool

    public static let disabled = CodeMapPerfOptions(enabled: false, signposts: false, collectCounters: false)
    public static let countersOnly = CodeMapPerfOptions(enabled: true, signposts: false, collectCounters: true)
    public static let full = CodeMapPerfOptions(enabled: true, signposts: true, collectCounters: true)

    public init(enabled: Bool, signposts: Bool, collectCounters: Bool) {
        self.enabled = enabled
        self.signposts = signposts
        self.collectCounters = collectCounters
    }
}

public final class CodeMapPerformanceCollector {
    // Builder boundary. Populated only when an invocation-local collector is supplied.
    public var builderTotalDuration: TimeInterval = 0
    public var builderGeneratorDuration: TimeInterval = 0

    // Syntax parse/query stages. These values are populated only when the app
    // supplies this invocation-local collector.
    public var syntaxTotalDuration: TimeInterval = 0
    public var syntaxLanguageLookupDuration: TimeInterval = 0
    public var syntaxOversizeGuardDuration: TimeInterval = 0
    public var syntaxParserCreateDuration: TimeInterval = 0
    public var syntaxSetLanguageDuration: TimeInterval = 0
    public var syntaxParseDuration: TimeInterval = 0
    public var syntaxCodeMapQueryLookupDuration: TimeInterval = 0
    public var syntaxQueryExecuteDuration: TimeInterval = 0
    public var syntaxCaptureMaterializationDuration: TimeInterval = 0
    public var syntaxCaptureNameCountingDuration: TimeInterval = 0
    public var syntaxCalls = 0
    public var syntaxUnsupported = 0
    public var syntaxOversized = 0
    public var syntaxParseNilTree = 0
    public var syntaxParseNilRoot = 0
    public var syntaxParserCreates = 0
    public var syntaxQueryExecutes = 0
    public var syntaxCaptures = 0
    public var syntaxCaptureCountsByName: [String: Int] = [:]
    public let collectsCaptureNames: Bool
    public var syntaxCodeMapQuerySuccessfulLookups = 0

    // Capture index construction and lookup complexity.
    public var captureIndexInputCaptureCount = 0
    public var captureIndexBucketCount = 0
    public var captureIndexFirstContainedLookupCount = 0
    public var captureIndexFirstContainedCandidateVisits = 0
    public var captureIndexAllContainedLookupCount = 0
    public var captureIndexAllContainedCandidateVisits = 0
    public var captureIndexSmallestContainingLookupCount = 0
    public var captureIndexSmallestContainingCandidateVisits = 0
    public var captureIndexMaximumCandidateVisits = 0

    // Swift context construction and declaration volume.
    public var swiftTypeNameMappingDuration: TimeInterval = 0
    public var swiftProtocolNameMappingDuration: TimeInterval = 0
    public var swiftBoundaryConstructionDuration: TimeInterval = 0
    public var swiftFunctionCaptureAssemblyDuration: TimeInterval = 0
    public var swiftTypeDeclarationCount = 0
    public var swiftProtocolDeclarationCount = 0
    public var swiftTopLevelFunctionCount = 0
    public var swiftMethodFunctionCount = 0
    public var swiftProtocolMethodCount = 0
    public var swiftParameterNodeCount = 0
    public var swiftPropertyDeclarationCount = 0
    public var swiftProtocolPropertyDeclarationCount = 0
    public var swiftPropertyIdentifierCount = 0
    public var swiftTypeBoundaryCount = 0

    // Capture loop
    public var capturesProcessed = 0
    public var swiftStrategyHandled = 0
    public var tsStrategyHandled = 0
    public var fallbackHandled = 0
    public var captureLoopLineAdvanceCount = 0
    public var captureLoopSwiftStrategyCount = 0
    public var captureLoopTSStrategyCount = 0
    public var captureLoopInterfaceHeuristicCount = 0
    public var captureLoopImportExportCount = 0
    public var captureLoopTypeAliasCount = 0
    public var captureLoopEnumMacroCount = 0
    public var captureLoopFunctionCount = 0
    public var captureLoopVariableCount = 0
    public var captureLoopSkippedCount = 0
    public var captureLoopUnclassifiedCount = 0
    public var swiftStrategyFunctionSignatureCount = 0
    public var swiftSignatureNormalizationASCIINoOpCount = 0
    public var swiftSignatureNormalizationASCIIRewriteCount = 0
    public var swiftSignatureNormalizationUnicodeFallbackCount = 0
    public var swiftSignatureNormalizationInputUTF8ByteCount = 0
    public var swiftSignatureNormalizationOutputUTF8ByteCount = 0
    public var swiftStrategyFunctionNameLookupCount = 0
    public var swiftStrategyParameterExtractionCount = 0
    public var swiftParameterTypeDirectCaptureCount = 0
    public var swiftParameterTypeFallbackParserCount = 0
    public var swiftParameterTypeASCIIFastPathCount = 0
    public var swiftParameterTypeUnicodeLegacyFallbackCount = 0
    public var swiftParameterTypeInputUTF8ByteCount = 0
    public var swiftStrategyReturnTypeExtractionCount = 0
    public var swiftStrategyPropertyDeclarationCount = 0
    public var swiftStrategyPropertyTypeExtractionCount = 0
    public var swiftPropertyTypeResolutionCount = 0
    public var swiftPropertyTypeASCIIDirectTypeCount = 0
    public var swiftPropertyTypeASCIIDirectNilCount = 0
    public var swiftPropertyTypeLegacyFallbackCount = 0
    public var swiftPropertyTypeUnicodeLegacyFallbackCount = 0
    public var swiftPropertyTypeASCIIIneligibleFallbackCount = 0
    public var swiftPropertyTypeInputUTF8ByteCount = 0
    public var swiftStrategyEnclosingTypeLookupCount = 0
    public var swiftStrategyModelInsertionCount = 0
    public var swiftStrategyContextOnlyCount = 0
    public var swiftStrategyHandledFunctionCount = 0
    public var swiftStrategyHandledPropertyCount = 0
    public var swiftSignatureCodeUnitVisits = 0
    public var swiftNestedFunctionContainmentLookupCount = 0
    public var swiftNestedFunctionContainmentCandidateVisits = 0
    public var swiftEnclosingTypeCandidateVisits = 0
    public var swiftFunctionDuplicateCheckCount = 0
    public var swiftFunctionDuplicateCandidateVisits = 0
    public var swiftPropertyDuplicateCheckCount = 0
    public var swiftPropertyDuplicateCandidateVisits = 0
    public var fallbackFunctionDeclarationCount = 0
    public var fallbackFunctionJSTSSignatureCount = 0
    public var fallbackFunctionNameExtractionCount = 0
    public var fallbackFunctionLTEParseCount = 0
    public var fallbackFunctionTSFastPathCount = 0
    public var fallbackFunctionReferencedTypesCount = 0
    public var fallbackFunctionRoutingCount = 0
    public var fallbackFunctionModelInsertionCount = 0
    public var fallbackFunctionSkippedCount = 0
    public var fallbackFunctionLightweightCount = 0
    public var fallbackFunctionHeavyweightCount = 0
    public var fallbackFunctionGlobalInsertCount = 0
    public var fallbackFunctionMethodInsertCount = 0
    public var fallbackFunctionInterfaceInsertCount = 0

    // Declaration capture + JS/TS signature extraction
    public var captureDeclarationCalls = 0
    public var jstsSignatureCallsFunctionLike = 0
    public var jstsSignatureCallsStatementLike = 0
    public var jstsNormalizationASCIINoOpCount = 0
    public var jstsNormalizationASCIIRewriteCount = 0
    public var jstsNormalizationUnicodeFallbackCount = 0

    // LanguageTypeExtractor
    public var lteMatchAnyFunctionCalls = 0
    public var lteMatchAnyVariableCalls = 0
    public var tsConstructorMatches = 0
    public var tsAccessorMatches = 0
    public var tsClassMethodMatches = 0
    public var tsClassArrowMatches = 0
    public var tsClassArrowNoParensMatches = 0
    public var tsArrowFunctionMatches = 0
    public var tsArrowFunctionParamsReturnMatches = 0
    public var tsxConstructorMatches = 0
    public var tsxAccessorMatches = 0
    public var tsxClassMethodMatches = 0
    public var tsxClassArrowMatches = 0
    public var tsxClassArrowNoParensMatches = 0
    public var tsxArrowFunctionMatches = 0
    public var tsxArrowFunctionParamsReturnMatches = 0
    public var swiftReturnTypeFastPathHits = 0
    public var tsDuplicateFunctionVariableSuppressions = 0
    public var tsReturnTypeFastPathHits = 0
    public var tsTypeAnnotationFastPathHits = 0
    public var tsTypeAliasRhsFastPathHits = 0

    // TypeCleaner
    public var typeCleanerExtractCalls = 0
    public var typeCleanerCacheHits = 0
    public var typeCleanerCacheMisses = 0
    public var typeCleanerSwiftCalls = 0
    public var typeCleanerTSCalls = 0
    public var typeCleanerTSXCalls = 0
    public var typeCleanerJSCalls = 0
    public var typeCleanerOtherLanguageCalls = 0
    public var typeCleanerPrecleanCount = 0
    public var typeCleanerTSLogicCount = 0
    public var typeCleanerNonTSLogicCount = 0
    public var typeCleanerTSObjectLiteralCount = 0
    public var typeCleanerFilterCount = 0
    public var typeCleanerDedupCount = 0
    public var referencedTypesRawInsertions = 0
    public var referencedTypesPrefilterSkips = 0
    public var referencedTypesSwiftDedupEligibleCount = 0
    public var referencedTypesSwiftFirstSeenCount = 0
    public var referencedTypesSwiftDuplicateSkipCount = 0
    public var referencedTypesSwiftDuplicateSkippedUTF8ByteCount = 0
    public var referencedTypesEmptyResults = 0
    public var referencedTypesOutputTypeCount = 0
    public var referencedTypesUniqueCount = 0

    // Extraction memo
    public var extractionMemoJSTSHits = 0
    public var extractionMemoJSTSMisses = 0
    public var extractionMemoFunctionHits = 0
    public var extractionMemoFunctionMisses = 0
    public var extractionMemoFunctionParsedHits = 0
    public var extractionMemoFunctionParsedMisses = 0
    public var extractionMemoVariableHits = 0
    public var extractionMemoVariableMisses = 0
    public var extractionMemoTSFastPathHits = 0
    public var extractionMemoTSFastPathMisses = 0

    // Durations
    public var captureIndexDuration: TimeInterval = 0
    public var swiftContextDuration: TimeInterval = 0
    public var tsContextDuration: TimeInterval = 0
    public var captureLoopDuration: TimeInterval = 0
    public var captureLoopLineAdvanceDuration: TimeInterval = 0
    public var captureLoopSwiftStrategyDuration: TimeInterval = 0
    public var captureLoopTSStrategyDuration: TimeInterval = 0
    public var captureLoopInterfaceHeuristicDuration: TimeInterval = 0
    public var captureLoopImportExportDuration: TimeInterval = 0
    public var captureLoopTypeAliasDuration: TimeInterval = 0
    public var captureLoopEnumMacroDuration: TimeInterval = 0
    public var captureLoopFunctionDuration: TimeInterval = 0
    public var captureLoopVariableDuration: TimeInterval = 0
    public var captureLoopSkippedDuration: TimeInterval = 0
    public var captureLoopUnclassifiedDuration: TimeInterval = 0
    public var swiftStrategyFunctionSignatureDuration: TimeInterval = 0
    public var swiftSignatureEndScanDuration: TimeInterval = 0
    public var swiftSignatureNormalizationDuration: TimeInterval = 0
    public var swiftStrategyFunctionNameLookupDuration: TimeInterval = 0
    public var swiftStrategyParameterExtractionDuration: TimeInterval = 0
    public var swiftParameterTypeResolutionDuration: TimeInterval = 0
    public var swiftParameterTypeLegacyFallbackDuration: TimeInterval = 0
    public var swiftStrategyReturnTypeExtractionDuration: TimeInterval = 0
    public var swiftStrategyPropertyDeclarationDuration: TimeInterval = 0
    public var swiftPropertyDeclarationLookupDuration: TimeInterval = 0
    public var swiftPropertyDeclarationSubstringDuration: TimeInterval = 0
    public var swiftPropertyInitializerStripDuration: TimeInterval = 0
    public var swiftStrategyPropertyTypeExtractionDuration: TimeInterval = 0
    public var swiftPropertyTypeResolutionDuration: TimeInterval = 0
    public var swiftPropertyTypeASCIIFastPathDuration: TimeInterval = 0
    public var swiftPropertyTypeLegacyFallbackDuration: TimeInterval = 0
    public var swiftStrategyEnclosingTypeLookupDuration: TimeInterval = 0
    public var swiftStrategyModelInsertionDuration: TimeInterval = 0
    public var swiftStrategyContextOnlyDuration: TimeInterval = 0
    public var fallbackFunctionDeclarationDuration: TimeInterval = 0
    public var fallbackFunctionJSTSSignatureDuration: TimeInterval = 0
    public var fallbackFunctionNameExtractionDuration: TimeInterval = 0
    public var fallbackFunctionLTEParseDuration: TimeInterval = 0
    public var fallbackFunctionTSFastPathDuration: TimeInterval = 0
    public var fallbackFunctionReferencedTypesDuration: TimeInterval = 0
    public var fallbackFunctionRoutingDuration: TimeInterval = 0
    public var fallbackFunctionModelInsertionDuration: TimeInterval = 0
    public var fallbackFunctionSkippedDuration: TimeInterval = 0
    public var captureDeclarationDuration: TimeInterval = 0
    public var jstsSignatureDuration: TimeInterval = 0
    public var jstsNormalizationASCIIFastPathDuration: TimeInterval = 0
    public var jstsNormalizationLegacyFallbackDuration: TimeInterval = 0
    public var languageTypeExtractorFunctionDuration: TimeInterval = 0
    public var languageTypeExtractorVariableDuration: TimeInterval = 0
    public var typeCleanerDuration: TimeInterval = 0
    public var typeCleanerSwiftDuration: TimeInterval = 0
    public var typeCleanerTSDuration: TimeInterval = 0
    public var typeCleanerTSXDuration: TimeInterval = 0
    public var typeCleanerJSDuration: TimeInterval = 0
    public var typeCleanerOtherLanguageDuration: TimeInterval = 0
    public var typeCleanerPrecleanDuration: TimeInterval = 0
    public var typeCleanerTSLogicDuration: TimeInterval = 0
    public var typeCleanerNonTSLogicDuration: TimeInterval = 0
    public var typeCleanerTSObjectLiteralDuration: TimeInterval = 0
    public var typeCleanerFilterDuration: TimeInterval = 0
    public var typeCleanerDedupDuration: TimeInterval = 0
    public var referencedTypesSwiftRawTypeDedupDuration: TimeInterval = 0
    public var referencedTypesFinalizeDuration: TimeInterval = 0
    public var artifactFinalizationDuration: TimeInterval = 0
    public var artifactMeaningfulContentCheckDuration: TimeInterval = 0
    public var fileAPIInitDuration: TimeInterval = 0
    public var artifactFinalClassCount = 0
    public var artifactFinalInterfaceCount = 0
    public var artifactFinalFunctionCount = 0
    public var artifactFinalGlobalVariableCount = 0

    public init(collectsCaptureNames: Bool = false) {
        self.collectsCaptureNames = collectsCaptureNames
    }
}
