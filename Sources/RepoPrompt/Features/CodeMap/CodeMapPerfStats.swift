//
//  CodeMapPerfStats.swift
//  RepoPrompt
//
//  Lightweight counters for codemap performance analysis.
//  These are expected to be used on a single thread per file scan.
//

import Foundation

struct CodeMapPerfOptions {
    let enabled: Bool
    let signposts: Bool
    let collectCounters: Bool

    static let disabled = CodeMapPerfOptions(enabled: false, signposts: false, collectCounters: false)
    static let countersOnly = CodeMapPerfOptions(enabled: true, signposts: false, collectCounters: true)
    static let full = CodeMapPerfOptions(enabled: true, signposts: true, collectCounters: true)
}

struct CodeMapSyntaxStartupPerfStats {
    var primeDuration: TimeInterval = 0
    var warmCacheDuration: TimeInterval = 0
    var warmCodeMapQueriesDuration: TimeInterval = 0
    var languageConfigCreateDuration: TimeInterval = 0
    var languagePointerDuration: TimeInterval = 0
    var highlightQueryDataDuration: TimeInterval = 0
    var highlightQueryCompileDuration: TimeInterval = 0
    var codeMapQueryDataDuration: TimeInterval = 0
    var codeMapQueryCompileDuration: TimeInterval = 0

    var warmCacheLanguageCount = 0
    var languageConfigCreateCount = 0
    var languageConfigSuccessCount = 0
    var languageConfigFailureCount = 0
    var highlightQueryCompileSuccessCount = 0
    var highlightQueryCompileFailureCount = 0
    var warmCodeMapQueryLanguageCount = 0
    var codeMapQueryPrecomputeSuccessCount = 0
    var codeMapQueryPrecomputeFailureCount = 0
    var codeMapQueryPrecomputeSkippedCount = 0
}

struct CodeMapSyntaxPerfStats {
    var languageLookupDuration: TimeInterval = 0
    var oversizeGuardDuration: TimeInterval = 0
    var parserCreateDuration: TimeInterval = 0
    var setLanguageDuration: TimeInterval = 0
    var parseDuration: TimeInterval = 0
    var codeMapQueryLookupDuration: TimeInterval = 0
    var queryExecuteDuration: TimeInterval = 0
    var captureMaterializationDuration: TimeInterval = 0

    var calls = 0
    var unsupported = 0
    var oversized = 0
    var parseNilTree = 0
    var parseNilRoot = 0
    var parserCreates = 0
    var queryExecutes = 0
    var captures = 0
    var codeMapQueryCacheHits = 0
    var codeMapQueryCacheMisses = 0
}

struct CodeMapPipelinePerfSnapshot: Equatable {
    var snapshotBuildDuration: TimeInterval = 0
    var requestBuildDuration: TimeInterval = 0
    var contentLoadDuration: TimeInterval = 0
    var actorRequestIngestDuration: TimeInterval = 0
    var actorCachePrefetchDuration: TimeInterval = 0
    var actorCacheCheckDuration: TimeInterval = 0
    var actorQueueWaitDuration: TimeInterval = 0
    var parseAndQueryDuration: TimeInterval = 0
    var generatorDuration: TimeInterval = 0
    var batchApplyDuration: TimeInterval = 0
    var syntaxManagerPrimeDuration: TimeInterval = 0
    var syntaxWarmCacheDuration: TimeInterval = 0
    var syntaxWarmCodeMapQueriesDuration: TimeInterval = 0
    var syntaxLanguageConfigCreateDuration: TimeInterval = 0
    var syntaxLanguagePointerDuration: TimeInterval = 0
    var syntaxHighlightQueryDataDuration: TimeInterval = 0
    var syntaxHighlightQueryCompileDuration: TimeInterval = 0
    var syntaxCodeMapQueryDataDuration: TimeInterval = 0
    var syntaxCodeMapQueryCompileDuration: TimeInterval = 0
    var syntaxLanguageLookupDuration: TimeInterval = 0
    var syntaxOversizeGuardDuration: TimeInterval = 0
    var syntaxParserCreateDuration: TimeInterval = 0
    var syntaxSetLanguageDuration: TimeInterval = 0
    var syntaxParseDuration: TimeInterval = 0
    var syntaxCodeMapQueryLookupDuration: TimeInterval = 0
    var syntaxQueryExecuteDuration: TimeInterval = 0
    var syntaxCaptureMaterializationDuration: TimeInterval = 0
    var generatorCaptureIndexDuration: TimeInterval = 0
    var generatorSwiftContextDuration: TimeInterval = 0
    var generatorTSContextDuration: TimeInterval = 0
    var generatorCaptureLoopDuration: TimeInterval = 0
    var generatorCaptureLoopLineAdvanceDuration: TimeInterval = 0
    var generatorCaptureLoopSwiftStrategyDuration: TimeInterval = 0
    var generatorCaptureLoopTSStrategyDuration: TimeInterval = 0
    var generatorCaptureLoopInterfaceHeuristicDuration: TimeInterval = 0
    var generatorCaptureLoopImportExportDuration: TimeInterval = 0
    var generatorCaptureLoopTypeAliasDuration: TimeInterval = 0
    var generatorCaptureLoopEnumMacroDuration: TimeInterval = 0
    var generatorCaptureLoopFunctionDuration: TimeInterval = 0
    var generatorCaptureLoopVariableDuration: TimeInterval = 0
    var generatorCaptureLoopSkippedDuration: TimeInterval = 0
    var generatorCaptureLoopUnclassifiedDuration: TimeInterval = 0
    var generatorSwiftStrategyFunctionSignatureDuration: TimeInterval = 0
    var generatorSwiftStrategyFunctionNameLookupDuration: TimeInterval = 0
    var generatorSwiftStrategyParameterExtractionDuration: TimeInterval = 0
    var generatorSwiftStrategyReturnTypeExtractionDuration: TimeInterval = 0
    var generatorSwiftStrategyPropertyDeclarationDuration: TimeInterval = 0
    var generatorSwiftStrategyPropertyTypeExtractionDuration: TimeInterval = 0
    var generatorSwiftStrategyEnclosingTypeLookupDuration: TimeInterval = 0
    var generatorSwiftStrategyModelInsertionDuration: TimeInterval = 0
    var generatorSwiftStrategyContextOnlyDuration: TimeInterval = 0
    var generatorFallbackFunctionDeclarationDuration: TimeInterval = 0
    var generatorFallbackFunctionJSTSSignatureDuration: TimeInterval = 0
    var generatorFallbackFunctionNameExtractionDuration: TimeInterval = 0
    var generatorFallbackFunctionLTEParseDuration: TimeInterval = 0
    var generatorFallbackFunctionTSFastPathDuration: TimeInterval = 0
    var generatorFallbackFunctionReferencedTypesDuration: TimeInterval = 0
    var generatorFallbackFunctionRoutingDuration: TimeInterval = 0
    var generatorFallbackFunctionModelInsertionDuration: TimeInterval = 0
    var generatorFallbackFunctionSkippedDuration: TimeInterval = 0
    var generatorDeclarationExtractionDuration: TimeInterval = 0
    var generatorJSTSSignatureDuration: TimeInterval = 0
    var generatorLanguageTypeExtractorFunctionDuration: TimeInterval = 0
    var generatorLanguageTypeExtractorVariableDuration: TimeInterval = 0
    var generatorTypeCleanerDuration: TimeInterval = 0
    var generatorTypeCleanerSwiftDuration: TimeInterval = 0
    var generatorTypeCleanerTSDuration: TimeInterval = 0
    var generatorTypeCleanerTSXDuration: TimeInterval = 0
    var generatorTypeCleanerJSDuration: TimeInterval = 0
    var generatorTypeCleanerOtherLanguageDuration: TimeInterval = 0
    var generatorTypeCleanerPrecleanDuration: TimeInterval = 0
    var generatorTypeCleanerTSLogicDuration: TimeInterval = 0
    var generatorTypeCleanerNonTSLogicDuration: TimeInterval = 0
    var generatorTypeCleanerTSObjectLiteralDuration: TimeInterval = 0
    var generatorTypeCleanerFilterDuration: TimeInterval = 0
    var generatorTypeCleanerDedupDuration: TimeInterval = 0
    var generatorReferencedTypesFinalizeDuration: TimeInterval = 0
    var generatorFileAPIInitDuration: TimeInterval = 0

    var requestsBuilt = 0
    var requestsEnqueued = 0
    var cacheHits = 0
    var cacheMisses = 0
    var oversizedSkips = 0
    var parseFailures = 0
    var generatedAPIs = 0
    var nilAPIs = 0
    var codeMapQueryCacheHits = 0
    var codeMapQueryCacheMisses = 0
    var syntaxWarmCacheLanguageCount = 0
    var syntaxLanguageConfigCreateCount = 0
    var syntaxLanguageConfigSuccessCount = 0
    var syntaxLanguageConfigFailureCount = 0
    var syntaxHighlightQueryCompileSuccessCount = 0
    var syntaxHighlightQueryCompileFailureCount = 0
    var syntaxWarmCodeMapQueryLanguageCount = 0
    var syntaxCodeMapQueryPrecomputeSuccessCount = 0
    var syntaxCodeMapQueryPrecomputeFailureCount = 0
    var syntaxCodeMapQueryPrecomputeSkippedCount = 0
    var syntaxCodeMapCalls = 0
    var syntaxUnsupportedExtensionCount = 0
    var syntaxOversizedSkipCount = 0
    var syntaxParseNilTreeCount = 0
    var syntaxParseNilRootCount = 0
    var syntaxParserCreateCount = 0
    var syntaxQueryExecuteCount = 0
    var syntaxCaptureCount = 0
    var capturesProcessed = 0
    var swiftStrategyHandled = 0
    var tsStrategyHandled = 0
    var fallbackHandled = 0
    var generatorCaptureLoopLineAdvanceCount = 0
    var generatorCaptureLoopSwiftStrategyCount = 0
    var generatorCaptureLoopTSStrategyCount = 0
    var generatorCaptureLoopInterfaceHeuristicCount = 0
    var generatorCaptureLoopImportExportCount = 0
    var generatorCaptureLoopTypeAliasCount = 0
    var generatorCaptureLoopEnumMacroCount = 0
    var generatorCaptureLoopFunctionCount = 0
    var generatorCaptureLoopVariableCount = 0
    var generatorCaptureLoopSkippedCount = 0
    var generatorCaptureLoopUnclassifiedCount = 0
    var generatorSwiftStrategyFunctionSignatureCount = 0
    var generatorSwiftStrategyFunctionNameLookupCount = 0
    var generatorSwiftStrategyParameterExtractionCount = 0
    var generatorSwiftStrategyReturnTypeExtractionCount = 0
    var generatorSwiftStrategyPropertyDeclarationCount = 0
    var generatorSwiftStrategyPropertyTypeExtractionCount = 0
    var generatorSwiftStrategyEnclosingTypeLookupCount = 0
    var generatorSwiftStrategyModelInsertionCount = 0
    var generatorSwiftStrategyContextOnlyCount = 0
    var generatorSwiftStrategyHandledFunctionCount = 0
    var generatorSwiftStrategyHandledPropertyCount = 0
    var generatorFallbackFunctionDeclarationCount = 0
    var generatorFallbackFunctionJSTSSignatureCount = 0
    var generatorFallbackFunctionNameExtractionCount = 0
    var generatorFallbackFunctionLTEParseCount = 0
    var generatorFallbackFunctionTSFastPathCount = 0
    var generatorFallbackFunctionReferencedTypesCount = 0
    var generatorFallbackFunctionRoutingCount = 0
    var generatorFallbackFunctionModelInsertionCount = 0
    var generatorFallbackFunctionSkippedCount = 0
    var generatorFallbackFunctionLightweightCount = 0
    var generatorFallbackFunctionHeavyweightCount = 0
    var generatorFallbackFunctionGlobalInsertCount = 0
    var generatorFallbackFunctionMethodInsertCount = 0
    var generatorFallbackFunctionInterfaceInsertCount = 0
    var captureDeclarationCalls = 0
    var jstsSignatureCallsFunctionLike = 0
    var jstsSignatureCallsStatementLike = 0
    var lteMatchAnyFunctionCalls = 0
    var lteMatchAnyVariableCalls = 0
    var typeCleanerExtractCalls = 0
    var typeCleanerCacheHits = 0
    var typeCleanerCacheMisses = 0
    var typeCleanerSwiftCalls = 0
    var typeCleanerTSCalls = 0
    var typeCleanerTSXCalls = 0
    var typeCleanerJSCalls = 0
    var typeCleanerOtherLanguageCalls = 0
    var typeCleanerPrecleanCount = 0
    var typeCleanerTSLogicCount = 0
    var typeCleanerNonTSLogicCount = 0
    var typeCleanerTSObjectLiteralCount = 0
    var typeCleanerFilterCount = 0
    var typeCleanerDedupCount = 0
    var referencedTypesRawInsertions = 0
    var referencedTypesPrefilterSkips = 0
    var referencedTypesEmptyResults = 0
    var referencedTypesOutputTypeCount = 0
    var extractionMemoJSTSHits = 0
    var extractionMemoJSTSMisses = 0
    var extractionMemoFunctionHits = 0
    var extractionMemoFunctionMisses = 0
    var extractionMemoFunctionParsedHits = 0
    var extractionMemoFunctionParsedMisses = 0
    var extractionMemoVariableHits = 0
    var extractionMemoVariableMisses = 0
    var extractionMemoTSFastPathHits = 0
    var extractionMemoTSFastPathMisses = 0

    var resultBatchCount = 0
    var maxResultBatchSize = 0
}

final class CodeMapPipelinePerfStats: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = CodeMapPipelinePerfSnapshot()

    var snapshot: CodeMapPipelinePerfSnapshot {
        lock.withLock { storage }
    }

    func addDuration(_ keyPath: WritableKeyPath<CodeMapPipelinePerfSnapshot, TimeInterval>, _ duration: TimeInterval) {
        lock.withLock {
            storage[keyPath: keyPath] += duration
        }
    }

    func increment(_ keyPath: WritableKeyPath<CodeMapPipelinePerfSnapshot, Int>, by amount: Int = 1) {
        guard amount != 0 else { return }
        lock.withLock {
            storage[keyPath: keyPath] += amount
        }
    }

    func recordResultBatch(size: Int) {
        lock.withLock {
            storage.resultBatchCount += 1
            storage.maxResultBatchSize = max(storage.maxResultBatchSize, size)
        }
    }

    func mergeSyntaxManagerStartupStats(_ stats: CodeMapSyntaxStartupPerfStats) {
        lock.withLock {
            storage.syntaxManagerPrimeDuration += stats.primeDuration
            storage.syntaxWarmCacheDuration += stats.warmCacheDuration
            storage.syntaxWarmCodeMapQueriesDuration += stats.warmCodeMapQueriesDuration
            storage.syntaxLanguageConfigCreateDuration += stats.languageConfigCreateDuration
            storage.syntaxLanguagePointerDuration += stats.languagePointerDuration
            storage.syntaxHighlightQueryDataDuration += stats.highlightQueryDataDuration
            storage.syntaxHighlightQueryCompileDuration += stats.highlightQueryCompileDuration
            storage.syntaxCodeMapQueryDataDuration += stats.codeMapQueryDataDuration
            storage.syntaxCodeMapQueryCompileDuration += stats.codeMapQueryCompileDuration

            storage.syntaxWarmCacheLanguageCount += stats.warmCacheLanguageCount
            storage.syntaxLanguageConfigCreateCount += stats.languageConfigCreateCount
            storage.syntaxLanguageConfigSuccessCount += stats.languageConfigSuccessCount
            storage.syntaxLanguageConfigFailureCount += stats.languageConfigFailureCount
            storage.syntaxHighlightQueryCompileSuccessCount += stats.highlightQueryCompileSuccessCount
            storage.syntaxHighlightQueryCompileFailureCount += stats.highlightQueryCompileFailureCount
            storage.syntaxWarmCodeMapQueryLanguageCount += stats.warmCodeMapQueryLanguageCount
            storage.syntaxCodeMapQueryPrecomputeSuccessCount += stats.codeMapQueryPrecomputeSuccessCount
            storage.syntaxCodeMapQueryPrecomputeFailureCount += stats.codeMapQueryPrecomputeFailureCount
            storage.syntaxCodeMapQueryPrecomputeSkippedCount += stats.codeMapQueryPrecomputeSkippedCount
        }
    }

    func mergeSyntaxCodeMapStats(_ stats: CodeMapSyntaxPerfStats) {
        lock.withLock {
            storage.syntaxLanguageLookupDuration += stats.languageLookupDuration
            storage.syntaxOversizeGuardDuration += stats.oversizeGuardDuration
            storage.syntaxParserCreateDuration += stats.parserCreateDuration
            storage.syntaxSetLanguageDuration += stats.setLanguageDuration
            storage.syntaxParseDuration += stats.parseDuration
            storage.syntaxCodeMapQueryLookupDuration += stats.codeMapQueryLookupDuration
            storage.syntaxQueryExecuteDuration += stats.queryExecuteDuration
            storage.syntaxCaptureMaterializationDuration += stats.captureMaterializationDuration

            storage.syntaxCodeMapCalls += stats.calls
            storage.syntaxUnsupportedExtensionCount += stats.unsupported
            storage.syntaxOversizedSkipCount += stats.oversized
            storage.syntaxParseNilTreeCount += stats.parseNilTree
            storage.syntaxParseNilRootCount += stats.parseNilRoot
            storage.syntaxParserCreateCount += stats.parserCreates
            storage.syntaxQueryExecuteCount += stats.queryExecutes
            storage.syntaxCaptureCount += stats.captures
            storage.codeMapQueryCacheHits += stats.codeMapQueryCacheHits
            storage.codeMapQueryCacheMisses += stats.codeMapQueryCacheMisses
        }
    }

    func mergeGeneratorStats(_ stats: CodeMapPerfStats) {
        lock.withLock {
            storage.generatorCaptureIndexDuration += stats.captureIndexDuration
            storage.generatorSwiftContextDuration += stats.swiftContextDuration
            storage.generatorTSContextDuration += stats.tsContextDuration
            storage.generatorCaptureLoopDuration += stats.captureLoopDuration
            storage.generatorCaptureLoopLineAdvanceDuration += stats.captureLoopLineAdvanceDuration
            storage.generatorCaptureLoopSwiftStrategyDuration += stats.captureLoopSwiftStrategyDuration
            storage.generatorCaptureLoopTSStrategyDuration += stats.captureLoopTSStrategyDuration
            storage.generatorCaptureLoopInterfaceHeuristicDuration += stats.captureLoopInterfaceHeuristicDuration
            storage.generatorCaptureLoopImportExportDuration += stats.captureLoopImportExportDuration
            storage.generatorCaptureLoopTypeAliasDuration += stats.captureLoopTypeAliasDuration
            storage.generatorCaptureLoopEnumMacroDuration += stats.captureLoopEnumMacroDuration
            storage.generatorCaptureLoopFunctionDuration += stats.captureLoopFunctionDuration
            storage.generatorCaptureLoopVariableDuration += stats.captureLoopVariableDuration
            storage.generatorCaptureLoopSkippedDuration += stats.captureLoopSkippedDuration
            storage.generatorCaptureLoopUnclassifiedDuration += stats.captureLoopUnclassifiedDuration
            storage.generatorSwiftStrategyFunctionSignatureDuration += stats.swiftStrategyFunctionSignatureDuration
            storage.generatorSwiftStrategyFunctionNameLookupDuration += stats.swiftStrategyFunctionNameLookupDuration
            storage.generatorSwiftStrategyParameterExtractionDuration += stats.swiftStrategyParameterExtractionDuration
            storage.generatorSwiftStrategyReturnTypeExtractionDuration += stats.swiftStrategyReturnTypeExtractionDuration
            storage.generatorSwiftStrategyPropertyDeclarationDuration += stats.swiftStrategyPropertyDeclarationDuration
            storage.generatorSwiftStrategyPropertyTypeExtractionDuration += stats.swiftStrategyPropertyTypeExtractionDuration
            storage.generatorSwiftStrategyEnclosingTypeLookupDuration += stats.swiftStrategyEnclosingTypeLookupDuration
            storage.generatorSwiftStrategyModelInsertionDuration += stats.swiftStrategyModelInsertionDuration
            storage.generatorSwiftStrategyContextOnlyDuration += stats.swiftStrategyContextOnlyDuration
            storage.generatorFallbackFunctionDeclarationDuration += stats.fallbackFunctionDeclarationDuration
            storage.generatorFallbackFunctionJSTSSignatureDuration += stats.fallbackFunctionJSTSSignatureDuration
            storage.generatorFallbackFunctionNameExtractionDuration += stats.fallbackFunctionNameExtractionDuration
            storage.generatorFallbackFunctionLTEParseDuration += stats.fallbackFunctionLTEParseDuration
            storage.generatorFallbackFunctionTSFastPathDuration += stats.fallbackFunctionTSFastPathDuration
            storage.generatorFallbackFunctionReferencedTypesDuration += stats.fallbackFunctionReferencedTypesDuration
            storage.generatorFallbackFunctionRoutingDuration += stats.fallbackFunctionRoutingDuration
            storage.generatorFallbackFunctionModelInsertionDuration += stats.fallbackFunctionModelInsertionDuration
            storage.generatorFallbackFunctionSkippedDuration += stats.fallbackFunctionSkippedDuration
            storage.generatorDeclarationExtractionDuration += stats.captureDeclarationDuration
            storage.generatorJSTSSignatureDuration += stats.jstsSignatureDuration
            storage.generatorLanguageTypeExtractorFunctionDuration += stats.languageTypeExtractorFunctionDuration
            storage.generatorLanguageTypeExtractorVariableDuration += stats.languageTypeExtractorVariableDuration
            storage.generatorTypeCleanerDuration += stats.typeCleanerDuration
            storage.generatorTypeCleanerSwiftDuration += stats.typeCleanerSwiftDuration
            storage.generatorTypeCleanerTSDuration += stats.typeCleanerTSDuration
            storage.generatorTypeCleanerTSXDuration += stats.typeCleanerTSXDuration
            storage.generatorTypeCleanerJSDuration += stats.typeCleanerJSDuration
            storage.generatorTypeCleanerOtherLanguageDuration += stats.typeCleanerOtherLanguageDuration
            storage.generatorTypeCleanerPrecleanDuration += stats.typeCleanerPrecleanDuration
            storage.generatorTypeCleanerTSLogicDuration += stats.typeCleanerTSLogicDuration
            storage.generatorTypeCleanerNonTSLogicDuration += stats.typeCleanerNonTSLogicDuration
            storage.generatorTypeCleanerTSObjectLiteralDuration += stats.typeCleanerTSObjectLiteralDuration
            storage.generatorTypeCleanerFilterDuration += stats.typeCleanerFilterDuration
            storage.generatorTypeCleanerDedupDuration += stats.typeCleanerDedupDuration
            storage.generatorReferencedTypesFinalizeDuration += stats.referencedTypesFinalizeDuration
            storage.generatorFileAPIInitDuration += stats.fileAPIInitDuration

            storage.capturesProcessed += stats.capturesProcessed
            storage.swiftStrategyHandled += stats.swiftStrategyHandled
            storage.tsStrategyHandled += stats.tsStrategyHandled
            storage.fallbackHandled += stats.fallbackHandled
            storage.generatorCaptureLoopLineAdvanceCount += stats.captureLoopLineAdvanceCount
            storage.generatorCaptureLoopSwiftStrategyCount += stats.captureLoopSwiftStrategyCount
            storage.generatorCaptureLoopTSStrategyCount += stats.captureLoopTSStrategyCount
            storage.generatorCaptureLoopInterfaceHeuristicCount += stats.captureLoopInterfaceHeuristicCount
            storage.generatorCaptureLoopImportExportCount += stats.captureLoopImportExportCount
            storage.generatorCaptureLoopTypeAliasCount += stats.captureLoopTypeAliasCount
            storage.generatorCaptureLoopEnumMacroCount += stats.captureLoopEnumMacroCount
            storage.generatorCaptureLoopFunctionCount += stats.captureLoopFunctionCount
            storage.generatorCaptureLoopVariableCount += stats.captureLoopVariableCount
            storage.generatorCaptureLoopSkippedCount += stats.captureLoopSkippedCount
            storage.generatorCaptureLoopUnclassifiedCount += stats.captureLoopUnclassifiedCount
            storage.generatorSwiftStrategyFunctionSignatureCount += stats.swiftStrategyFunctionSignatureCount
            storage.generatorSwiftStrategyFunctionNameLookupCount += stats.swiftStrategyFunctionNameLookupCount
            storage.generatorSwiftStrategyParameterExtractionCount += stats.swiftStrategyParameterExtractionCount
            storage.generatorSwiftStrategyReturnTypeExtractionCount += stats.swiftStrategyReturnTypeExtractionCount
            storage.generatorSwiftStrategyPropertyDeclarationCount += stats.swiftStrategyPropertyDeclarationCount
            storage.generatorSwiftStrategyPropertyTypeExtractionCount += stats.swiftStrategyPropertyTypeExtractionCount
            storage.generatorSwiftStrategyEnclosingTypeLookupCount += stats.swiftStrategyEnclosingTypeLookupCount
            storage.generatorSwiftStrategyModelInsertionCount += stats.swiftStrategyModelInsertionCount
            storage.generatorSwiftStrategyContextOnlyCount += stats.swiftStrategyContextOnlyCount
            storage.generatorSwiftStrategyHandledFunctionCount += stats.swiftStrategyHandledFunctionCount
            storage.generatorSwiftStrategyHandledPropertyCount += stats.swiftStrategyHandledPropertyCount
            storage.generatorFallbackFunctionDeclarationCount += stats.fallbackFunctionDeclarationCount
            storage.generatorFallbackFunctionJSTSSignatureCount += stats.fallbackFunctionJSTSSignatureCount
            storage.generatorFallbackFunctionNameExtractionCount += stats.fallbackFunctionNameExtractionCount
            storage.generatorFallbackFunctionLTEParseCount += stats.fallbackFunctionLTEParseCount
            storage.generatorFallbackFunctionTSFastPathCount += stats.fallbackFunctionTSFastPathCount
            storage.generatorFallbackFunctionReferencedTypesCount += stats.fallbackFunctionReferencedTypesCount
            storage.generatorFallbackFunctionRoutingCount += stats.fallbackFunctionRoutingCount
            storage.generatorFallbackFunctionModelInsertionCount += stats.fallbackFunctionModelInsertionCount
            storage.generatorFallbackFunctionSkippedCount += stats.fallbackFunctionSkippedCount
            storage.generatorFallbackFunctionLightweightCount += stats.fallbackFunctionLightweightCount
            storage.generatorFallbackFunctionHeavyweightCount += stats.fallbackFunctionHeavyweightCount
            storage.generatorFallbackFunctionGlobalInsertCount += stats.fallbackFunctionGlobalInsertCount
            storage.generatorFallbackFunctionMethodInsertCount += stats.fallbackFunctionMethodInsertCount
            storage.generatorFallbackFunctionInterfaceInsertCount += stats.fallbackFunctionInterfaceInsertCount
            storage.captureDeclarationCalls += stats.captureDeclarationCalls
            storage.jstsSignatureCallsFunctionLike += stats.jstsSignatureCallsFunctionLike
            storage.jstsSignatureCallsStatementLike += stats.jstsSignatureCallsStatementLike
            storage.lteMatchAnyFunctionCalls += stats.lteMatchAnyFunctionCalls
            storage.lteMatchAnyVariableCalls += stats.lteMatchAnyVariableCalls
            storage.typeCleanerExtractCalls += stats.typeCleanerExtractCalls
            storage.typeCleanerCacheHits += stats.typeCleanerCacheHits
            storage.typeCleanerCacheMisses += stats.typeCleanerCacheMisses
            storage.typeCleanerSwiftCalls += stats.typeCleanerSwiftCalls
            storage.typeCleanerTSCalls += stats.typeCleanerTSCalls
            storage.typeCleanerTSXCalls += stats.typeCleanerTSXCalls
            storage.typeCleanerJSCalls += stats.typeCleanerJSCalls
            storage.typeCleanerOtherLanguageCalls += stats.typeCleanerOtherLanguageCalls
            storage.typeCleanerPrecleanCount += stats.typeCleanerPrecleanCount
            storage.typeCleanerTSLogicCount += stats.typeCleanerTSLogicCount
            storage.typeCleanerNonTSLogicCount += stats.typeCleanerNonTSLogicCount
            storage.typeCleanerTSObjectLiteralCount += stats.typeCleanerTSObjectLiteralCount
            storage.typeCleanerFilterCount += stats.typeCleanerFilterCount
            storage.typeCleanerDedupCount += stats.typeCleanerDedupCount
            storage.referencedTypesRawInsertions += stats.referencedTypesRawInsertions
            storage.referencedTypesPrefilterSkips += stats.referencedTypesPrefilterSkips
            storage.referencedTypesEmptyResults += stats.referencedTypesEmptyResults
            storage.referencedTypesOutputTypeCount += stats.referencedTypesOutputTypeCount
            storage.extractionMemoJSTSHits += stats.extractionMemoJSTSHits
            storage.extractionMemoJSTSMisses += stats.extractionMemoJSTSMisses
            storage.extractionMemoFunctionHits += stats.extractionMemoFunctionHits
            storage.extractionMemoFunctionMisses += stats.extractionMemoFunctionMisses
            storage.extractionMemoFunctionParsedHits += stats.extractionMemoFunctionParsedHits
            storage.extractionMemoFunctionParsedMisses += stats.extractionMemoFunctionParsedMisses
            storage.extractionMemoVariableHits += stats.extractionMemoVariableHits
            storage.extractionMemoVariableMisses += stats.extractionMemoVariableMisses
            storage.extractionMemoTSFastPathHits += stats.extractionMemoTSFastPathHits
            storage.extractionMemoTSFastPathMisses += stats.extractionMemoTSFastPathMisses
        }
    }
}

enum CodeMapPerfRuntime {
    static let instrumentationEnvironmentKey = "REPOPROMPT_CODEMAP_PERF"
    static let benchmarkEnvironmentKey = "REPOPROMPT_RUN_CODEMAP_BENCHMARKS"
    static let benchmarkIterationsEnvironmentKey = "REPOPROMPT_CODEMAP_BENCHMARK_ITERATIONS"
    static let benchmarkMarkerURL = MCPFilesystemConstants.identity.temporaryRootURL()
        .appendingPathComponent("run-codemap-benchmarks", isDirectory: false)

    #if DEBUG || CODEMAP_PERF
        static let isCompiledIn = true
    #else
        static let isCompiledIn = false
    #endif

    private static var benchmarkMarkerEnabled: Bool {
        guard isCompiledIn else { return false }
        return !isRunningInCI && FileManager.default.fileExists(atPath: benchmarkMarkerURL.path)
    }

    private static var benchmarkRequested: Bool {
        guard isCompiledIn else { return false }
        return environmentFlagEnabled(benchmarkEnvironmentKey)
            || CommandLine.arguments.contains("--run-codemap-benchmarks")
            || benchmarkMarkerEnabled
    }

    static let isEnabled: Bool = {
        guard isCompiledIn else { return false }
        return environmentFlagEnabled(instrumentationEnvironmentKey) || benchmarkRequested
    }()

    static let sharedPipelineStats: CodeMapPipelinePerfStats? = isEnabled ? CodeMapPipelinePerfStats() : nil

    static func makeGeneratorOptions() -> CodeMapPerfOptions {
        isEnabled ? .countersOnly : .disabled
    }

    static func makeGeneratorStats() -> CodeMapPerfStats? {
        isEnabled ? CodeMapPerfStats() : nil
    }

    @inline(__always)
    static func activeOptions(_ options: CodeMapPerfOptions) -> CodeMapPerfOptions {
        #if DEBUG || CODEMAP_PERF
            return options
        #else
            return .disabled
        #endif
    }

    @inline(__always)
    static func activeStats(_ stats: CodeMapPerfStats?) -> CodeMapPerfStats? {
        #if DEBUG || CODEMAP_PERF
            return stats
        #else
            return nil
        #endif
    }

    static var shouldRunBenchmarks: Bool {
        benchmarkRequested
    }

    static var isRunningInCI: Bool {
        ["CI", "GITHUB_ACTIONS", "BUILDKITE", "JENKINS_URL", "TEAMCITY_VERSION"].contains { key in
            ProcessInfo.processInfo.environment[key] != nil
        }
    }

    static func environmentFlagEnabled(_ name: String) -> Bool {
        guard let rawValue = ProcessInfo.processInfo.environment[name] else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled", "enable", "run":
            return true
        default:
            return false
        }
    }

    static func currentTime() -> DispatchTime {
        DispatchTime.now()
    }

    static func durationSince(_ start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
    }
}

final class CodeMapPerfStats {
    // Capture loop
    var capturesProcessed = 0
    var swiftStrategyHandled = 0
    var tsStrategyHandled = 0
    var fallbackHandled = 0
    var captureLoopLineAdvanceCount = 0
    var captureLoopSwiftStrategyCount = 0
    var captureLoopTSStrategyCount = 0
    var captureLoopInterfaceHeuristicCount = 0
    var captureLoopImportExportCount = 0
    var captureLoopTypeAliasCount = 0
    var captureLoopEnumMacroCount = 0
    var captureLoopFunctionCount = 0
    var captureLoopVariableCount = 0
    var captureLoopSkippedCount = 0
    var captureLoopUnclassifiedCount = 0
    var swiftStrategyFunctionSignatureCount = 0
    var swiftStrategyFunctionNameLookupCount = 0
    var swiftStrategyParameterExtractionCount = 0
    var swiftStrategyReturnTypeExtractionCount = 0
    var swiftStrategyPropertyDeclarationCount = 0
    var swiftStrategyPropertyTypeExtractionCount = 0
    var swiftStrategyEnclosingTypeLookupCount = 0
    var swiftStrategyModelInsertionCount = 0
    var swiftStrategyContextOnlyCount = 0
    var swiftStrategyHandledFunctionCount = 0
    var swiftStrategyHandledPropertyCount = 0
    var fallbackFunctionDeclarationCount = 0
    var fallbackFunctionJSTSSignatureCount = 0
    var fallbackFunctionNameExtractionCount = 0
    var fallbackFunctionLTEParseCount = 0
    var fallbackFunctionTSFastPathCount = 0
    var fallbackFunctionReferencedTypesCount = 0
    var fallbackFunctionRoutingCount = 0
    var fallbackFunctionModelInsertionCount = 0
    var fallbackFunctionSkippedCount = 0
    var fallbackFunctionLightweightCount = 0
    var fallbackFunctionHeavyweightCount = 0
    var fallbackFunctionGlobalInsertCount = 0
    var fallbackFunctionMethodInsertCount = 0
    var fallbackFunctionInterfaceInsertCount = 0

    // Declaration capture + JS/TS signature extraction
    var captureDeclarationCalls = 0
    var jstsSignatureCallsFunctionLike = 0
    var jstsSignatureCallsStatementLike = 0

    // LanguageTypeExtractor
    var lteMatchAnyFunctionCalls = 0
    var lteMatchAnyVariableCalls = 0
    var tsConstructorMatches = 0
    var tsAccessorMatches = 0
    var tsClassMethodMatches = 0
    var tsClassArrowMatches = 0
    var tsClassArrowNoParensMatches = 0
    var tsArrowFunctionMatches = 0
    var tsArrowFunctionParamsReturnMatches = 0
    var tsxConstructorMatches = 0
    var tsxAccessorMatches = 0
    var tsxClassMethodMatches = 0
    var tsxClassArrowMatches = 0
    var tsxClassArrowNoParensMatches = 0
    var tsxArrowFunctionMatches = 0
    var tsxArrowFunctionParamsReturnMatches = 0
    var swiftReturnTypeFastPathHits = 0
    var tsReturnTypeFastPathHits = 0
    var tsTypeAnnotationFastPathHits = 0
    var tsTypeAliasRhsFastPathHits = 0

    // TypeCleaner
    var typeCleanerExtractCalls = 0
    var typeCleanerCacheHits = 0
    var typeCleanerCacheMisses = 0
    var typeCleanerSwiftCalls = 0
    var typeCleanerTSCalls = 0
    var typeCleanerTSXCalls = 0
    var typeCleanerJSCalls = 0
    var typeCleanerOtherLanguageCalls = 0
    var typeCleanerPrecleanCount = 0
    var typeCleanerTSLogicCount = 0
    var typeCleanerNonTSLogicCount = 0
    var typeCleanerTSObjectLiteralCount = 0
    var typeCleanerFilterCount = 0
    var typeCleanerDedupCount = 0
    var referencedTypesRawInsertions = 0
    var referencedTypesPrefilterSkips = 0
    var referencedTypesEmptyResults = 0
    var referencedTypesOutputTypeCount = 0

    // Extraction memo
    var extractionMemoJSTSHits = 0
    var extractionMemoJSTSMisses = 0
    var extractionMemoFunctionHits = 0
    var extractionMemoFunctionMisses = 0
    var extractionMemoFunctionParsedHits = 0
    var extractionMemoFunctionParsedMisses = 0
    var extractionMemoVariableHits = 0
    var extractionMemoVariableMisses = 0
    var extractionMemoTSFastPathHits = 0
    var extractionMemoTSFastPathMisses = 0

    // Durations
    var captureIndexDuration: TimeInterval = 0
    var swiftContextDuration: TimeInterval = 0
    var tsContextDuration: TimeInterval = 0
    var captureLoopDuration: TimeInterval = 0
    var captureLoopLineAdvanceDuration: TimeInterval = 0
    var captureLoopSwiftStrategyDuration: TimeInterval = 0
    var captureLoopTSStrategyDuration: TimeInterval = 0
    var captureLoopInterfaceHeuristicDuration: TimeInterval = 0
    var captureLoopImportExportDuration: TimeInterval = 0
    var captureLoopTypeAliasDuration: TimeInterval = 0
    var captureLoopEnumMacroDuration: TimeInterval = 0
    var captureLoopFunctionDuration: TimeInterval = 0
    var captureLoopVariableDuration: TimeInterval = 0
    var captureLoopSkippedDuration: TimeInterval = 0
    var captureLoopUnclassifiedDuration: TimeInterval = 0
    var swiftStrategyFunctionSignatureDuration: TimeInterval = 0
    var swiftStrategyFunctionNameLookupDuration: TimeInterval = 0
    var swiftStrategyParameterExtractionDuration: TimeInterval = 0
    var swiftStrategyReturnTypeExtractionDuration: TimeInterval = 0
    var swiftStrategyPropertyDeclarationDuration: TimeInterval = 0
    var swiftStrategyPropertyTypeExtractionDuration: TimeInterval = 0
    var swiftStrategyEnclosingTypeLookupDuration: TimeInterval = 0
    var swiftStrategyModelInsertionDuration: TimeInterval = 0
    var swiftStrategyContextOnlyDuration: TimeInterval = 0
    var fallbackFunctionDeclarationDuration: TimeInterval = 0
    var fallbackFunctionJSTSSignatureDuration: TimeInterval = 0
    var fallbackFunctionNameExtractionDuration: TimeInterval = 0
    var fallbackFunctionLTEParseDuration: TimeInterval = 0
    var fallbackFunctionTSFastPathDuration: TimeInterval = 0
    var fallbackFunctionReferencedTypesDuration: TimeInterval = 0
    var fallbackFunctionRoutingDuration: TimeInterval = 0
    var fallbackFunctionModelInsertionDuration: TimeInterval = 0
    var fallbackFunctionSkippedDuration: TimeInterval = 0
    var captureDeclarationDuration: TimeInterval = 0
    var jstsSignatureDuration: TimeInterval = 0
    var languageTypeExtractorFunctionDuration: TimeInterval = 0
    var languageTypeExtractorVariableDuration: TimeInterval = 0
    var typeCleanerDuration: TimeInterval = 0
    var typeCleanerSwiftDuration: TimeInterval = 0
    var typeCleanerTSDuration: TimeInterval = 0
    var typeCleanerTSXDuration: TimeInterval = 0
    var typeCleanerJSDuration: TimeInterval = 0
    var typeCleanerOtherLanguageDuration: TimeInterval = 0
    var typeCleanerPrecleanDuration: TimeInterval = 0
    var typeCleanerTSLogicDuration: TimeInterval = 0
    var typeCleanerNonTSLogicDuration: TimeInterval = 0
    var typeCleanerTSObjectLiteralDuration: TimeInterval = 0
    var typeCleanerFilterDuration: TimeInterval = 0
    var typeCleanerDedupDuration: TimeInterval = 0
    var referencedTypesFinalizeDuration: TimeInterval = 0
    var fileAPIInitDuration: TimeInterval = 0
}
