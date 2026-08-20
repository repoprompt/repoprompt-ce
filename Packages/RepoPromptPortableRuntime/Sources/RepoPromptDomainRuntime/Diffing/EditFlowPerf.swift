import Foundation
import RepoPromptShared
#if DEBUG
    import Synchronization
#endif
#if (DEBUG || EDIT_FLOW_PERF) && canImport(os)
    import os
#endif

/// Lightweight, gated instrumentation for hot-path diagnostics.
///
/// Keep this utility safe for broad use:
/// - disabled by default and cheap on the fast path;
/// - stage names are static;
/// - dimensions are coarse counts/status labels only;
/// - never pass raw paths, patterns, replacement text, file content, or diffs.
public enum EditFlowPerf {
    public struct LifecycleCorrelation: Sendable {
        public let id: UUID
        public let captureEpoch: UInt64?
        public let requestIdentity: MCPRequestTimelineIdentity?
    }

    @TaskLocal
    public static var currentLifecycleCorrelation: LifecycleCorrelation?
    @TaskLocal
    public static var currentFileSystemPublicationCorrelation: LifecycleCorrelation?

    #if (DEBUG || EDIT_FLOW_PERF) && canImport(os)
        public struct IntervalState {
            let signpostState: OSSignpostIntervalState?
            #if DEBUG
                let debugCaptureEpoch: UInt64?
                let debugCaptureStartNanoseconds: UInt64?
                let debugCaptureStageName: String
                let debugCaptureDimensions: String
            #endif
        }
    #else
        public struct IntervalState {}
    #endif

    public struct Dimensions {
        var toolName: String?
        var runPurpose: String?
        var status: String?
        var outcome: String?
        var fileBytes: Int?
        var lineCount: Int?
        var diffLines: Int?
        var editCount: Int?
        var matchCount: Int?
        var appliedCount: Int?
        var chunkCount: Int?
        var taskCount: Int?
        var workerCount: Int?
        var activeCount: Int?
        var storeCapacity: Int?
        var globalCapacity: Int?
        var storeActiveCount: Int?
        var globalActiveCount: Int?
        var storeQueueDepth: Int?
        var globalQueueDepth: Int?
        var admittedFileCount: Int?
        var scannedFileCount: Int?
        var matchedFileCount: Int?
        var contentMatchCount: Int?
        var pathMatchCount: Int?
        var errorCount: Int?
        var isError: Bool?
        var isForced: Bool?
        var isAgentMode: Bool?
        var includesToolCardDiff: Bool?
        var limitHit: Bool?
        var usesWorktreeProjection: Bool?
        var searchMode: String?
        var workloadClass: String?
        var admissionClass: String?
        var queueAgeBucket: String?
        var contentSource: String?
        var freshnessPolicy: String?
        var scanKind: String?
        var fileCount: Int?
        var batchSize: Int?
        var maxResults: Int?
        var cacheHit: Bool?
        var isRegex: Bool?
        var countOnly: Bool?
        var caseInsensitive: Bool?
        var wholeWord: Bool?
        var contextLines: Int?
        var sourceItemCount: Int?
        var sanitizedActivityCount: Int?
        var retainedPayloadCount: Int?
        var retainedPayloadBytes: Int?
        var jsonParseAttemptCount: Int?
        var jsonParseCacheHitCount: Int?
        var jsonParseCacheMissCount: Int?
        var jsonParseSuccessCount: Int?
        var jsonParseFailureCount: Int?
        var jsonParseByteCount: Int?
        var toolExecutionCacheHitCount: Int?
        var toolExecutionCacheMissCount: Int?
        var bashMetadataCacheHitCount: Int?
        var bashMetadataCacheMissCount: Int?
        var regexCaptureCallCount: Int?
        var inputBytes: Int?
        var contentItemCount: Int?
        var changeCount: Int?
        var scopeCount: Int?
        var warningCount: Int?
        var fileAction: String?
        var rootCount: Int?
        var folderCount: Int?
        var pendingRootCount: Int?
        var pendingRawEventCount: Int?
        var rootToken: String?
        var queueDepth: Int?
        var waiterCount: Int?
        var ingressSequence: UInt64?
        var barrierSequence: UInt64?
        var observerToken: String?
        var observerType: String?
        var serialPosition: Int?
        var queueDelayMicroseconds: Int?
        var durationMicroseconds: Int?
        var correlationPath: String?
        var scannedItemCount: Int?
        var resultBytes: Int?
        var windowID: Int?
        var runID: String?
        var ownerResource: String?
        var providerActive: Bool?
        var networkScopeActive: Bool?
        var permitActive: Bool?
        var publicationPending: Bool?
        var terminalBarrier: Bool?

        public init(
            toolName: String? = nil,
            runPurpose: String? = nil,
            status: String? = nil,
            outcome: String? = nil,
            fileBytes: Int? = nil,
            lineCount: Int? = nil,
            diffLines: Int? = nil,
            editCount: Int? = nil,
            matchCount: Int? = nil,
            appliedCount: Int? = nil,
            chunkCount: Int? = nil,
            taskCount: Int? = nil,
            workerCount: Int? = nil,
            activeCount: Int? = nil,
            storeCapacity: Int? = nil,
            globalCapacity: Int? = nil,
            storeActiveCount: Int? = nil,
            globalActiveCount: Int? = nil,
            storeQueueDepth: Int? = nil,
            globalQueueDepth: Int? = nil,
            admittedFileCount: Int? = nil,
            scannedFileCount: Int? = nil,
            matchedFileCount: Int? = nil,
            contentMatchCount: Int? = nil,
            pathMatchCount: Int? = nil,
            errorCount: Int? = nil,
            isError: Bool? = nil,
            isForced: Bool? = nil,
            isAgentMode: Bool? = nil,
            includesToolCardDiff: Bool? = nil,
            limitHit: Bool? = nil,
            usesWorktreeProjection: Bool? = nil,
            searchMode: String? = nil,
            workloadClass: String? = nil,
            admissionClass: String? = nil,
            queueAgeBucket: String? = nil,
            contentSource: String? = nil,
            freshnessPolicy: String? = nil,
            scanKind: String? = nil,
            fileCount: Int? = nil,
            batchSize: Int? = nil,
            maxResults: Int? = nil,
            cacheHit: Bool? = nil,
            isRegex: Bool? = nil,
            countOnly: Bool? = nil,
            caseInsensitive: Bool? = nil,
            wholeWord: Bool? = nil,
            contextLines: Int? = nil,
            sourceItemCount: Int? = nil,
            sanitizedActivityCount: Int? = nil,
            retainedPayloadCount: Int? = nil,
            retainedPayloadBytes: Int? = nil,
            jsonParseAttemptCount: Int? = nil,
            jsonParseCacheHitCount: Int? = nil,
            jsonParseCacheMissCount: Int? = nil,
            jsonParseSuccessCount: Int? = nil,
            jsonParseFailureCount: Int? = nil,
            jsonParseByteCount: Int? = nil,
            toolExecutionCacheHitCount: Int? = nil,
            toolExecutionCacheMissCount: Int? = nil,
            bashMetadataCacheHitCount: Int? = nil,
            bashMetadataCacheMissCount: Int? = nil,
            regexCaptureCallCount: Int? = nil,
            inputBytes: Int? = nil,
            contentItemCount: Int? = nil,
            changeCount: Int? = nil,
            scopeCount: Int? = nil,
            warningCount: Int? = nil,
            fileAction: String? = nil,
            rootCount: Int? = nil,
            folderCount: Int? = nil,
            pendingRootCount: Int? = nil,
            pendingRawEventCount: Int? = nil,
            rootToken: String? = nil,
            queueDepth: Int? = nil,
            waiterCount: Int? = nil,
            ingressSequence: UInt64? = nil,
            barrierSequence: UInt64? = nil,
            observerToken: String? = nil,
            observerType: String? = nil,
            serialPosition: Int? = nil,
            queueDelayMicroseconds: Int? = nil,
            durationMicroseconds: Int? = nil,
            correlationPath: String? = nil,
            scannedItemCount: Int? = nil,
            resultBytes: Int? = nil,
            windowID: Int? = nil,
            runID: String? = nil,
            ownerResource: String? = nil,
            providerActive: Bool? = nil,
            networkScopeActive: Bool? = nil,
            permitActive: Bool? = nil,
            publicationPending: Bool? = nil,
            terminalBarrier: Bool? = nil
        ) {
            self.toolName = Self.sanitizedLabel(toolName)
            self.runPurpose = Self.sanitizedLabel(runPurpose)
            self.status = Self.sanitizedLabel(status)
            self.outcome = Self.sanitizedLabel(outcome)
            self.fileBytes = Self.nonNegative(fileBytes)
            self.lineCount = Self.nonNegative(lineCount)
            self.diffLines = Self.nonNegative(diffLines)
            self.editCount = Self.nonNegative(editCount)
            self.matchCount = Self.nonNegative(matchCount)
            self.appliedCount = Self.nonNegative(appliedCount)
            self.chunkCount = Self.nonNegative(chunkCount)
            self.taskCount = Self.nonNegative(taskCount)
            self.workerCount = Self.nonNegative(workerCount)
            self.activeCount = Self.nonNegative(activeCount)
            self.storeCapacity = Self.nonNegative(storeCapacity)
            self.globalCapacity = Self.nonNegative(globalCapacity)
            self.storeActiveCount = Self.nonNegative(storeActiveCount)
            self.globalActiveCount = Self.nonNegative(globalActiveCount)
            self.storeQueueDepth = Self.nonNegative(storeQueueDepth)
            self.globalQueueDepth = Self.nonNegative(globalQueueDepth)
            self.admittedFileCount = Self.nonNegative(admittedFileCount)
            self.scannedFileCount = Self.nonNegative(scannedFileCount)
            self.matchedFileCount = Self.nonNegative(matchedFileCount)
            self.contentMatchCount = Self.nonNegative(contentMatchCount)
            self.pathMatchCount = Self.nonNegative(pathMatchCount)
            self.errorCount = Self.nonNegative(errorCount)
            self.isError = isError
            self.isForced = isForced
            self.isAgentMode = isAgentMode
            self.includesToolCardDiff = includesToolCardDiff
            self.limitHit = limitHit
            self.usesWorktreeProjection = usesWorktreeProjection
            self.searchMode = Self.sanitizedLabel(searchMode)
            self.workloadClass = Self.sanitizedLabel(workloadClass)
            self.admissionClass = Self.sanitizedLabel(admissionClass)
            self.queueAgeBucket = Self.sanitizedLabel(queueAgeBucket)
            self.contentSource = Self.sanitizedLabel(contentSource)
            self.freshnessPolicy = Self.sanitizedLabel(freshnessPolicy)
            self.scanKind = Self.sanitizedLabel(scanKind)
            self.fileCount = Self.nonNegative(fileCount)
            self.batchSize = Self.nonNegative(batchSize)
            self.maxResults = Self.nonNegative(maxResults)
            self.cacheHit = cacheHit
            self.isRegex = isRegex
            self.countOnly = countOnly
            self.caseInsensitive = caseInsensitive
            self.wholeWord = wholeWord
            self.contextLines = Self.nonNegative(contextLines)
            self.sourceItemCount = Self.nonNegative(sourceItemCount)
            self.sanitizedActivityCount = Self.nonNegative(sanitizedActivityCount)
            self.retainedPayloadCount = Self.nonNegative(retainedPayloadCount)
            self.retainedPayloadBytes = Self.nonNegative(retainedPayloadBytes)
            self.jsonParseAttemptCount = Self.nonNegative(jsonParseAttemptCount)
            self.jsonParseCacheHitCount = Self.nonNegative(jsonParseCacheHitCount)
            self.jsonParseCacheMissCount = Self.nonNegative(jsonParseCacheMissCount)
            self.jsonParseSuccessCount = Self.nonNegative(jsonParseSuccessCount)
            self.jsonParseFailureCount = Self.nonNegative(jsonParseFailureCount)
            self.jsonParseByteCount = Self.nonNegative(jsonParseByteCount)
            self.toolExecutionCacheHitCount = Self.nonNegative(toolExecutionCacheHitCount)
            self.toolExecutionCacheMissCount = Self.nonNegative(toolExecutionCacheMissCount)
            self.bashMetadataCacheHitCount = Self.nonNegative(bashMetadataCacheHitCount)
            self.bashMetadataCacheMissCount = Self.nonNegative(bashMetadataCacheMissCount)
            self.regexCaptureCallCount = Self.nonNegative(regexCaptureCallCount)
            self.inputBytes = Self.nonNegative(inputBytes)
            self.contentItemCount = Self.nonNegative(contentItemCount)
            self.changeCount = Self.nonNegative(changeCount)
            self.scopeCount = Self.nonNegative(scopeCount)
            self.warningCount = Self.nonNegative(warningCount)
            self.fileAction = Self.sanitizedLabel(fileAction)
            self.rootCount = Self.nonNegative(rootCount)
            self.folderCount = Self.nonNegative(folderCount)
            self.pendingRootCount = Self.nonNegative(pendingRootCount)
            self.pendingRawEventCount = Self.nonNegative(pendingRawEventCount)
            self.rootToken = Self.sanitizedLabel(rootToken)
            self.queueDepth = Self.nonNegative(queueDepth)
            self.waiterCount = Self.nonNegative(waiterCount)
            self.ingressSequence = ingressSequence
            self.barrierSequence = barrierSequence
            self.observerToken = Self.sanitizedLabel(observerToken)
            self.observerType = Self.sanitizedLabel(observerType)
            self.serialPosition = Self.nonNegative(serialPosition)
            self.queueDelayMicroseconds = Self.nonNegative(queueDelayMicroseconds)
            self.durationMicroseconds = Self.nonNegative(durationMicroseconds)
            self.correlationPath = Self.sanitizedLabel(correlationPath)
            self.scannedItemCount = Self.nonNegative(scannedItemCount)
            self.resultBytes = Self.nonNegative(resultBytes)
            self.windowID = Self.nonNegative(windowID)
            self.runID = Self.sanitizedLabel(runID)
            self.ownerResource = Self.sanitizedLabel(ownerResource)
            self.providerActive = providerActive
            self.networkScopeActive = networkScopeActive
            self.permitActive = permitActive
            self.publicationPending = publicationPending
            self.terminalBarrier = terminalBarrier
        }

        fileprivate var logDescription: String {
            var parts: [String] = []
            append("tool", toolName, to: &parts)
            append("purpose", runPurpose, to: &parts)
            append("status", status, to: &parts)
            append("outcome", outcome, to: &parts)
            append("fileBytes", fileBytes, to: &parts)
            append("lineCount", lineCount, to: &parts)
            append("diffLines", diffLines, to: &parts)
            append("editCount", editCount, to: &parts)
            append("matchCount", matchCount, to: &parts)
            append("appliedCount", appliedCount, to: &parts)
            append("chunkCount", chunkCount, to: &parts)
            append("taskCount", taskCount, to: &parts)
            append("workerCount", workerCount, to: &parts)
            append("activeCount", activeCount, to: &parts)
            append("storeCapacity", storeCapacity, to: &parts)
            append("globalCapacity", globalCapacity, to: &parts)
            append("storeActiveCount", storeActiveCount, to: &parts)
            append("globalActiveCount", globalActiveCount, to: &parts)
            append("storeQueueDepth", storeQueueDepth, to: &parts)
            append("globalQueueDepth", globalQueueDepth, to: &parts)
            append("admittedFileCount", admittedFileCount, to: &parts)
            append("scannedFileCount", scannedFileCount, to: &parts)
            append("matchedFileCount", matchedFileCount, to: &parts)
            append("contentMatchCount", contentMatchCount, to: &parts)
            append("pathMatchCount", pathMatchCount, to: &parts)
            append("errorCount", errorCount, to: &parts)
            append("isError", isError, to: &parts)
            append("isForced", isForced, to: &parts)
            append("isAgentMode", isAgentMode, to: &parts)
            append("includesToolCardDiff", includesToolCardDiff, to: &parts)
            append("limitHit", limitHit, to: &parts)
            append("usesWorktreeProjection", usesWorktreeProjection, to: &parts)
            append("searchMode", searchMode, to: &parts)
            append("workloadClass", workloadClass, to: &parts)
            append("admissionClass", admissionClass, to: &parts)
            append("queueAgeBucket", queueAgeBucket, to: &parts)
            append("contentSource", contentSource, to: &parts)
            append("freshnessPolicy", freshnessPolicy, to: &parts)
            append("scanKind", scanKind, to: &parts)
            append("fileCount", fileCount, to: &parts)
            append("batchSize", batchSize, to: &parts)
            append("maxResults", maxResults, to: &parts)
            append("cacheHit", cacheHit, to: &parts)
            append("isRegex", isRegex, to: &parts)
            append("countOnly", countOnly, to: &parts)
            append("caseInsensitive", caseInsensitive, to: &parts)
            append("wholeWord", wholeWord, to: &parts)
            append("contextLines", contextLines, to: &parts)
            append("sourceItemCount", sourceItemCount, to: &parts)
            append("sanitizedActivityCount", sanitizedActivityCount, to: &parts)
            append("retainedPayloadCount", retainedPayloadCount, to: &parts)
            append("retainedPayloadBytes", retainedPayloadBytes, to: &parts)
            append("jsonParseAttemptCount", jsonParseAttemptCount, to: &parts)
            append("jsonParseCacheHitCount", jsonParseCacheHitCount, to: &parts)
            append("jsonParseCacheMissCount", jsonParseCacheMissCount, to: &parts)
            append("jsonParseSuccessCount", jsonParseSuccessCount, to: &parts)
            append("jsonParseFailureCount", jsonParseFailureCount, to: &parts)
            append("jsonParseByteCount", jsonParseByteCount, to: &parts)
            append("toolExecutionCacheHitCount", toolExecutionCacheHitCount, to: &parts)
            append("toolExecutionCacheMissCount", toolExecutionCacheMissCount, to: &parts)
            append("bashMetadataCacheHitCount", bashMetadataCacheHitCount, to: &parts)
            append("bashMetadataCacheMissCount", bashMetadataCacheMissCount, to: &parts)
            append("regexCaptureCallCount", regexCaptureCallCount, to: &parts)
            append("inputBytes", inputBytes, to: &parts)
            append("contentItemCount", contentItemCount, to: &parts)
            append("changeCount", changeCount, to: &parts)
            append("scopeCount", scopeCount, to: &parts)
            append("warningCount", warningCount, to: &parts)
            append("fileAction", fileAction, to: &parts)
            append("rootCount", rootCount, to: &parts)
            append("folderCount", folderCount, to: &parts)
            append("pendingRootCount", pendingRootCount, to: &parts)
            append("pendingRawEventCount", pendingRawEventCount, to: &parts)
            append("rootToken", rootToken, to: &parts)
            append("queueDepth", queueDepth, to: &parts)
            append("waiterCount", waiterCount, to: &parts)
            append("ingressSequence", ingressSequence, to: &parts)
            append("barrierSequence", barrierSequence, to: &parts)
            append("observerToken", observerToken, to: &parts)
            append("observerType", observerType, to: &parts)
            append("serialPosition", serialPosition, to: &parts)
            append("queueDelayUs", queueDelayMicroseconds, to: &parts)
            append("durationUs", durationMicroseconds, to: &parts)
            append("correlationPath", correlationPath, to: &parts)
            append("scannedItemCount", scannedItemCount, to: &parts)
            append("resultBytes", resultBytes, to: &parts)
            append("windowID", windowID, to: &parts)
            append("runID", runID, to: &parts)
            append("ownerResource", ownerResource, to: &parts)
            append("providerActive", providerActive, to: &parts)
            append("networkScopeActive", networkScopeActive, to: &parts)
            append("permitActive", permitActive, to: &parts)
            append("publicationPending", publicationPending, to: &parts)
            append("terminalBarrier", terminalBarrier, to: &parts)
            return parts.joined(separator: " ")
        }

        fileprivate var isEmpty: Bool {
            logDescription.isEmpty
        }

        private static func nonNegative(_ value: Int?) -> Int? {
            value.map { max(0, $0) }
        }

        private static func sanitizedLabel(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let replacement = UnicodeScalar("_")
            let scalars = trimmed.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? scalar : replacement
            }
            return String(String.UnicodeScalarView(scalars.prefix(64)))
        }

        private func append(_ key: String, _ value: String?, to parts: inout [String]) {
            guard let value else { return }
            parts.append("\(key)=\(value)")
        }

        private func append(_ key: String, _ value: Int?, to parts: inout [String]) {
            guard let value else { return }
            parts.append("\(key)=\(value)")
        }

        private func append(_ key: String, _ value: UInt64?, to parts: inout [String]) {
            guard let value else { return }
            parts.append("\(key)=\(value)")
        }

        private func append(_ key: String, _ value: Bool?, to parts: inout [String]) {
            guard let value else { return }
            parts.append("\(key)=\(value ? "true" : "false")")
        }
    }

    public enum Stage {
        public enum MCPToolCall {
            public static let total: StaticString = "EditFlow.MCPToolCall.Total"
            public static let normalizeArgs: StaticString = "EditFlow.MCPToolCall.NormalizeArgs"
            public static let logicalContextResolution: StaticString = "EditFlow.MCPToolCall.LogicalContextResolution"
            public static let policyGating: StaticString = "EditFlow.MCPToolCall.PolicyGating"
            public static let effectivePolicySnapshot: StaticString = "EditFlow.MCPToolCall.EffectivePolicySnapshot"
            public static let routingSnapshot: StaticString = "EditFlow.MCPToolCall.RoutingSnapshot"
            public static let preLimiterEnvelope: StaticString = "EditFlow.MCPToolCall.PreLimiterEnvelope"
            public static let limiterResolution: StaticString = "EditFlow.MCPToolCall.LimiterResolution"
            public static let limiterEnvelope: StaticString = "EditFlow.MCPToolCall.LimiterEnvelope"
            public static let limiterWait: StaticString = "EditFlow.MCPToolCall.LimiterWait"
            public static let permitBodyEnvelope: StaticString = "EditFlow.MCPToolCall.PermitBodyEnvelope"
            public static let permitPreDispatchEnvelope: StaticString = "EditFlow.MCPToolCall.PermitPreDispatchEnvelope"
            public static let enabledStateSnapshot: StaticString = "EditFlow.MCPToolCall.EnabledStateSnapshot"
            public static let windowRunResolution: StaticString = "EditFlow.MCPToolCall.WindowRunResolution"
            public static let observerCallbacks: StaticString = "EditFlow.MCPToolCall.ObserverCallbacks"
            public static let ownershipPurposeResolution: StaticString = "EditFlow.MCPToolCall.OwnershipPurposeResolution"
            public static let toolCallRecording: StaticString = "EditFlow.MCPToolCall.ToolCallRecording"
            public static let runScopedTabRebindFallback: StaticString = "EditFlow.MCPToolCall.RunScopedTabRebindFallback"
            public static let presentationContextResolution: StaticString = "EditFlow.MCPToolCall.PresentationContextResolution"
            public static let serviceToolLookup: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup"
            public static let serviceToolLookupServiceToolsAwait: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.ServiceToolsAwait"
            public static let serviceToolLookupToolDefinitionScan: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.ToolDefinitionScan"
            public static let serviceToolLookupPublicWindowIDInjection: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.PublicWindowIDInjection"
            public static let serviceToolLookupAppSettingsToolsBuild: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.AppSettingsToolsBuild"
            public static let serviceToolLookupWindowRoutingToolsCacheActorBody: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.WindowRoutingToolsCacheActorBody"
            public static let serviceToolLookupWindowCatalogToolsActorBodyTotal: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsActorBodyTotal"
            public static let serviceToolLookupWindowCatalogToolsMaterialization: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsMaterialization"
            public static let domainHostQueueWait: StaticString = "EditFlow.MCPToolCall.DomainHost.QueueWait"
            public static let domainHostExecution: StaticString = "EditFlow.MCPToolCall.DomainHost.Execution"
            public static let dispatch: StaticString = "EditFlow.MCPToolCall.Dispatch"
            public static let resolvedProviderDispatch: StaticString = "EditFlow.MCPToolCall.ResolvedProviderDispatch"
            public static let handlerResultHandoff: StaticString = "EditFlow.MCPToolCall.HandlerResultHandoff"
            public static let permitPostDispatchEnvelope: StaticString = "EditFlow.MCPToolCall.PermitPostDispatchEnvelope"
            public static let completionObservers: StaticString = "EditFlow.MCPToolCall.CompletionObservers"
            public static let completionObserverResultEncoding: StaticString = "EditFlow.MCPToolCall.CompletionObserverResultEncoding"
            public static let completionObserverCallbacks: StaticString = "EditFlow.MCPToolCall.CompletionObserverCallbacks"
            public static let preToolFilesystemFlush: StaticString = "EditFlow.MCPToolCall.PreToolFilesystemFlush"
            public static let runToolSetup: StaticString = "EditFlow.MCPToolCall.RunToolSetup"
            public static let runToolRegistration: StaticString = "EditFlow.MCPToolCall.RunToolRegistration"
            public static let providerExecution: StaticString = "EditFlow.MCPToolCall.ProviderExecution"
            public static let runToolTimeoutEnvelope: StaticString = "EditFlow.MCPToolCall.RunToolTimeoutEnvelope"
            public static let runToolCompletionCleanup: StaticString = "EditFlow.MCPToolCall.RunToolCompletionCleanup"
            public static let formatResult: StaticString = "EditFlow.MCPToolCall.FormatResult"
        }

        public enum MCPWindowToolCatalog {
            public static let construction: StaticString = "EditFlow.MCPWindowToolCatalog.Construction"
            public static let invalidateToolsCache: StaticString = "EditFlow.MCPWindowToolCatalog.InvalidateToolsCache"
            public static let invalidationToolSummariesChange: StaticString = "EditFlow.MCPWindowToolCatalog.Invalidation.ToolSummariesChange"
            public static let invalidationToolRegistrationUpdate: StaticString = "EditFlow.MCPWindowToolCatalog.Invalidation.ToolRegistrationUpdate"
            public static let registrationUpdateWindowToolsEnabledDidSet: StaticString = "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.WindowToolsEnabledDidSet"
            public static let registrationUpdateAgentBootstrap: StaticString = "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.AgentBootstrap"
            public static let readinessWarmAccess: StaticString = "EditFlow.MCPWindowToolCatalog.ReadinessWarmAccess"
            public static let domainRegistrationToolsPublication: StaticString = "EditFlow.MCPAppToolCatalog.DomainRegistrationToolsPublication"
            public static let codexTurnMCPServerEnable: StaticString = "EditFlow.MCPWindowToolCatalog.CodexTurnMCPServerEnable"
        }

        public enum ApplyEdits {
            public static let serviceRun: StaticString = "EditFlow.ApplyEdits.ServiceRun"
            public static let servicePreview: StaticString = "EditFlow.ApplyEdits.ServicePreview"
            public static let requestBuild: StaticString = "EditFlow.ApplyEdits.RequestBuild"
            public static let hostRead: StaticString = "EditFlow.ApplyEdits.HostRead"
            public static let hostWrite: StaticString = "EditFlow.ApplyEdits.HostWrite"
            public static let engineApply: StaticString = "EditFlow.ApplyEdits.EngineApply"
            public static let diffGeneration: StaticString = "EditFlow.ApplyEdits.DiffGeneration"
            public static let patchApply: StaticString = "EditFlow.ApplyEdits.PatchApply"
            public static let toolCardDiff: StaticString = "EditFlow.ApplyEdits.ToolCardDiff"
            public static let format: StaticString = "EditFlow.ApplyEdits.Format"
            public static let formatDecode: StaticString = "EditFlow.ApplyEdits.FormatDecode"
            public static let formatMarkdown: StaticString = "EditFlow.ApplyEdits.FormatMarkdown"
            public static let formatResource: StaticString = "EditFlow.ApplyEdits.FormatResource"
            public static let approvalWait: StaticString = "EditFlow.ApplyEdits.ApprovalWait"
            public static let flushDeltas: StaticString = "EditFlow.ApplyEdits.FlushDeltas"
        }

        public enum Search {
            public static let broadAdmissionWait: StaticString = "EditFlow.Search.BroadAdmissionWait"
            public static let broadAdmissionLeaseHold: StaticString = "EditFlow.Search.BroadAdmissionLeaseHold"
            public static let ingressFreshnessWait: StaticString = "EditFlow.Search.IngressFreshnessWait"
            public static let contentFreshnessValidation: StaticString = "EditFlow.Search.ContentFreshnessValidation"
            public static let contentFreshnessValidationStoreActorBody: StaticString = "EditFlow.Search.ContentFreshnessValidation.StoreActorBody"
            public static let contentFreshnessValidationRootActorBody: StaticString = "EditFlow.Search.ContentFreshnessValidation.RootActorBody"
            public static let contentScanTotal: StaticString = "EditFlow.Search.ContentScanTotal"
            public static let resultConstruction: StaticString = "EditFlow.Search.ResultConstruction"
            public static let entrypoint: StaticString = "EditFlow.Search.Entrypoint"
            public static let scopeFiltering: StaticString = "EditFlow.Search.ScopeFiltering"
            public static let actorSearchCall: StaticString = "EditFlow.Search.ActorSearchCall"
            public static let actorSearchUnified: StaticString = "EditFlow.Search.ActorSearchUnified"
            public static let contentBatch: StaticString = "EditFlow.Search.ContentBatch"
            public static let pathBatch: StaticString = "EditFlow.Search.PathBatch"
            public static let fileContentFetch: StaticString = "EditFlow.Search.FileContentFetch"
            public static let lineIndexCacheKey: StaticString = "EditFlow.Search.LineIndexCacheKey"
            public static let lineIndexLookup: StaticString = "EditFlow.Search.LineIndexLookup"
            public static let lineIndexBuild: StaticString = "EditFlow.Search.LineIndexBuild"
            public static let countOnlyFastPath: StaticString = "EditFlow.Search.CountOnlyFastPath"
            public static let regexFullBufferScan: StaticString = "EditFlow.Search.RegexFullBufferScan"
            public static let regexLineByLineScan: StaticString = "EditFlow.Search.RegexLineByLineScan"
            public static let literalScan: StaticString = "EditFlow.Search.LiteralScan"
            public static let materializeMatches: StaticString = "EditFlow.Search.MaterializeMatches"
            public static let catalogSnapshot: StaticString = "EditFlow.Search.CatalogSnapshot"
            public static let dtoBuild: StaticString = "EditFlow.Search.DTOBuild"
            public static let dtoRootRefSnapshotLookup: StaticString = "EditFlow.Search.DTOBuild.RootRefSnapshotLookup"
            public static let dtoDisplayResolverPreparation: StaticString = "EditFlow.Search.DTOBuild.DisplayResolverPreparation"
            public static let dtoPathDisplayProjection: StaticString = "EditFlow.Search.DTOBuild.PathDisplayProjection"
            public static let dtoCapAccounting: StaticString = "EditFlow.Search.DTOBuild.CapAccounting"
            public static let dtoAssembly: StaticString = "EditFlow.Search.DTOBuild.Assembly"
            public static let providerTotal: StaticString = "EditFlow.Search.ProviderTotal"
            public static let providerRequestMetadata: StaticString = "EditFlow.Search.ProviderRequestMetadata"
            public static let providerLookupContextResolution: StaticString = "EditFlow.Search.ProviderLookupContextResolution"
            public static let providerWorkspaceSearchAwait: StaticString = "EditFlow.Search.ProviderWorkspaceSearchAwait"
            public static let rootScopeAvailabilityGate: StaticString = "EditFlow.Search.RootScopeAvailabilityGate"
            public static let workspaceReadinessAcquireGate: StaticString = "EditFlow.Search.WorkspaceReadinessAcquireGate"
            public static let workspaceReadinessValidationGate: StaticString = "EditFlow.Search.WorkspaceReadinessValidationGate"
            public static let providerAutoSelection: StaticString = "EditFlow.Search.ProviderAutoSelection"
            public static let providerValueEncoding: StaticString = "EditFlow.Search.ProviderValueEncoding"

            public enum AutoSelect {
                public static let shapeEligibility: StaticString = "EditFlow.Search.AutoSelect.ShapeEligibility"
                public static let agentEligibility: StaticString = "EditFlow.Search.AutoSelect.AgentEligibility"
                public static let mutation: StaticString = "EditFlow.Search.AutoSelect.Mutation"
            }
        }

        public enum ReadFile {
            public static let providerTotal: StaticString = "EditFlow.ReadFile.ProviderTotal"
            public static let providerArgumentParsing: StaticString = "EditFlow.ReadFile.ProviderArgumentParsing"
            public static let providerRequestMetadata: StaticString = "EditFlow.ReadFile.ProviderRequestMetadata"
            public static let providerLookupContextResolution: StaticString = "EditFlow.ReadFile.ProviderLookupContextResolution"
            public static let providerPathTranslation: StaticString = "EditFlow.ReadFile.ProviderPathTranslation"
            public static let providerReadEnvelope: StaticString = "EditFlow.ReadFile.ProviderReadEnvelope"
            public static let providerReplyProjection: StaticString = "EditFlow.ReadFile.ProviderReplyProjection"
            public static let providerAutoSelect: StaticString = "EditFlow.ReadFile.ProviderAutoSelect"
            public static let providerValueEncoding: StaticString = "EditFlow.ReadFile.ProviderValueEncoding"
            public static let explicitIngressFreshnessWait: StaticString = "EditFlow.ReadFile.ExplicitIngressFreshnessWait"
            public static let exactCatalogShortcut: StaticString = "EditFlow.ReadFile.ExactCatalogShortcut"
            public static let storeReadContentForwardAwait: StaticString = "EditFlow.ReadFile.StoreReadContentForwardAwait"
            public static let folderResolutionGeneralLookupFallback: StaticString = "EditFlow.ReadFile.FolderResolutionGeneralLookupFallback"
            public static let pathLookupStaticSnapshotBuild: StaticString = "EditFlow.ReadFile.PathLookupStaticSnapshotBuild"
            public static let resolveReadableFile: StaticString = "EditFlow.ReadFile.ResolveReadableFile"
            public static let exactPathIssueDetection: StaticString = "EditFlow.ReadFile.ExactPathIssueDetection"
            public static let rootRefsLookup: StaticString = "EditFlow.ReadFile.RootRefsLookup"
            public static let folderResolution: StaticString = "EditFlow.ReadFile.FolderResolution"
            public static let externalFolderGuard: StaticString = "EditFlow.ReadFile.ExternalFolderGuard"
            public static let readableServiceResolution: StaticString = "EditFlow.ReadFile.ReadableServiceResolution"
            public static let exactCatalogLookupActorBody: StaticString = "EditFlow.ReadFile.ExactCatalogLookupActorBody"
            public static let workspaceContentLoad: StaticString = "EditFlow.ReadFile.WorkspaceContentLoad"
            public static let splitPreservingLineEndings: StaticString = "EditFlow.ReadFile.SplitPreservingLineEndings"
            public static let buildSlice: StaticString = "EditFlow.ReadFile.BuildSlice"

            public enum AutoSelect {
                public static let total: StaticString = "EditFlow.ReadFile.AutoSelect.Total"
                public static let eligibilityResolution: StaticString = "EditFlow.ReadFile.AutoSelect.EligibilityResolution"
                public static let selectionProjection: StaticString = "EditFlow.ReadFile.AutoSelect.SelectionProjection"
                public static let fullFlowTotal: StaticString = "EditFlow.ReadFile.AutoSelect.FullFlowTotal"
                public static let fullRequestMetadata: StaticString = "EditFlow.ReadFile.AutoSelect.FullRequestMetadata"
                public static let fullLookupContext: StaticString = "EditFlow.ReadFile.AutoSelect.FullLookupContext"
                public static let fullSnapshotResolution: StaticString = "EditFlow.ReadFile.AutoSelect.FullSnapshotResolution"
                public static let structuralAddTotal: StaticString = "EditFlow.ReadFile.AutoSelect.StructuralAddTotal"
                public static let candidateResolutionTotal: StaticString = "EditFlow.ReadFile.AutoSelect.CandidateResolutionTotal"
                public static let structuralMerge: StaticString = "EditFlow.ReadFile.AutoSelect.StructuralMerge"
                public static let autoCodemapRecomputeTotal: StaticString = "EditFlow.ReadFile.AutoSelect.AutoCodemapRecomputeTotal"
                public static let selectedFileLookup: StaticString = "EditFlow.ReadFile.AutoSelect.SelectedFileLookup"
                public static let fullSliceClearing: StaticString = "EditFlow.ReadFile.AutoSelect.FullSliceClearing"
                public static let finalSelectionEquality: StaticString = "EditFlow.ReadFile.AutoSelect.FinalSelectionEquality"
                public static let persistence: StaticString = "EditFlow.ReadFile.AutoSelect.Persistence"
                public static let responseEnqueue: StaticString = "EditFlow.ReadFile.AutoSelect.ResponseEnqueue"
                public static let canonicalQueueWait: StaticString = "EditFlow.ReadFile.AutoSelect.CanonicalQueueWait"
                public static let canonicalMutation: StaticString = "EditFlow.ReadFile.AutoSelect.CanonicalMutation"
                public static let canonicalStoredCommit: StaticString = "EditFlow.ReadFile.AutoSelect.CanonicalStoredCommit"
                public static let mirrorEnqueue: StaticString = "EditFlow.ReadFile.AutoSelect.MirrorEnqueue"
                public static let mirrorQueueWait: StaticString = "EditFlow.ReadFile.AutoSelect.MirrorQueueWait"
                public static let mirrorApply: StaticString = "EditFlow.ReadFile.AutoSelect.MirrorApply"
                public static let drainWait: StaticString = "EditFlow.ReadFile.AutoSelect.DrainWait"
                public static let sliceFlowTotal: StaticString = "EditFlow.ReadFile.AutoSelect.SliceFlowTotal"
            }
        }

        public enum FileSystem {
            public static let contentLoadTotal: StaticString = "EditFlow.FileSystem.ContentLoadTotal"
            public static let contentLoadActorBody: StaticString = "EditFlow.FileSystem.ContentLoadActorBody"
            public static let contentReadRequestPreparation: StaticString = "EditFlow.FileSystem.ContentReadRequestPreparation"
            public static let contentReadOffActorAwait: StaticString = "EditFlow.FileSystem.ContentReadOffActorAwait"
            public static let contentModificationDateLookup: StaticString = "EditFlow.FileSystem.ContentModificationDateLookup"
            public static let contentReadWorkerPermitWait: StaticString = "EditFlow.FileSystem.ContentReadWorkerPermitWait"
            public static let contentReadWorkerBody: StaticString = "EditFlow.FileSystem.ContentReadWorkerBody"
        }

        public enum Bootstrap {
            public static let handshakeIOQueueEnvelope: StaticString = "EditFlow.Bootstrap.HandshakeIOQueueEnvelope"
            public static let handshakeIOBlockingRead: StaticString = "EditFlow.Bootstrap.HandshakeIOBlockingRead"
            public static let admission: StaticString = "EditFlow.Bootstrap.Admission"
            public static let postAcceptStartup: StaticString = "EditFlow.Bootstrap.PostAcceptStartup"
        }

        public enum WorkspaceDurability {
            public static let flushWait: StaticString = "EditFlow.WorkspaceDurability.FlushWait"
            public static let atomicWrite: StaticString = "EditFlow.WorkspaceDurability.AtomicWrite"
        }

        public enum Transcript {
            public static let scheduleRefresh: StaticString = "EditFlow.Transcript.ScheduleRefresh"
            public static let refreshTotal: StaticString = "EditFlow.Transcript.RefreshTotal"
            public static let importTranscript: StaticString = "EditFlow.Transcript.ImportTranscript"
            public static let incrementalImport: StaticString = "EditFlow.Transcript.IncrementalImport"
            public static let payloadMap: StaticString = "EditFlow.Transcript.PayloadMap"
            public static let sanitize: StaticString = "EditFlow.Transcript.Sanitize"
            public static let projectionBuild: StaticString = "EditFlow.Transcript.ProjectionBuild"
            public static let publish: StaticString = "EditFlow.Transcript.Publish"
            public static let toolProcessing: StaticString = "EditFlow.Transcript.ToolProcessing"
        }

        public enum Parser {
            public static let chatContentParse: StaticString = "EditFlow.Parser.ChatContentParse"
            public static let diffParseChanges: StaticString = "EditFlow.Parser.DiffParseChanges"
            public static let diffRegexCacheLookup: StaticString = "EditFlow.Parser.DiffRegexCacheLookup"
        }

        public enum Finalization {
            public static let watchdogArm: StaticString = "EditFlow.Finalization.WatchdogArm"
            public static let watchdogSkip: StaticString = "EditFlow.Finalization.WatchdogSkip"
            public static let watchdogCancel: StaticString = "EditFlow.Finalization.WatchdogCancel"
            public static let watchdogComplete: StaticString = "EditFlow.Finalization.WatchdogComplete"
        }

        public enum UnifiedDiff {
            public static let parseForRender: StaticString = "EditFlow.UnifiedDiff.ParseForRender"
            public static let attributedBuild: StaticString = "EditFlow.UnifiedDiff.AttributedBuild"
        }

        public enum Git {
            public static let hunkParsing: StaticString = "EditFlow.Git.HunkParsing"
            public static let mapLoadingExcerpting: StaticString = "EditFlow.Git.MapLoadingExcerpting"
            public static let dtoConstruction: StaticString = "EditFlow.Git.DTOConstruction"
        }

        public enum MCPProviderProjection {
            public static let workerBody: StaticString = "EditFlow.MCPProviderProjection.WorkerBody"
        }
    }

    public enum Lifecycle {
        public enum MCPToolCall {
            public static let received: StaticString = "MCP.ToolCall.Received"
            public static let routingSnapshotCompleted: StaticString = "MCP.ToolCall.RoutingSnapshotCompleted"
            public static let limiterWaitBegan: StaticString = "MCP.ToolCall.LimiterWaitBegan"
            public static let limiterAcquired: StaticString = "MCP.ToolCall.LimiterAcquired"
            public static let permitQueued: StaticString = "MCP.ToolCall.PermitQueued"
            public static let permitAcquired: StaticString = "MCP.ToolCall.PermitAcquired"
            public static let permitReleased: StaticString = "MCP.ToolCall.PermitReleased"
            public static let observerScheduled: StaticString = "MCP.ToolCall.ObserverScheduled"
            public static let observerEntered: StaticString = "MCP.ToolCall.ObserverEntered"
            public static let observerExited: StaticString = "MCP.ToolCall.ObserverExited"
            public static let mainActorScheduled: StaticString = "MCP.ToolCall.MainActorScheduled"
            public static let mainActorEntered: StaticString = "MCP.ToolCall.MainActorEntered"
            public static let mainActorExited: StaticString = "MCP.ToolCall.MainActorExited"
            public static let publicationOwnershipState: StaticString = "MCP.ToolCall.PublicationOwnershipState"
            public static let completionObserverReturned: StaticString = "MCP.ToolCall.CompletionObserverReturned"
            public static let formatResultReturned: StaticString = "MCP.ToolCall.FormatResultReturned"
            public static let resolvedProviderBegan: StaticString = "MCP.ToolCall.ResolvedProviderBegan"
            public static let resolvedProviderEnded: StaticString = "MCP.ToolCall.ResolvedProviderEnded"
            public static let resourceAdmissionReleased: StaticString = "MCP.ToolCall.ResourceAdmissionReleased"
            public static let handlerResultReady: StaticString = "MCP.ToolCall.HandlerResultReady"
        }

        public enum MCPRunTool {
            public static let preflushBegan: StaticString = "MCP.RunTool.PreflushBegan"
            public static let preflushEnded: StaticString = "MCP.RunTool.PreflushEnded"
            public static let registrationScheduled: StaticString = "MCP.RunTool.RegistrationScheduled"
            public static let registrationMainActorEntered: StaticString = "MCP.RunTool.RegistrationMainActorEntered"
            public static let registrationEnded: StaticString = "MCP.RunTool.RegistrationEnded"
            public static let providerBegan: StaticString = "MCP.RunTool.ProviderBegan"
            public static let providerEnded: StaticString = "MCP.RunTool.ProviderEnded"
            public static let cleanupScheduled: StaticString = "MCP.RunTool.CleanupScheduled"
            public static let cleanupMainActorEntered: StaticString = "MCP.RunTool.CleanupMainActorEntered"
            public static let unregister: StaticString = "MCP.RunTool.Unregister"
            public static let idleWaitersResumed: StaticString = "MCP.RunTool.IdleWaitersResumed"
            public static let cleanupEnded: StaticString = "MCP.RunTool.CleanupEnded"
            public static let returned: StaticString = "MCP.RunTool.Return"
        }

        public enum FileSystem {
            public static let callbackAccepted: StaticString = "FileSystem.CallbackAccepted"
            public static let serviceEnqueueEntered: StaticString = "FileSystem.ServiceEnqueueEntered"
            public static let servicePublish: StaticString = "FileSystem.ServicePublish"
            public static let contentLoadEntered: StaticString = "FileSystem.ContentLoadEntered"
            public static let contentReadRequestPrepared: StaticString = "FileSystem.ContentReadRequestPrepared"
            public static let contentReadOffActorScheduled: StaticString = "FileSystem.ContentReadOffActorScheduled"
            public static let contentReadWorkerReturned: StaticString = "FileSystem.ContentReadWorkerReturned"
            public static let contentLoadReturned: StaticString = "FileSystem.ContentLoadReturned"
            public static let contentReadWorkerPermitWaitBegan: StaticString = "FileSystem.ContentReadWorkerPermitWaitBegan"
            public static let contentReadWorkerPermitAcquired: StaticString = "FileSystem.ContentReadWorkerPermitAcquired"
            public static let contentReadWorkerPermitCancelled: StaticString = "FileSystem.ContentReadWorkerPermitCancelled"
            public static let contentReadWorkerOverloaded: StaticString = "FileSystem.ContentReadWorkerOverloaded"
        }

        public enum Search {
            public static let contentFreshnessStoreEntered: StaticString = "Search.ContentFreshnessStoreEntered"
            public static let contentFreshnessStoreReturned: StaticString = "Search.ContentFreshnessStoreReturned"
            public static let contentFreshnessRootEntered: StaticString = "Search.ContentFreshnessRootEntered"
            public static let contentFreshnessRootReturned: StaticString = "Search.ContentFreshnessRootReturned"
            public static let broadAdmissionWaitBegan: StaticString = "Search.BroadAdmissionWaitBegan"
            public static let broadAdmissionPermitAcquired: StaticString = "Search.BroadAdmissionPermitAcquired"
            public static let broadAdmissionPermitCancelled: StaticString = "Search.BroadAdmissionPermitCancelled"
            public static let broadAdmissionPermitReleased: StaticString = "Search.BroadAdmissionPermitReleased"
            public static let broadAdmissionOverloaded: StaticString = "Search.BroadAdmissionOverloaded"
            public static let broadAdmissionWaitExpired: StaticString = "Search.BroadAdmissionWaitExpired"
            public static let providerEntered: StaticString = "Search.ProviderEntered"
            public static let providerWorkspaceSearchReturned: StaticString = "Search.ProviderWorkspaceSearchReturned"
            public static let providerDTOReady: StaticString = "Search.ProviderDTOReady"
            public static let providerAutoSelectionReturned: StaticString = "Search.ProviderAutoSelectionReturned"
            public static let providerResultReady: StaticString = "Search.ProviderResultReady"
        }

        public enum ReadFile {
            public static let providerEntered: StaticString = "ReadFile.ProviderEntered"
            public static let explicitFreshnessBegan: StaticString = "ReadFile.ExplicitFreshnessBegan"
            public static let explicitFreshnessEnded: StaticString = "ReadFile.ExplicitFreshnessEnded"
            public static let exactCatalogLookupResolved: StaticString = "ReadFile.ExactCatalogLookupResolved"
            public static let exactCatalogShortcutResolved: StaticString = "ReadFile.ExactCatalogShortcutResolved"
            public static let folderResolutionReturned: StaticString = "ReadFile.FolderResolutionReturned"
            public static let readableServiceResolutionReturned: StaticString = "ReadFile.ReadableServiceResolutionReturned"
            public static let storeReadContentEntered: StaticString = "ReadFile.StoreReadContentEntered"
            public static let storeReadContentReturned: StaticString = "ReadFile.StoreReadContentReturned"
            public static let providerResultReady: StaticString = "ReadFile.ProviderResultReady"
        }

        public enum Bootstrap {
            public static let socketAccepted: StaticString = "Bootstrap.SocketAccepted"
            public static let handshakeIOQueued: StaticString = "Bootstrap.HandshakeIOQueued"
            public static let handshakeIOBegan: StaticString = "Bootstrap.HandshakeIOBegan"
            public static let handshakeIOEnded: StaticString = "Bootstrap.HandshakeIOEnded"
            public static let admissionBegan: StaticString = "Bootstrap.AdmissionBegan"
            public static let admissionEnded: StaticString = "Bootstrap.AdmissionEnded"
            public static let acceptedResponseSent: StaticString = "Bootstrap.AcceptedResponseSent"
            public static let ownershipTransferred: StaticString = "Bootstrap.OwnershipTransferred"
            public static let postAcceptStartupBegan: StaticString = "Bootstrap.PostAcceptStartupBegan"
            public static let postAcceptStartupEnded: StaticString = "Bootstrap.PostAcceptStartupEnded"
        }

        public enum WorkspaceIngress {
            public static let storeSinkScheduled: StaticString = "WorkspaceIngress.StoreSinkScheduled"
            public static let storeSinkBegan: StaticString = "WorkspaceIngress.StoreSinkBegan"
            public static let storeCanonicalApplyCompleted: StaticString = "WorkspaceIngress.StoreCanonicalApplyCompleted"
            public static let codemapInvalidationStage: StaticString = "WorkspaceIngress.CodemapInvalidationStage"
            public static let rootFlushBegan: StaticString = "WorkspaceIngress.RootFlushBegan"
            public static let rootFlushEnded: StaticString = "WorkspaceIngress.RootFlushEnded"
        }

        public enum ReadFileAutoSelect {
            public static let enqueueAccepted: StaticString = "ReadFile.AutoSelect.EnqueueAccepted"
            public static let enqueueCoalesced: StaticString = "ReadFile.AutoSelect.EnqueueCoalesced"
            public static let canonicalApplyBegan: StaticString = "ReadFile.AutoSelect.CanonicalApplyBegan"
            public static let canonicalApplyEnded: StaticString = "ReadFile.AutoSelect.CanonicalApplyEnded"
            public static let mirrorScheduled: StaticString = "ReadFile.AutoSelect.MirrorScheduled"
            public static let mirrorCoalesced: StaticString = "ReadFile.AutoSelect.MirrorCoalesced"
            public static let mirrorApplyBegan: StaticString = "ReadFile.AutoSelect.MirrorApplyBegan"
            public static let mirrorApplyEnded: StaticString = "ReadFile.AutoSelect.MirrorApplyEnded"
            public static let drainBegan: StaticString = "ReadFile.AutoSelect.DrainBegan"
            public static let drainEnded: StaticString = "ReadFile.AutoSelect.DrainEnded"
        }

        public enum WorkspaceDurability {
            public static let flushBegan: StaticString = "WorkspaceDurability.FlushBegan"
            public static let flushEnded: StaticString = "WorkspaceDurability.FlushEnded"
            public static let writeBegan: StaticString = "WorkspaceDurability.WriteBegan"
            public static let writeEnded: StaticString = "WorkspaceDurability.WriteEnded"
        }
    }

    #if DEBUG
        public struct DebugCaptureStageAggregate {
            public let stageName: String
            public let sanitizedDimensions: String
            public let sampleCount: Int
            public let p50MS: Double
            public let p95MS: Double
            public let maxMS: Double
            public let totalMS: Double

            public var payload: [String: Any] {
                [
                    "stage_name": stageName,
                    "sanitized_dimensions": sanitizedDimensions,
                    "sample_count": sampleCount,
                    "p50_ms": Self.roundedMS(p50MS),
                    "p95_ms": Self.roundedMS(p95MS),
                    "max_ms": Self.roundedMS(maxMS),
                    "total_ms": Self.roundedMS(totalMS)
                ]
            }

            private static func roundedMS(_ value: Double) -> Double {
                (value * 1000).rounded() / 1000
            }
        }

        public struct DebugCaptureLifecycleEvent {
            public let ordinal: UInt64
            public let offsetMS: Double
            public let eventName: String
            public let correlationID: String
            public let requestIdentity: MCPRequestTimelineIdentity?
            public let sanitizedDimensions: String

            public var payload: [String: Any] {
                [
                    "ordinal": ordinal,
                    "offset_ms": Self.roundedMS(offsetMS),
                    "event_name": eventName,
                    "correlation_id": correlationID,
                    "request_identity": requestIdentity.map(Self.requestIdentityPayload) ?? NSNull(),
                    "sanitized_dimensions": sanitizedDimensions
                ]
            }

            private static func requestIdentityPayload(_ identity: MCPRequestTimelineIdentity) -> [String: Any] {
                [
                    "jsonrpc_request_id": identity.jsonRPCRequestID?.description ?? NSNull(),
                    "connection_id": identity.connectionID ?? NSNull(),
                    "connection_generation": identity.connectionGeneration ?? NSNull(),
                    "app_invocation_id": identity.appInvocationID ?? NSNull(),
                    "request_ordinal": identity.requestOrdinal ?? NSNull()
                ]
            }

            private static func roundedMS(_ value: Double) -> Double {
                (value * 1000).rounded() / 1000
            }
        }

        public struct DebugCaptureSnapshot {
            public let label: String
            public let active: Bool
            public let startedAt: Date?
            public let finishedAt: Date?
            public let maxSamples: Int
            public let retainedSampleCount: Int
            public let droppedSampleCount: Int
            public let stages: [DebugCaptureStageAggregate]
            public let maxLifecycleEvents: Int
            public let retainedLifecycleEventCount: Int
            public let droppedLifecycleEventCount: Int
            public let lifecycleEvents: [DebugCaptureLifecycleEvent]

            public func payload(includeTimeline: Bool = true) -> [String: Any] {
                var result: [String: Any] = [
                    "label": label,
                    "active": active,
                    "started_at": startedAt?.timeIntervalSince1970 ?? NSNull(),
                    "finished_at": finishedAt?.timeIntervalSince1970 ?? NSNull(),
                    "max_samples": maxSamples,
                    "retained_sample_count": retainedSampleCount,
                    "dropped_sample_count": droppedSampleCount,
                    "stages": stages.map(\.payload),
                    "max_lifecycle_events": maxLifecycleEvents,
                    "retained_lifecycle_event_count": retainedLifecycleEventCount,
                    "dropped_lifecycle_event_count": droppedLifecycleEventCount,
                    "timeline_included": includeTimeline,
                    "request_timeline_count": requestTimelinePayloads.count,
                    "request_timelines": requestTimelinePayloads,
                    "workload_matrix_catalog": Self.workloadMatrixCatalog
                ]
                if includeTimeline {
                    result["lifecycle_events"] = lifecycleEvents.map(\.payload)
                }
                return result
            }

            private var requestTimelinePayloads: [[String: Any]] {
                let grouped = Dictionary(grouping: lifecycleEvents) { event in
                    event.requestIdentity?.appInvocationID ?? event.correlationID
                }
                return grouped.keys.sorted().compactMap { key in
                    guard let events = grouped[key]?.sorted(by: { $0.ordinal < $1.ordinal }),
                          let first = events.first
                    else { return nil }
                    return [
                        "join_key": key,
                        "request_identity": first.payload["request_identity"] ?? NSNull(),
                        "event_count": events.count,
                        "event_names": events.map(\.eventName),
                        "first_offset_ms": events.first?.payload["offset_ms"] ?? NSNull(),
                        "last_offset_ms": events.last?.payload["offset_ms"] ?? NSNull()
                    ]
                }
            }

            private nonisolated(unsafe) static let workloadMatrixCatalog: [[String: Any]] = [
                ["id": "same_connection_ordinary_burst", "connections": 1, "windows": 1, "transcript": "short"],
                ["id": "same_connection_mixed_ordinary_search", "connections": 1, "windows": 1, "transcript": "short"],
                ["id": "distinct_connections_one_window", "connections": 2, "windows": 1, "transcript": "short"],
                ["id": "distinct_windows", "connections": 2, "windows": 2, "transcript": "short"],
                ["id": "agent_transcript_short_vs_long", "connections": 1, "windows": 1, "transcript": "short_and_long"]
            ]
        }

        public enum DebugCaptureBeginResult {
            case started(DebugCaptureSnapshot)
            case busy(DebugCaptureSnapshot)
        }

        private struct DebugCaptureKey: Hashable {
            let stageName: String
            let sanitizedDimensions: String
        }

        private struct DebugCaptureStart {
            let epoch: UInt64
            let startNanoseconds: UInt64
        }

        private final class DebugCaptureActiveHint {
            @available(macOS 15.0, *)
            private final class AtomicStorage {
                let value = Atomic(false)
            }

            private let storage: AnyObject?

            public init() {
                if #available(macOS 15.0, *) {
                    storage = AtomicStorage()
                } else {
                    storage = nil
                }
            }

            public func loadIfAvailable() -> Bool? {
                if #available(macOS 15.0, *), let storage = storage as? AtomicStorage {
                    return storage.value.load(ordering: .acquiring)
                }
                return nil
            }

            public func store(_ active: Bool) {
                if #available(macOS 15.0, *), let storage = storage as? AtomicStorage {
                    storage.value.store(active, ordering: .releasing)
                }
            }
        }

        private final class DebugCaptureRecorder {
            private static let sampleLimitRange = 100 ... 100_000
            private static let lifecycleEventLimit = 20000

            private let lock = NSLock()
            private let activeHint = DebugCaptureActiveHint()
            private var active = false
            private var captureEpoch: UInt64 = 0
            private var label = ""
            private var startedAt: Date?
            private var finishedAt: Date?
            private var captureStartNanoseconds: UInt64?
            private var maxSamples = 20000
            private var retainedSampleCount = 0
            private var droppedSampleCount = 0
            private var samplesByKey: [DebugCaptureKey: [Double]] = [:]
            private var nextLifecycleOrdinal: UInt64 = 1
            private var retainedLifecycleEventCount = 0
            private var droppedLifecycleEventCount = 0
            private var lifecycleEvents: [DebugCaptureLifecycleEvent] = []

            var isActive: Bool {
                if let active = activeHint.loadIfAvailable() {
                    return active
                }
                lock.lock()
                defer { lock.unlock() }
                return active
            }

            public func begin(label: String, maxSamples: Int) -> DebugCaptureBeginResult {
                lock.lock()
                defer { lock.unlock() }
                guard !active else { return .busy(snapshotLocked()) }
                captureEpoch += 1
                self.label = Self.sanitizedLabel(label)
                // Defense in depth for non-MCP callers; MCP controls reject out-of-range input earlier.
                self.maxSamples = Self.clampedMaxSamples(maxSamples)
                active = true
                startedAt = Date()
                finishedAt = nil
                captureStartNanoseconds = DispatchTime.now().uptimeNanoseconds
                retainedSampleCount = 0
                droppedSampleCount = 0
                samplesByKey.removeAll(keepingCapacity: true)
                nextLifecycleOrdinal = 1
                retainedLifecycleEventCount = 0
                droppedLifecycleEventCount = 0
                lifecycleEvents.removeAll(keepingCapacity: true)
                activeHint.store(true)
                return .started(snapshotLocked())
            }

            public func snapshot(finish: Bool) -> DebugCaptureSnapshot {
                lock.lock()
                defer { lock.unlock() }
                if finish, active {
                    active = false
                    activeHint.store(false)
                    finishedAt = Date()
                }
                return snapshotLocked()
            }

            public func resetForTesting() {
                lock.lock()
                active = false
                activeHint.store(false)
                label = ""
                startedAt = nil
                finishedAt = nil
                captureStartNanoseconds = nil
                maxSamples = 20000
                retainedSampleCount = 0
                droppedSampleCount = 0
                samplesByKey.removeAll(keepingCapacity: false)
                nextLifecycleOrdinal = 1
                retainedLifecycleEventCount = 0
                droppedLifecycleEventCount = 0
                lifecycleEvents.removeAll(keepingCapacity: false)
                lock.unlock()
            }

            public func startTimestampIfActive() -> DebugCaptureStart? {
                if let active = activeHint.loadIfAvailable(), !active { return nil }
                lock.lock()
                defer { lock.unlock() }
                guard active else { return nil }
                return DebugCaptureStart(epoch: captureEpoch, startNanoseconds: DispatchTime.now().uptimeNanoseconds)
            }

            public func activeEpochIfActive() -> UInt64? {
                if let active = activeHint.loadIfAvailable(), !active { return nil }
                lock.lock()
                defer { lock.unlock() }
                return active ? captureEpoch : nil
            }

            public func shouldRecordLifecycleEvent(_ correlation: LifecycleCorrelation) -> Bool {
                guard let correlationEpoch = correlation.captureEpoch else { return false }
                if let active = activeHint.loadIfAvailable(), !active { return false }
                lock.lock()
                defer { lock.unlock() }
                return active && correlationEpoch == captureEpoch
            }

            public func recordLifecycleEvent(
                eventName: String,
                correlation: LifecycleCorrelation,
                sanitizedDimensions: String
            ) {
                guard let correlationEpoch = correlation.captureEpoch else { return }
                let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
                lock.lock()
                defer { lock.unlock() }
                guard active,
                      correlationEpoch == captureEpoch,
                      let captureStartNanoseconds
                else { return }
                let ordinal = nextLifecycleOrdinal
                nextLifecycleOrdinal &+= 1
                guard retainedLifecycleEventCount < min(maxSamples, Self.lifecycleEventLimit) else {
                    droppedLifecycleEventCount += 1
                    return
                }
                let elapsedNanoseconds = nowNanoseconds >= captureStartNanoseconds
                    ? nowNanoseconds - captureStartNanoseconds
                    : 0
                lifecycleEvents.append(DebugCaptureLifecycleEvent(
                    ordinal: ordinal,
                    offsetMS: Double(elapsedNanoseconds) / 1_000_000.0,
                    eventName: eventName,
                    correlationID: correlation.id.uuidString,
                    requestIdentity: correlation.requestIdentity,
                    sanitizedDimensions: sanitizedDimensions
                ))
                retainedLifecycleEventCount += 1
            }

            public func record(stageName: String, sanitizedDimensions: String, captureEpoch: UInt64, startNanoseconds: UInt64) {
                let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startNanoseconds
                let elapsedMS = Double(elapsedNanoseconds) / 1_000_000.0
                lock.lock()
                defer { lock.unlock() }
                guard active, captureEpoch == self.captureEpoch else { return }
                guard retainedSampleCount < maxSamples else {
                    droppedSampleCount += 1
                    return
                }
                let key = DebugCaptureKey(stageName: stageName, sanitizedDimensions: sanitizedDimensions)
                samplesByKey[key, default: []].append(elapsedMS)
                retainedSampleCount += 1
            }

            private static func clampedMaxSamples(_ maxSamples: Int) -> Int {
                min(max(maxSamples, sampleLimitRange.lowerBound), sampleLimitRange.upperBound)
            }

            private static func sanitizedLabel(_ label: String) -> String {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
                let replacement = UnicodeScalar("_")
                let scalars = trimmed.unicodeScalars.map { scalar in
                    allowed.contains(scalar) ? scalar : replacement
                }
                return String(String.UnicodeScalarView(scalars.prefix(64)))
            }

            private func snapshotLocked() -> DebugCaptureSnapshot {
                let stages = samplesByKey.map { key, samples in
                    let sorted = samples.sorted()
                    return DebugCaptureStageAggregate(
                        stageName: key.stageName,
                        sanitizedDimensions: key.sanitizedDimensions,
                        sampleCount: sorted.count,
                        p50MS: nearestRank(sorted, percentile: 0.50),
                        p95MS: nearestRank(sorted, percentile: 0.95),
                        maxMS: sorted.last ?? 0,
                        totalMS: sorted.reduce(0, +)
                    )
                }
                .sorted {
                    if $0.stageName == $1.stageName {
                        return $0.sanitizedDimensions < $1.sanitizedDimensions
                    }
                    return $0.stageName < $1.stageName
                }
                return DebugCaptureSnapshot(
                    label: label,
                    active: active,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    maxSamples: maxSamples,
                    retainedSampleCount: retainedSampleCount,
                    droppedSampleCount: droppedSampleCount,
                    stages: stages,
                    maxLifecycleEvents: min(maxSamples, Self.lifecycleEventLimit),
                    retainedLifecycleEventCount: retainedLifecycleEventCount,
                    droppedLifecycleEventCount: droppedLifecycleEventCount,
                    lifecycleEvents: lifecycleEvents
                )
            }

            private func nearestRank(_ sorted: [Double], percentile: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                let rank = Int(ceil(percentile * Double(sorted.count))) - 1
                return sorted[min(max(rank, 0), sorted.count - 1)]
            }
        }

        private nonisolated(unsafe) static let debugCaptureRecorder = DebugCaptureRecorder()

        public static var isDebugCaptureActive: Bool {
            debugCaptureRecorder.isActive
        }

        public static func beginDebugCapture(label: String, maxSamples: Int) -> DebugCaptureBeginResult {
            debugCaptureRecorder.begin(label: label, maxSamples: maxSamples)
        }

        public static func debugCaptureSnapshot(finish: Bool) -> DebugCaptureSnapshot {
            debugCaptureRecorder.snapshot(finish: finish)
        }

        public static func resetDebugCaptureForTesting() {
            debugCaptureRecorder.resetForTesting()
        }
    #endif

    #if (DEBUG || EDIT_FLOW_PERF) && canImport(os)
        private static let signposter = OSSignposter(subsystem: "com.repoprompt.edit-flow", category: "perf")
        private static let logger = Logger(subsystem: "com.repoprompt.edit-flow", category: "perf")
        private static let environmentEnabled: Bool = {
            guard let raw = ProcessInfo.processInfo.environment["REPOPROMPT_EDIT_FLOW_PERF"] else {
                return false
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "y", "on"].contains(value)
        }()

        public static var isEnabled: Bool {
            environmentEnabled || UserDefaults.standard.bool(forKey: "editFlowPerfEnabled")
        }

        private static var shouldCaptureIntervals: Bool {
            #if DEBUG
                isDebugCaptureActive
            #else
                false
            #endif
        }

        private static func makeIntervalState(_ name: StaticString, dimensions: Dimensions) -> IntervalState? {
            let signpostState = isEnabled ? signposter.beginInterval(name) : nil
            #if DEBUG
                let debugCaptureStart = debugCaptureRecorder.startTimestampIfActive()
                guard signpostState != nil || debugCaptureStart != nil else { return nil }
                return IntervalState(
                    signpostState: signpostState,
                    debugCaptureEpoch: debugCaptureStart?.epoch,
                    debugCaptureStartNanoseconds: debugCaptureStart?.startNanoseconds,
                    debugCaptureStageName: String(describing: name),
                    debugCaptureDimensions: dimensions.logDescription
                )
            #else
                guard signpostState != nil else { return nil }
                return IntervalState(signpostState: signpostState)
            #endif
        }

        @discardableResult
        public static func begin(_ name: StaticString) -> IntervalState? {
            guard isEnabled || shouldCaptureIntervals else { return nil }
            return makeIntervalState(name, dimensions: Dimensions())
        }

        @discardableResult
        public static func begin(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) -> IntervalState? {
            guard isEnabled || shouldCaptureIntervals else { return nil }
            let renderedDimensions = dimensions()
            if isEnabled {
                logDimensions(renderedDimensions)
            }
            return makeIntervalState(name, dimensions: renderedDimensions)
        }

        public static func end(_ name: StaticString, _ state: IntervalState?) {
            guard let state else { return }
            #if DEBUG
                if let captureEpoch = state.debugCaptureEpoch,
                   let startNanoseconds = state.debugCaptureStartNanoseconds
                {
                    debugCaptureRecorder.record(
                        stageName: state.debugCaptureStageName,
                        sanitizedDimensions: state.debugCaptureDimensions,
                        captureEpoch: captureEpoch,
                        startNanoseconds: startNanoseconds
                    )
                }
            #endif
            if let signpostState = state.signpostState {
                signposter.endInterval(name, signpostState)
            }
        }

        public static func end(_ name: StaticString, _ state: IntervalState?, _ dimensions: @autoclosure () -> Dimensions) {
            guard let state else { return }
            let renderedDimensions = dimensions()
            if isEnabled {
                logDimensions(renderedDimensions)
            }
            #if DEBUG
                if let captureEpoch = state.debugCaptureEpoch,
                   let startNanoseconds = state.debugCaptureStartNanoseconds
                {
                    debugCaptureRecorder.record(
                        stageName: state.debugCaptureStageName,
                        sanitizedDimensions: renderedDimensions.isEmpty ? state.debugCaptureDimensions : renderedDimensions.logDescription,
                        captureEpoch: captureEpoch,
                        startNanoseconds: startNanoseconds
                    )
                }
            #endif
            if let signpostState = state.signpostState {
                signposter.endInterval(name, signpostState)
            }
        }

        public static func event(_ name: StaticString) {
            guard isEnabled else { return }
            signposter.emitEvent(name)
        }

        public static func event(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) {
            guard isEnabled else { return }
            logDimensions(dimensions())
            signposter.emitEvent(name)
        }

        public static func makeLifecycleCorrelationIfActive(
            requestIdentity: MCPRequestTimelineIdentity? = MCPRequestTimelineContext.current
        ) -> LifecycleCorrelation? {
            #if DEBUG
                let captureEpoch = debugCaptureRecorder.activeEpochIfActive()
                guard isEnabled || captureEpoch != nil else { return nil }
                return LifecycleCorrelation(
                    id: UUID(),
                    captureEpoch: captureEpoch,
                    requestIdentity: requestIdentity
                )
            #else
                guard isEnabled else { return nil }
                return LifecycleCorrelation(
                    id: UUID(),
                    captureEpoch: nil,
                    requestIdentity: requestIdentity
                )
            #endif
        }

        public static func lifecycleEvent(
            _ name: StaticString,
            correlation: LifecycleCorrelation? = currentLifecycleCorrelation,
            _ dimensions: @autoclosure () -> Dimensions = Dimensions()
        ) {
            guard let correlation else { return }
            #if DEBUG
                let shouldRecord = debugCaptureRecorder.shouldRecordLifecycleEvent(correlation)
                guard isEnabled || shouldRecord else { return }
            #else
                guard isEnabled else { return }
            #endif
            let renderedDimensions = dimensions()
            if isEnabled {
                logDimensions(renderedDimensions)
                signposter.emitEvent(name)
            }
            #if DEBUG
                if shouldRecord {
                    debugCaptureRecorder.recordLifecycleEvent(
                        eventName: String(describing: name),
                        correlation: correlation,
                        sanitizedDimensions: renderedDimensions.logDescription
                    )
                }
            #endif
        }

        public static func measure<T>(
            _ name: StaticString,
            operation: () throws -> T
        ) rethrows -> T {
            let state = begin(name)
            defer { end(name, state) }
            return try operation()
        }

        public static func measure<T>(
            _ name: StaticString,
            _ dimensions: @autoclosure () -> Dimensions,
            operation: () throws -> T
        ) rethrows -> T {
            let state = begin(name, dimensions())
            defer { end(name, state) }
            return try operation()
        }

        public static func measure<T>(
            _ name: StaticString,
            operation: () async throws -> T
        ) async rethrows -> T {
            let state = begin(name)
            defer { end(name, state) }
            return try await operation()
        }

        public static func measure<T>(
            _ name: StaticString,
            _ dimensions: @autoclosure () -> Dimensions,
            operation: () async throws -> T
        ) async rethrows -> T {
            let state = begin(name, dimensions())
            defer { end(name, state) }
            return try await operation()
        }

        private static func logDimensions(_ dimensions: Dimensions) {
            guard !dimensions.isEmpty else { return }
            logger.debug("dimensions \(dimensions.logDescription, privacy: .public)")
        }
    #else
        public static var isEnabled: Bool {
            false
        }

        @discardableResult
        @inline(__always)
        public static func begin(_ name: StaticString) -> IntervalState? {
            nil
        }

        @discardableResult
        @inline(__always)
        public static func begin(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) -> IntervalState? {
            nil
        }

        @inline(__always)
        public static func end(_ name: StaticString, _ state: IntervalState?) {}

        @inline(__always)
        public static func end(_ name: StaticString, _ state: IntervalState?, _ dimensions: @autoclosure () -> Dimensions) {}

        @inline(__always)
        public static func event(_ name: StaticString) {}

        @inline(__always)
        public static func event(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) {}

        @inline(__always)
        public static func makeLifecycleCorrelationIfActive() -> LifecycleCorrelation? {
            nil
        }

        @inline(__always)
        public static func lifecycleEvent(
            _ name: StaticString,
            correlation: LifecycleCorrelation? = currentLifecycleCorrelation,
            _ dimensions: @autoclosure () -> Dimensions = Dimensions()
        ) {}

        @inline(__always)
        public static func measure<T>(
            _ name: StaticString,
            operation: () throws -> T
        ) rethrows -> T {
            try operation()
        }

        @inline(__always)
        public static func measure<T>(
            _ name: StaticString,
            _ dimensions: @autoclosure () -> Dimensions,
            operation: () throws -> T
        ) rethrows -> T {
            try operation()
        }

        /// Compatibility barrier for https://github.com/repoprompt/repoprompt-ce/issues/301.
        /// The deterministic macOS 14 release crash unwinds through these generic async passthroughs
        /// around MCP limiter and TaskLocal scopes. Preserve a non-inlined boundary pending Sonoma
        /// verification and resolution of the underlying compiler/runtime interaction. The reported
        /// stack is distinct from https://github.com/swiftlang/swift/issues/86204: no `Task.sleep`
        /// specialization is present.
        @inline(never)
        public static func measure<T>(
            _ name: StaticString,
            operation: () async throws -> T
        ) async rethrows -> T {
            try await operation()
        }

        // Keep the dimensions overload behind the same issue #301 optimizer barrier.
        @inline(never)
        public static func measure<T>(
            _ name: StaticString,
            _ dimensions: @autoclosure () -> Dimensions,
            operation: () async throws -> T
        ) async rethrows -> T {
            try await operation()
        }
    #endif
}
