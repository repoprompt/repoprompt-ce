//
//  CodeMapPerfStats.swift
//  RepoPrompt
//
//  Lightweight counters for codemap performance analysis.
//  These are expected to be used on a single thread per file scan.
//

import Foundation

package struct CodeMapPerfOptions {
    package let enabled: Bool
    package let collectCounters: Bool

    package static let disabled = CodeMapPerfOptions(enabled: false, collectCounters: false)
    package static let countersOnly = CodeMapPerfOptions(enabled: true, collectCounters: true)
}

package struct CodeMapSyntaxStartupPerfStats {
    package var primeDuration: TimeInterval = 0
    package var warmCacheDuration: TimeInterval = 0
    package var warmCodeMapQueriesDuration: TimeInterval = 0
    package var languageConfigCreateDuration: TimeInterval = 0
    package var languagePointerDuration: TimeInterval = 0
    package var highlightQueryDataDuration: TimeInterval = 0
    package var highlightQueryCompileDuration: TimeInterval = 0
    package var codeMapQueryDataDuration: TimeInterval = 0
    package var codeMapQueryCompileDuration: TimeInterval = 0

    package var warmCacheLanguageCount = 0
    package var languageConfigCreateCount = 0
    package var languageConfigSuccessCount = 0
    package var languageConfigFailureCount = 0
    package var highlightQueryCompileSuccessCount = 0
    package var highlightQueryCompileFailureCount = 0
    package var warmCodeMapQueryLanguageCount = 0
    package var codeMapQueryPrecomputeSuccessCount = 0
    package var codeMapQueryPrecomputeFailureCount = 0
    package var codeMapQueryPrecomputeSkippedCount = 0
}

package struct CodeMapSyntaxPerfStats {
    package var languageLookupDuration: TimeInterval = 0
    package var oversizeGuardDuration: TimeInterval = 0
    package var parserCreateDuration: TimeInterval = 0
    package var setLanguageDuration: TimeInterval = 0
    package var parseDuration: TimeInterval = 0
    package var codeMapQueryLookupDuration: TimeInterval = 0
    package var queryExecuteDuration: TimeInterval = 0
    package var captureMaterializationDuration: TimeInterval = 0

    package var calls = 0
    package var unsupported = 0
    package var oversized = 0
    package var parseNilTree = 0
    package var parseNilRoot = 0
    package var parserCreates = 0
    package var queryExecutes = 0
    package var captures = 0
    package var codeMapQueryCacheHits = 0
    package var codeMapQueryCacheMisses = 0
}

package struct CodeMapPipelinePerfSnapshot: Equatable {
    package var snapshotBuildDuration: TimeInterval = 0
    package var requestBuildDuration: TimeInterval = 0
    package var contentLoadDuration: TimeInterval = 0
    package var actorRequestIngestDuration: TimeInterval = 0
    package var actorCachePrefetchDuration: TimeInterval = 0
    package var actorCacheCheckDuration: TimeInterval = 0
    package var actorQueueWaitDuration: TimeInterval = 0
    package var parseAndQueryDuration: TimeInterval = 0
    package var generatorDuration: TimeInterval = 0
    package var batchApplyDuration: TimeInterval = 0
    package var syntaxManagerPrimeDuration: TimeInterval = 0
    package var syntaxWarmCacheDuration: TimeInterval = 0
    package var syntaxWarmCodeMapQueriesDuration: TimeInterval = 0
    package var syntaxLanguageConfigCreateDuration: TimeInterval = 0
    package var syntaxLanguagePointerDuration: TimeInterval = 0
    package var syntaxHighlightQueryDataDuration: TimeInterval = 0
    package var syntaxHighlightQueryCompileDuration: TimeInterval = 0
    package var syntaxCodeMapQueryDataDuration: TimeInterval = 0
    package var syntaxCodeMapQueryCompileDuration: TimeInterval = 0
    package var syntaxLanguageLookupDuration: TimeInterval = 0
    package var syntaxOversizeGuardDuration: TimeInterval = 0
    package var syntaxParserCreateDuration: TimeInterval = 0
    package var syntaxSetLanguageDuration: TimeInterval = 0
    package var syntaxParseDuration: TimeInterval = 0
    package var syntaxCodeMapQueryLookupDuration: TimeInterval = 0
    package var syntaxQueryExecuteDuration: TimeInterval = 0
    package var syntaxCaptureMaterializationDuration: TimeInterval = 0
    package var generatorCaptureIndexDuration: TimeInterval = 0
    package var generatorSwiftContextDuration: TimeInterval = 0
    package var generatorTSContextDuration: TimeInterval = 0
    package var generatorCaptureLoopDuration: TimeInterval = 0
    package var generatorCaptureLoopLineAdvanceDuration: TimeInterval = 0
    package var generatorCaptureLoopSwiftStrategyDuration: TimeInterval = 0
    package var generatorCaptureLoopTSStrategyDuration: TimeInterval = 0
    package var generatorCaptureLoopInterfaceHeuristicDuration: TimeInterval = 0
    package var generatorCaptureLoopImportExportDuration: TimeInterval = 0
    package var generatorCaptureLoopTypeAliasDuration: TimeInterval = 0
    package var generatorCaptureLoopEnumMacroDuration: TimeInterval = 0
    package var generatorCaptureLoopFunctionDuration: TimeInterval = 0
    package var generatorCaptureLoopVariableDuration: TimeInterval = 0
    package var generatorCaptureLoopSkippedDuration: TimeInterval = 0
    package var generatorCaptureLoopUnclassifiedDuration: TimeInterval = 0
    package var generatorSwiftStrategyFunctionSignatureDuration: TimeInterval = 0
    package var generatorSwiftStrategyFunctionNameLookupDuration: TimeInterval = 0
    package var generatorSwiftStrategyParameterExtractionDuration: TimeInterval = 0
    package var generatorSwiftStrategyReturnTypeExtractionDuration: TimeInterval = 0
    package var generatorSwiftStrategyPropertyDeclarationDuration: TimeInterval = 0
    package var generatorSwiftStrategyPropertyTypeExtractionDuration: TimeInterval = 0
    package var generatorSwiftStrategyEnclosingTypeLookupDuration: TimeInterval = 0
    package var generatorSwiftStrategyModelInsertionDuration: TimeInterval = 0
    package var generatorSwiftStrategyContextOnlyDuration: TimeInterval = 0
    package var generatorFallbackFunctionDeclarationDuration: TimeInterval = 0
    package var generatorFallbackFunctionJSTSSignatureDuration: TimeInterval = 0
    package var generatorFallbackFunctionNameExtractionDuration: TimeInterval = 0
    package var generatorFallbackFunctionLTEParseDuration: TimeInterval = 0
    package var generatorFallbackFunctionTSFastPathDuration: TimeInterval = 0
    package var generatorFallbackFunctionReferencedTypesDuration: TimeInterval = 0
    package var generatorFallbackFunctionRoutingDuration: TimeInterval = 0
    package var generatorFallbackFunctionModelInsertionDuration: TimeInterval = 0
    package var generatorFallbackFunctionSkippedDuration: TimeInterval = 0
    package var generatorDeclarationExtractionDuration: TimeInterval = 0
    package var generatorJSTSSignatureDuration: TimeInterval = 0
    package var generatorLanguageTypeExtractorFunctionDuration: TimeInterval = 0
    package var generatorLanguageTypeExtractorVariableDuration: TimeInterval = 0
    package var generatorTypeCleanerDuration: TimeInterval = 0
    package var generatorTypeCleanerSwiftDuration: TimeInterval = 0
    package var generatorTypeCleanerTSDuration: TimeInterval = 0
    package var generatorTypeCleanerTSXDuration: TimeInterval = 0
    package var generatorTypeCleanerJSDuration: TimeInterval = 0
    package var generatorTypeCleanerOtherLanguageDuration: TimeInterval = 0
    package var generatorTypeCleanerPrecleanDuration: TimeInterval = 0
    package var generatorTypeCleanerTSLogicDuration: TimeInterval = 0
    package var generatorTypeCleanerNonTSLogicDuration: TimeInterval = 0
    package var generatorTypeCleanerTSObjectLiteralDuration: TimeInterval = 0
    package var generatorTypeCleanerFilterDuration: TimeInterval = 0
    package var generatorTypeCleanerDedupDuration: TimeInterval = 0
    package var generatorReferencedTypesFinalizeDuration: TimeInterval = 0
    package var generatorFileAPIInitDuration: TimeInterval = 0

    package var requestsBuilt = 0
    package var requestsEnqueued = 0
    package var cacheHits = 0
    package var cacheMisses = 0
    package var oversizedSkips = 0
    package var parseFailures = 0
    package var generatedAPIs = 0
    package var nilAPIs = 0
    package var codeMapQueryCacheHits = 0
    package var codeMapQueryCacheMisses = 0
    package var syntaxWarmCacheLanguageCount = 0
    package var syntaxLanguageConfigCreateCount = 0
    package var syntaxLanguageConfigSuccessCount = 0
    package var syntaxLanguageConfigFailureCount = 0
    package var syntaxHighlightQueryCompileSuccessCount = 0
    package var syntaxHighlightQueryCompileFailureCount = 0
    package var syntaxWarmCodeMapQueryLanguageCount = 0
    package var syntaxCodeMapQueryPrecomputeSuccessCount = 0
    package var syntaxCodeMapQueryPrecomputeFailureCount = 0
    package var syntaxCodeMapQueryPrecomputeSkippedCount = 0
    package var syntaxCodeMapCalls = 0
    package var syntaxUnsupportedExtensionCount = 0
    package var syntaxOversizedSkipCount = 0
    package var syntaxParseNilTreeCount = 0
    package var syntaxParseNilRootCount = 0
    package var syntaxParserCreateCount = 0
    package var syntaxQueryExecuteCount = 0
    package var syntaxCaptureCount = 0
    package var capturesProcessed = 0
    package var swiftStrategyHandled = 0
    package var tsStrategyHandled = 0
    package var fallbackHandled = 0
    package var generatorCaptureLoopLineAdvanceCount = 0
    package var generatorCaptureLoopSwiftStrategyCount = 0
    package var generatorCaptureLoopTSStrategyCount = 0
    package var generatorCaptureLoopInterfaceHeuristicCount = 0
    package var generatorCaptureLoopImportExportCount = 0
    package var generatorCaptureLoopTypeAliasCount = 0
    package var generatorCaptureLoopEnumMacroCount = 0
    package var generatorCaptureLoopFunctionCount = 0
    package var generatorCaptureLoopVariableCount = 0
    package var generatorCaptureLoopSkippedCount = 0
    package var generatorCaptureLoopUnclassifiedCount = 0
    package var generatorSwiftStrategyFunctionSignatureCount = 0
    package var generatorSwiftStrategyFunctionNameLookupCount = 0
    package var generatorSwiftStrategyParameterExtractionCount = 0
    package var generatorSwiftStrategyReturnTypeExtractionCount = 0
    package var generatorSwiftStrategyPropertyDeclarationCount = 0
    package var generatorSwiftStrategyPropertyTypeExtractionCount = 0
    package var generatorSwiftStrategyEnclosingTypeLookupCount = 0
    package var generatorSwiftStrategyModelInsertionCount = 0
    package var generatorSwiftStrategyContextOnlyCount = 0
    package var generatorSwiftStrategyHandledFunctionCount = 0
    package var generatorSwiftStrategyHandledPropertyCount = 0
    package var generatorFallbackFunctionDeclarationCount = 0
    package var generatorFallbackFunctionJSTSSignatureCount = 0
    package var generatorFallbackFunctionNameExtractionCount = 0
    package var generatorFallbackFunctionLTEParseCount = 0
    package var generatorFallbackFunctionTSFastPathCount = 0
    package var generatorFallbackFunctionReferencedTypesCount = 0
    package var generatorFallbackFunctionRoutingCount = 0
    package var generatorFallbackFunctionModelInsertionCount = 0
    package var generatorFallbackFunctionSkippedCount = 0
    package var generatorFallbackFunctionLightweightCount = 0
    package var generatorFallbackFunctionHeavyweightCount = 0
    package var generatorFallbackFunctionGlobalInsertCount = 0
    package var generatorFallbackFunctionMethodInsertCount = 0
    package var generatorFallbackFunctionInterfaceInsertCount = 0
    package var captureDeclarationCalls = 0
    package var jstsSignatureCallsFunctionLike = 0
    package var jstsSignatureCallsStatementLike = 0
    package var lteMatchAnyFunctionCalls = 0
    package var lteMatchAnyVariableCalls = 0
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

    package var resultBatchCount = 0
    package var maxResultBatchSize = 0
}

package final class CodeMapPipelinePerfStats: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = CodeMapPipelinePerfSnapshot()

    package var snapshot: CodeMapPipelinePerfSnapshot {
        lock.withLock { storage }
    }

    package func addDuration(_ keyPath: WritableKeyPath<CodeMapPipelinePerfSnapshot, TimeInterval>, _ duration: TimeInterval) {
        lock.withLock {
            storage[keyPath: keyPath] += duration
        }
    }

    package func increment(_ keyPath: WritableKeyPath<CodeMapPipelinePerfSnapshot, Int>, by amount: Int = 1) {
        guard amount != 0 else { return }
        lock.withLock {
            storage[keyPath: keyPath] += amount
        }
    }

    package func recordResultBatch(size: Int) {
        lock.withLock {
            storage.resultBatchCount += 1
            storage.maxResultBatchSize = max(storage.maxResultBatchSize, size)
        }
    }

    package func mergeSyntaxManagerStartupStats(_ stats: CodeMapSyntaxStartupPerfStats) {
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

    package func mergeSyntaxCodeMapStats(_ stats: CodeMapSyntaxPerfStats) {
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

    package func mergeGeneratorStats(_ stats: CodeMapPerfStats) {
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

package enum CodeMapPerfRuntime {
    package static let instrumentationEnvironmentKey = "REPOPROMPT_CODEMAP_PERF"
    package static let benchmarkEnvironmentKey = "REPOPROMPT_RUN_CODEMAP_BENCHMARKS"
    package static let benchmarkIterationsEnvironmentKey = "REPOPROMPT_CODEMAP_BENCHMARK_ITERATIONS"
    package static let benchmarkMarkerPath = "/tmp/repoprompt-run-codemap-benchmarks"

    #if DEBUG || CODEMAP_PERF
        static let isCompiledIn = true
    #else
        static let isCompiledIn = false
    #endif

    private static var benchmarkMarkerEnabled: Bool {
        guard isCompiledIn else { return false }
        return !isRunningInCI && FileManager.default.fileExists(atPath: benchmarkMarkerPath)
    }

    private static var benchmarkRequested: Bool {
        guard isCompiledIn else { return false }
        return environmentFlagEnabled(benchmarkEnvironmentKey)
            || CommandLine.arguments.contains("--run-codemap-benchmarks")
            || benchmarkMarkerEnabled
    }

    package static let isEnabled: Bool = {
        guard isCompiledIn else { return false }
        return environmentFlagEnabled(instrumentationEnvironmentKey) || benchmarkRequested
    }()

    package static let sharedPipelineStats: CodeMapPipelinePerfStats? = isEnabled ? CodeMapPipelinePerfStats() : nil

    package static func makeGeneratorOptions() -> CodeMapPerfOptions {
        isEnabled ? .countersOnly : .disabled
    }

    package static func makeGeneratorStats() -> CodeMapPerfStats? {
        isEnabled ? CodeMapPerfStats() : nil
    }

    @inline(__always)
    package static func activeOptions(_ options: CodeMapPerfOptions) -> CodeMapPerfOptions {
        #if DEBUG || CODEMAP_PERF
            return options
        #else
            return .disabled
        #endif
    }

    @inline(__always)
    package static func activeStats(_ stats: CodeMapPerfStats?) -> CodeMapPerfStats? {
        #if DEBUG || CODEMAP_PERF
            return stats
        #else
            return nil
        #endif
    }

    package static var shouldRunBenchmarks: Bool {
        benchmarkRequested
    }

    package static var isRunningInCI: Bool {
        ["CI", "GITHUB_ACTIONS", "BUILDKITE", "JENKINS_URL", "TEAMCITY_VERSION"].contains { key in
            ProcessInfo.processInfo.environment[key] != nil
        }
    }

    package static func environmentFlagEnabled(_ name: String) -> Bool {
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

    package static func currentTime() -> DispatchTime {
        DispatchTime.now()
    }

    package static func durationSince(_ start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
    }
}

package final class CodeMapPerfStats {
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
}
