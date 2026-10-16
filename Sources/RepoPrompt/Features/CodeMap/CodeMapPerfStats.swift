//
//  CodeMapPerfStats.swift
//  RepoPrompt
//
//  Lightweight counters for codemap performance analysis.
//  These are expected to be used on a single thread per file scan.
//

import Foundation
import RepoPromptCodeMapCore

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
    var codeMapQuerySuccessfulLookups = 0
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
    var generatorJSTSNormalizationASCIIFastPathDuration: TimeInterval = 0
    var generatorJSTSNormalizationLegacyFallbackDuration: TimeInterval = 0
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
    var generatorReferencedTypesSwiftRawTypeDedupDuration: TimeInterval = 0
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
    var codeMapQuerySuccessfulLookups = 0
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
    var jstsNormalizationASCIINoOpCount = 0
    var jstsNormalizationASCIIRewriteCount = 0
    var jstsNormalizationUnicodeFallbackCount = 0
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
    var referencedTypesSwiftDedupEligibleCount = 0
    var referencedTypesSwiftFirstSeenCount = 0
    var referencedTypesSwiftDuplicateSkipCount = 0
    var referencedTypesSwiftDuplicateSkippedUTF8ByteCount = 0
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
            storage.codeMapQuerySuccessfulLookups += stats.codeMapQuerySuccessfulLookups
        }
    }

    func mergeSyntaxCodeMapStats(_ stats: CodeMapPerformanceCollector) {
        mergeSyntaxCodeMapStats(
            CodeMapSyntaxPerfStats(
                languageLookupDuration: stats.syntaxLanguageLookupDuration,
                oversizeGuardDuration: stats.syntaxOversizeGuardDuration,
                parserCreateDuration: stats.syntaxParserCreateDuration,
                setLanguageDuration: stats.syntaxSetLanguageDuration,
                parseDuration: stats.syntaxParseDuration,
                codeMapQueryLookupDuration: stats.syntaxCodeMapQueryLookupDuration,
                queryExecuteDuration: stats.syntaxQueryExecuteDuration,
                captureMaterializationDuration: stats.syntaxCaptureMaterializationDuration,
                calls: stats.syntaxCalls,
                unsupported: stats.syntaxUnsupported,
                oversized: stats.syntaxOversized,
                parseNilTree: stats.syntaxParseNilTree,
                parseNilRoot: stats.syntaxParseNilRoot,
                parserCreates: stats.syntaxParserCreates,
                queryExecutes: stats.syntaxQueryExecutes,
                captures: stats.syntaxCaptures,
                codeMapQuerySuccessfulLookups: stats.syntaxCodeMapQuerySuccessfulLookups
            )
        )
    }

    func mergeGeneratorStats(_ stats: CodeMapPerformanceCollector) {
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
            storage.generatorJSTSNormalizationASCIIFastPathDuration += stats.jstsNormalizationASCIIFastPathDuration
            storage.generatorJSTSNormalizationLegacyFallbackDuration += stats.jstsNormalizationLegacyFallbackDuration
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
            storage.generatorReferencedTypesSwiftRawTypeDedupDuration += stats.referencedTypesSwiftRawTypeDedupDuration
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
            storage.jstsNormalizationASCIINoOpCount += stats.jstsNormalizationASCIINoOpCount
            storage.jstsNormalizationASCIIRewriteCount += stats.jstsNormalizationASCIIRewriteCount
            storage.jstsNormalizationUnicodeFallbackCount += stats.jstsNormalizationUnicodeFallbackCount
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
            storage.referencedTypesSwiftDedupEligibleCount += stats.referencedTypesSwiftDedupEligibleCount
            storage.referencedTypesSwiftFirstSeenCount += stats.referencedTypesSwiftFirstSeenCount
            storage.referencedTypesSwiftDuplicateSkipCount += stats.referencedTypesSwiftDuplicateSkipCount
            storage.referencedTypesSwiftDuplicateSkippedUTF8ByteCount += stats.referencedTypesSwiftDuplicateSkippedUTF8ByteCount
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
    static let benchmarkMarkerURL = WorkspaceContextFilesystemIdentity.identity.temporaryRootURL()
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

    static func makeGeneratorStats() -> CodeMapPerformanceCollector? {
        isEnabled ? CodeMapPerformanceCollector() : nil
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
    static func activeStats(_ stats: CodeMapPerformanceCollector?) -> CodeMapPerformanceCollector? {
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

#if DEBUG
    /// Stable, privacy-safe payload model for the attachable `codemap_graph_status` DEBUG MCP operation.
    struct CodemapGraphStatusStoreEventSnapshot: Equatable {
        let ordinal: UInt64
        let rootEpoch: WorkspaceCodemapRootEpoch
        let kind: String
        let launchPhase: String
        let uptimeNanoseconds: UInt64
    }

    struct CodemapGraphStatusStoreEventPage: Equatable {
        let firstOrdinal: UInt64
        let lastOrdinal: UInt64
        let nextOrdinal: UInt64?
        let events: [CodemapGraphStatusStoreEventSnapshot]
    }

    struct CodemapGraphStatusRetrySnapshot: Equatable {
        let attempt: Int
        let deadlineUptimeNanoseconds: UInt64
    }

    struct CodemapGraphStatusRetryExhaustionSnapshot: Equatable {
        let attempt: Int
        let uptimeNanoseconds: UInt64
    }

    struct CodemapGraphStatusLaunchSnapshot: Equatable {
        let id: UUID
        let phase: WorkspaceCodemapGraphIndexLaunchPhase
        let retryAttempt: Int
        let taskPresent: Bool
        let createdUptimeNanoseconds: UInt64
        let phaseEnteredUptimeNanoseconds: UInt64
        let retry: CodemapGraphStatusRetrySnapshot?
        let retryExhaustion: CodemapGraphStatusRetryExhaustionSnapshot?
    }

    struct CodemapGraphStatusAdmissionSnapshot: Equatable {
        let metrics: [String: UInt64]
        let queueWaitMilliseconds: [UInt64]
    }

    struct CodemapManifestWriterTaskSnapshot: Equatable {
        let writerID: UUID
        let namespaceDigest: String
        var rootEpoch: WorkspaceCodemapRootEpoch?
        var batchID: UUID?
        var origin: String?
        var phase: String
        let taskStartedUptimeNanoseconds: UInt64
        var batchStartedUptimeNanoseconds: UInt64?
        var phaseStartedUptimeNanoseconds: UInt64
    }

    struct CodemapManifestWriterQueueSnapshot: Equatable {
        let namespaceDigest: String
        let queuedItemCount: Int
        let deferredTailItemCount: Int
        let deferredHeadWaitingItemCount: Int
        let inFlightItemCount: Int
        let retryPending: Bool
    }

    struct CodemapManifestWriterActivitySnapshot: Equatable {
        let engineInstanceID: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let sampledUptimeNanoseconds: UInt64
        let liveTaskCount: Int
        let namespaceCount: Int
        let accountingComplete: Bool
        let quiescenceConfirmed: Bool
        let omittedLiveTaskCount: Int
        let tasks: [CodemapManifestWriterTaskSnapshot]
        let namespaces: [CodemapManifestWriterQueueSnapshot]
        let omittedNamespaceCount: Int
    }

    struct CodemapGraphStatusManifestSnapshot: Equatable {
        let failureCounts: [WorkspaceCodemapManifestFailureReason: UInt64]
        let lastFailure: WorkspaceCodemapManifestFailureDiagnostic?
        let measurements: WorkspaceCodemapManifestMeasurementSnapshot
        var writerActivity: CodemapManifestWriterActivitySnapshot?
    }

    struct CodemapGraphStatusRootSnapshot: Equatable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let catalogGeneration: UInt64
        let ingressGeneration: UInt64
        let rootKind: WorkspaceRootKind
        let eligibilityFlightPresent: Bool
        let launch: CodemapGraphStatusLaunchSnapshot?
        let job: WorkspaceCodemapBindingEngineGraphIndexRootAccounting?
        let admission: CodemapGraphStatusAdmissionSnapshot?
        let manifest: CodemapGraphStatusManifestSnapshot?
        let milestones: [CodemapGraphStatusStoreEventSnapshot]
        let engineEvents: WorkspaceCodemapGraphIndexDebugEventPage?
    }

    struct CodemapGraphStatusSnapshot: Equatable {
        let sampledUptimeNanoseconds: UInt64
        let roots: [CodemapGraphStatusRootSnapshot]
        let storeEvents: CodemapGraphStatusStoreEventPage?
        let graphIndexJobCount: Int
        let queuedGraphIndexBatchCount: Int
        let activeGraphIndexBatchCount: Int
        let drainingGraphIndexTaskCount: Int
    }

#endif

#if DEBUG
    enum CodemapFullLoadAggregateState: String, Equatable {
        case ready
        case pending
        case failed
        case superseded
        case incompleteDiagnostics = "incomplete_diagnostics"
    }

    enum CodemapFullLoadRootState: String, Equatable {
        case ready
        case terminalIneligible = "terminal_ineligible"
        case excluded
        case pending
        case failed
        case superseded
    }

    struct CodemapFullLoadRootIdentity: Equatable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let catalogGeneration: UInt64
        let ingressGeneration: UInt64
        let engineIdentity: ObjectIdentifier?
    }

    struct CodemapFullLoadMilestone: Equatable {
        let kind: String
        let uptimeNanoseconds: UInt64
    }

    struct CodemapFullLoadRootSnapshot: Equatable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let catalogGeneration: UInt64
        let ingressGeneration: UInt64
        let rootKind: String
        /// Real execution mode of the root's Code Map session, or nil before one exists.
        let sourceKind: WorkspaceCodemapRootSourceKind?
        let manifestMode: WorkspaceCodemapRootManifestMode?
        let state: CodemapFullLoadRootState
        let reason: String?
        let launchPhase: String?
        let graphIndexPhase: String?
        let supportedCandidateCount: UInt64?
        let processedCandidateCount: UInt64?
        let terminalCount: UInt64?
        let lastGraphChangeSequence: UInt64?
        let readyUptimeNanoseconds: UInt64?
        let metrics: [String: UInt64]
        let resources: [String: UInt64]
        let queueWaitMilliseconds: [UInt64]
        let milestones: [CodemapFullLoadMilestone]
    }

    struct CodemapFullLoadAggregateSnapshot: Equatable {
        let expectedWorkspaceID: UUID
        let state: CodemapFullLoadAggregateState
        let sampledUptimeNanoseconds: UInt64
        let visibleRootCount: Int
        let eligibleRootCount: Int
        let readyRootCount: Int
        let terminalIneligibleRootCount: Int
        let excludedRootCount: Int
        let pendingRootCount: Int
        let failedRootCount: Int
        let supersededRootCount: Int
        let cohort: String
        let roots: [CodemapFullLoadRootSnapshot]
        let metrics: [String: UInt64]
        let resources: [String: UInt64]
        let queueWaitMilliseconds: [UInt64]
    }

    struct CodemapFullLoadSampleStatistics: Equatable {
        let raw: [Double]
        let median: Double
        let nearestRankP95: Double
        let mean: Double
        let sampleStandardDeviation: Double
        let coefficientOfVariation: Double
        let medianAbsoluteDeviation: Double
        let relativeMedianAbsoluteDeviation: Double
        let tukeyOutlierIndices: [Int]
        let reliability: String
    }

    enum CodemapFullLoadDebugSupport {
        static func universeMatches(
            _ lhs: [CodemapFullLoadRootIdentity],
            _ rhs: [CodemapFullLoadRootIdentity]
        ) -> Bool {
            lhs == rhs
        }

        static func aggregateState(for roots: [CodemapFullLoadRootSnapshot]) -> CodemapFullLoadAggregateState {
            guard !roots.isEmpty else { return .incompleteDiagnostics }
            if roots.contains(where: { $0.state == .superseded }) {
                return .superseded
            }
            if roots.contains(where: { $0.state == .failed }) {
                return .failed
            }
            if roots.allSatisfy({ $0.state == .ready || $0.state == .terminalIneligible || $0.state == .excluded }) {
                return .ready
            }
            return .pending
        }

        static func cohort(metrics: [String: UInt64]) -> String {
            if (metrics["graph_index_artifact_builds_started"] ?? 0) > 0 ||
                (metrics["materializations"] ?? 0) > 0
            {
                return "cold-build"
            }
            if (metrics["classifications"] ?? 0) > 0 ||
                (metrics["locator_fast_paths"] ?? 0) > 0 ||
                (metrics["cas_fast_paths"] ?? 0) > 0
            {
                return "reuse-partial"
            }
            let candidates = metrics["graph_index_catalog_candidates"] ?? 0
            if candidates > 0, (metrics["graph_index_envelope_hits"] ?? 0) >= candidates {
                return "warm-envelope"
            }
            return "mixed"
        }

        static func adding(
            _ lhs: [String: UInt64],
            _ rhs: [String: UInt64]
        ) -> [String: UInt64] {
            rhs.reduce(into: lhs) { result, entry in
                let (sum, overflow) = (result[entry.key] ?? 0).addingReportingOverflow(entry.value)
                result[entry.key] = overflow ? .max : sum
            }
        }

        static func statistics(_ raw: [Double]) -> CodemapFullLoadSampleStatistics? {
            guard !raw.isEmpty else { return nil }
            let sorted = raw.sorted()
            let median = percentile(sorted, fraction: 0.5)
            let p95 = nearestRank(sorted, percentile: 0.95)
            let mean = raw.reduce(0, +) / Double(raw.count)
            let variance = raw.count > 1
                ? raw.reduce(0) { $0 + pow($1 - mean, 2) } / Double(raw.count - 1)
                : 0
            let standardDeviation = sqrt(variance)
            let deviations = raw.map { abs($0 - median) }.sorted()
            let mad = percentile(deviations, fraction: 0.5)
            let cv = mean == 0 ? 0 : standardDeviation / mean
            let relativeMAD = median == 0 ? 0 : mad / median
            var outliers: [Int] = []
            if raw.count >= 4 {
                let q1 = percentile(sorted, fraction: 0.25)
                let q3 = percentile(sorted, fraction: 0.75)
                let iqr = q3 - q1
                let lower = q1 - 1.5 * iqr
                let upper = q3 + 1.5 * iqr
                outliers = raw.indices.filter { raw[$0] < lower || raw[$0] > upper }
            }
            let reliability = cv <= 0.10 ? "high" : (cv <= 0.20 ? "moderate" : "low")
            return CodemapFullLoadSampleStatistics(
                raw: raw,
                median: median,
                nearestRankP95: p95,
                mean: mean,
                sampleStandardDeviation: standardDeviation,
                coefficientOfVariation: cv,
                medianAbsoluteDeviation: mad,
                relativeMedianAbsoluteDeviation: relativeMAD,
                tukeyOutlierIndices: outliers,
                reliability: reliability
            )
        }

        private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
            guard sorted.count > 1 else { return sorted[0] }
            let position = fraction * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = Int(position.rounded(.up))
            guard lower != upper else { return sorted[lower] }
            let weight = position - Double(lower)
            return sorted[lower] * (1 - weight) + sorted[upper] * weight
        }

        private static func nearestRank(_ sorted: [Double], percentile: Double) -> Double {
            let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
            return sorted[min(rank - 1, sorted.count - 1)]
        }

        static func graphIndexPhaseName(_ phase: WorkspaceCodemapGraphIndexPhase) -> String {
            switch phase {
            case .scheduled: "scheduled"
            case .waitingForAdmission: "waiting_for_admission"
            case .readingCatalogPage: "reading_catalog_page"
            case .loadingEnvelopes: "loading_envelopes"
            case .classifyingBatch: "classifying_batch"
            case .resolvingArtifacts: "resolving_artifacts"
            case .stagingManifestCache: "staging_manifest_cache"
            case .publishingGraphChanges: "publishing_graph_changes"
            case .checkpointed: "checkpointed"
            case .persistingManifestCache: "persisting_manifest_cache"
            case .suspendedBusy: "suspended_busy"
            case .budgetLimited: "budget_limited"
            case .complete: "complete"
            case .cancelled: "cancelled"
            case .superseded: "superseded"
            }
        }

        static func launchPhaseName(_ phase: WorkspaceCodemapGraphIndexLaunchPhase) -> String {
            switch phase {
            case .notScheduled: "not_scheduled"
            case .eligibilityQueued: "eligibility_queued"
            case .setupJoining: "setup_joining"
            case .engineScheduling: "engine_scheduling"
            case .handedOff: "handed_off"
            case .terminalUnavailable: "terminal_unavailable"
            case .transientRetry: "transient_retry"
            case .retryExhausted: "retry_exhausted"
            case .cancelled: "cancelled"
            case .superseded: "superseded"
            }
        }

        static func rootKindName(_ kind: WorkspaceRootKind) -> String {
            switch kind {
            case .primaryWorkspace: "primary_workspace"
            case .workspaceGitData: "workspace_git_data"
            case .supplementalSystem: "supplemental_system"
            case .sessionWorktree: "session_worktree"
            }
        }

        static func metrics(_ accounting: WorkspaceCodemapBindingEngineAccounting) -> [String: UInt64] {
            let counters = accounting.counters
            return [
                "classifications": counters.classifications,
                "locator_fast_paths": counters.locatorFastPaths,
                "cas_fast_paths": counters.casFastPaths,
                "materializations": counters.materializations,
                "materialized_bytes": counters.materializedBytes,
                "validated_worktree_reads": counters.validatedWorktreeReads,
                "validated_worktree_bytes": counters.validatedWorktreeBytes,
                "graph_index_runs_scheduled": counters.graphIndexRunsScheduled,
                "graph_index_runs_started": counters.graphIndexRunsStarted,
                "graph_index_envelope_hits": counters.graphIndexEnvelopeHits,
                "graph_index_envelope_stale": counters.graphIndexEnvelopeStale,
                "graph_index_envelope_invalid": counters.graphIndexEnvelopeInvalid,
                "graph_index_locator_misses": counters.graphIndexLocatorMisses,
                "graph_index_locator_corruptions": counters.graphIndexLocatorCorruptions,
                "graph_index_cas_misses": counters.graphIndexCASMisses,
                "graph_index_artifact_builds_joined": counters.graphIndexArtifactBuildsJoined,
                "graph_index_artifact_builds_started": counters.graphIndexArtifactBuildsStarted,
                "graph_index_artifact_builds_completed": counters.graphIndexArtifactBuildsCompleted,
                "graph_index_catalog_pages": counters.graphIndexCatalogPages,
                "graph_index_catalog_candidates": counters.graphIndexCatalogCandidates,
                "graph_index_catalog_path_bytes": counters.graphIndexCatalogPathBytes,
                "graph_index_changes_published": counters.graphIndexChangesPublished,
                "graph_index_change_bytes": counters.graphIndexChangeBytes,
                "graph_index_batch_nanoseconds": counters.graphIndexBatchNanoseconds,
                "graph_index_published_slots": counters.graphIndexPublishedSlots,
                "graph_index_publish_nanoseconds": counters.graphIndexPublishNanoseconds,
                "graph_index_retries": counters.graphIndexRetries,
                "graph_index_budget_rejections": counters.graphIndexBudgetRejections,
                "manifest_writes": counters.manifestWrites,
                "manifest_failures": counters.manifestFailures,
                "failures": counters.failures
            ]
        }

        static func resources(_ accounting: WorkspaceCodemapBindingEngineAccounting) -> [String: UInt64] {
            let resources = accounting.graphIndexResources
            return [
                "retained_path_bytes": resources.retainedPathBytes,
                "retained_source_bytes": resources.retainedSourceBytes,
                "retained_graph_index_bytes": resources.retainedGraphIndexBytes,
                "staged_graph_bytes": resources.stagedGraphBytes,
                "resident_graph_bytes": resources.residentGraphBytes,
                "queued_manifest_mutation_bytes": resources.queuedManifestMutationBytes
            ]
        }

        static func privacySafeRootPayload(_ root: CodemapFullLoadRootSnapshot) -> [String: Any] {
            [
                "root_id": root.rootEpoch.rootID.uuidString,
                "root_lifetime_id": root.rootEpoch.rootLifetimeID.uuidString,
                "catalog_generation": root.catalogGeneration,
                "ingress_generation": root.ingressGeneration,
                "root_kind": root.rootKind,
                "source_kind": root.sourceKind?.rawValue ?? NSNull(),
                "manifest_mode": root.manifestMode?.rawValue ?? NSNull(),
                "state": root.state.rawValue,
                "reason": root.reason ?? NSNull(),
                "launch_phase": root.launchPhase ?? NSNull(),
                "graph_index_phase": root.graphIndexPhase ?? NSNull(),
                "supported_candidate_count": root.supportedCandidateCount ?? NSNull(),
                "processed_candidate_count": root.processedCandidateCount ?? NSNull(),
                "terminal_count": root.terminalCount ?? NSNull(),
                "last_graph_change_sequence": root.lastGraphChangeSequence ?? NSNull(),
                "ready_uptime_ns": root.readyUptimeNanoseconds ?? NSNull(),
                "metrics": root.metrics,
                "resources": root.resources,
                "queue_wait_ms": root.queueWaitMilliseconds,
                "milestones": root.milestones.map {
                    [
                        "kind": $0.kind,
                        "uptime_ns": $0.uptimeNanoseconds
                    ]
                }
            ]
        }
    }
#endif
