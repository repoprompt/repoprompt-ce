import Foundation

package struct CodeMapPerfOptions: Sendable {
    package let enabled: Bool
    package let signposts: Bool
    package let collectCounters: Bool

    package static let disabled = CodeMapPerfOptions(enabled: false, signposts: false, collectCounters: false)
    package static let countersOnly = CodeMapPerfOptions(enabled: true, signposts: false, collectCounters: true)
    package static let full = CodeMapPerfOptions(enabled: true, signposts: true, collectCounters: true)

    package init(enabled: Bool, signposts: Bool, collectCounters: Bool) {
        self.enabled = enabled
        self.signposts = signposts
        self.collectCounters = collectCounters
    }
}

package final class CodeMapPerformanceCollector {
    // Syntax parse/query stages. These values are populated only when the app
    // supplies this invocation-local collector.
    package var syntaxLanguageLookupDuration: TimeInterval = 0
    package var syntaxOversizeGuardDuration: TimeInterval = 0
    package var syntaxParserCreateDuration: TimeInterval = 0
    package var syntaxSetLanguageDuration: TimeInterval = 0
    package var syntaxParseDuration: TimeInterval = 0
    package var syntaxCodeMapQueryLookupDuration: TimeInterval = 0
    package var syntaxQueryExecuteDuration: TimeInterval = 0
    package var syntaxCaptureMaterializationDuration: TimeInterval = 0
    package var syntaxCalls = 0
    package var syntaxUnsupported = 0
    package var syntaxOversized = 0
    package var syntaxParseNilTree = 0
    package var syntaxParseNilRoot = 0
    package var syntaxParserCreates = 0
    package var syntaxQueryExecutes = 0
    package var syntaxCaptures = 0
    package var syntaxCodeMapQueryCacheHits = 0
    package var syntaxCodeMapQueryCacheMisses = 0

    // Capture loop
    package var capturesProcessed = 0
    package var swiftStrategyHandled = 0
    package var tsStrategyHandled = 0
    package var fallbackHandled = 0
    package var captureLoopLineAdvanceCount = 0
    package var captureLoopSwiftStrategyCount = 0
    package var captureLoopTSStrategyCount = 0
    package var captureLoopInterfaceHeuristicCount = 0
    package var captureLoopImportExportCount = 0
    package var captureLoopTypeAliasCount = 0
    package var captureLoopEnumMacroCount = 0
    package var captureLoopFunctionCount = 0
    package var captureLoopVariableCount = 0
    package var captureLoopSkippedCount = 0
    package var captureLoopUnclassifiedCount = 0
    package var swiftStrategyFunctionSignatureCount = 0
    package var swiftStrategyFunctionNameLookupCount = 0
    package var swiftStrategyParameterExtractionCount = 0
    package var swiftStrategyReturnTypeExtractionCount = 0
    package var swiftStrategyPropertyDeclarationCount = 0
    package var swiftStrategyPropertyTypeExtractionCount = 0
    package var swiftStrategyEnclosingTypeLookupCount = 0
    package var swiftStrategyModelInsertionCount = 0
    package var swiftStrategyContextOnlyCount = 0
    package var swiftStrategyHandledFunctionCount = 0
    package var swiftStrategyHandledPropertyCount = 0
    package var fallbackFunctionDeclarationCount = 0
    package var fallbackFunctionJSTSSignatureCount = 0
    package var fallbackFunctionNameExtractionCount = 0
    package var fallbackFunctionLTEParseCount = 0
    package var fallbackFunctionTSFastPathCount = 0
    package var fallbackFunctionReferencedTypesCount = 0
    package var fallbackFunctionRoutingCount = 0
    package var fallbackFunctionModelInsertionCount = 0
    package var fallbackFunctionSkippedCount = 0
    package var fallbackFunctionLightweightCount = 0
    package var fallbackFunctionHeavyweightCount = 0
    package var fallbackFunctionGlobalInsertCount = 0
    package var fallbackFunctionMethodInsertCount = 0
    package var fallbackFunctionInterfaceInsertCount = 0

    // Declaration capture + JS/TS signature extraction
    package var captureDeclarationCalls = 0
    package var jstsSignatureCallsFunctionLike = 0
    package var jstsSignatureCallsStatementLike = 0

    // LanguageTypeExtractor
    package var lteMatchAnyFunctionCalls = 0
    package var lteMatchAnyVariableCalls = 0
    package var tsConstructorMatches = 0
    package var tsAccessorMatches = 0
    package var tsClassMethodMatches = 0
    package var tsClassArrowMatches = 0
    package var tsClassArrowNoParensMatches = 0
    package var tsArrowFunctionMatches = 0
    package var tsArrowFunctionParamsReturnMatches = 0
    package var tsxConstructorMatches = 0
    package var tsxAccessorMatches = 0
    package var tsxClassMethodMatches = 0
    package var tsxClassArrowMatches = 0
    package var tsxClassArrowNoParensMatches = 0
    package var tsxArrowFunctionMatches = 0
    package var tsxArrowFunctionParamsReturnMatches = 0
    package var swiftReturnTypeFastPathHits = 0
    package var tsReturnTypeFastPathHits = 0
    package var tsTypeAnnotationFastPathHits = 0
    package var tsTypeAliasRhsFastPathHits = 0

    // TypeCleaner
    package var typeCleanerExtractCalls = 0
    package var typeCleanerCacheHits = 0
    package var typeCleanerCacheMisses = 0
    package var typeCleanerSwiftCalls = 0
    package var typeCleanerTSCalls = 0
    package var typeCleanerTSXCalls = 0
    package var typeCleanerJSCalls = 0
    package var typeCleanerOtherLanguageCalls = 0
    package var typeCleanerPrecleanCount = 0
    package var typeCleanerTSLogicCount = 0
    package var typeCleanerNonTSLogicCount = 0
    package var typeCleanerTSObjectLiteralCount = 0
    package var typeCleanerFilterCount = 0
    package var typeCleanerDedupCount = 0
    package var referencedTypesRawInsertions = 0
    package var referencedTypesPrefilterSkips = 0
    package var referencedTypesEmptyResults = 0
    package var referencedTypesOutputTypeCount = 0

    // Extraction memo
    package var extractionMemoJSTSHits = 0
    package var extractionMemoJSTSMisses = 0
    package var extractionMemoFunctionHits = 0
    package var extractionMemoFunctionMisses = 0
    package var extractionMemoFunctionParsedHits = 0
    package var extractionMemoFunctionParsedMisses = 0
    package var extractionMemoVariableHits = 0
    package var extractionMemoVariableMisses = 0
    package var extractionMemoTSFastPathHits = 0
    package var extractionMemoTSFastPathMisses = 0

    // Durations
    package var captureIndexDuration: TimeInterval = 0
    package var swiftContextDuration: TimeInterval = 0
    package var tsContextDuration: TimeInterval = 0
    package var captureLoopDuration: TimeInterval = 0
    package var captureLoopLineAdvanceDuration: TimeInterval = 0
    package var captureLoopSwiftStrategyDuration: TimeInterval = 0
    package var captureLoopTSStrategyDuration: TimeInterval = 0
    package var captureLoopInterfaceHeuristicDuration: TimeInterval = 0
    package var captureLoopImportExportDuration: TimeInterval = 0
    package var captureLoopTypeAliasDuration: TimeInterval = 0
    package var captureLoopEnumMacroDuration: TimeInterval = 0
    package var captureLoopFunctionDuration: TimeInterval = 0
    package var captureLoopVariableDuration: TimeInterval = 0
    package var captureLoopSkippedDuration: TimeInterval = 0
    package var captureLoopUnclassifiedDuration: TimeInterval = 0
    package var swiftStrategyFunctionSignatureDuration: TimeInterval = 0
    package var swiftStrategyFunctionNameLookupDuration: TimeInterval = 0
    package var swiftStrategyParameterExtractionDuration: TimeInterval = 0
    package var swiftStrategyReturnTypeExtractionDuration: TimeInterval = 0
    package var swiftStrategyPropertyDeclarationDuration: TimeInterval = 0
    package var swiftStrategyPropertyTypeExtractionDuration: TimeInterval = 0
    package var swiftStrategyEnclosingTypeLookupDuration: TimeInterval = 0
    package var swiftStrategyModelInsertionDuration: TimeInterval = 0
    package var swiftStrategyContextOnlyDuration: TimeInterval = 0
    package var fallbackFunctionDeclarationDuration: TimeInterval = 0
    package var fallbackFunctionJSTSSignatureDuration: TimeInterval = 0
    package var fallbackFunctionNameExtractionDuration: TimeInterval = 0
    package var fallbackFunctionLTEParseDuration: TimeInterval = 0
    package var fallbackFunctionTSFastPathDuration: TimeInterval = 0
    package var fallbackFunctionReferencedTypesDuration: TimeInterval = 0
    package var fallbackFunctionRoutingDuration: TimeInterval = 0
    package var fallbackFunctionModelInsertionDuration: TimeInterval = 0
    package var fallbackFunctionSkippedDuration: TimeInterval = 0
    package var captureDeclarationDuration: TimeInterval = 0
    package var jstsSignatureDuration: TimeInterval = 0
    package var languageTypeExtractorFunctionDuration: TimeInterval = 0
    package var languageTypeExtractorVariableDuration: TimeInterval = 0
    package var typeCleanerDuration: TimeInterval = 0
    package var typeCleanerSwiftDuration: TimeInterval = 0
    package var typeCleanerTSDuration: TimeInterval = 0
    package var typeCleanerTSXDuration: TimeInterval = 0
    package var typeCleanerJSDuration: TimeInterval = 0
    package var typeCleanerOtherLanguageDuration: TimeInterval = 0
    package var typeCleanerPrecleanDuration: TimeInterval = 0
    package var typeCleanerTSLogicDuration: TimeInterval = 0
    package var typeCleanerNonTSLogicDuration: TimeInterval = 0
    package var typeCleanerTSObjectLiteralDuration: TimeInterval = 0
    package var typeCleanerFilterDuration: TimeInterval = 0
    package var typeCleanerDedupDuration: TimeInterval = 0
    package var referencedTypesFinalizeDuration: TimeInterval = 0
    package var fileAPIInitDuration: TimeInterval = 0

    package init() {}
}
