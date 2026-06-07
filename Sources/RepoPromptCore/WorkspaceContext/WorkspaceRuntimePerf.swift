import Foundation

private final class WorkspaceRuntimeProcessDiagnostics: @unchecked Sendable {
    static let shared = WorkspaceRuntimeProcessDiagnostics()

    private let lock = NSLock()
    private var sink: (any WorkspaceRuntimeDiagnosticsSink)?

    func install(_ sink: any WorkspaceRuntimeDiagnosticsSink) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func current() -> (any WorkspaceRuntimeDiagnosticsSink)? {
        lock.lock()
        defer { lock.unlock() }
        return sink
    }
}

/// Foundation-only diagnostic vocabulary for the shared runtime. The app may
/// install an injected sink around runtime entry points; Core owns no signposter.
package enum WorkspaceRuntimePerf {
    package struct LifecycleCorrelation {
        let id: UUID
        init(id: UUID = UUID()) {
            self.id = id
        }
    }

    @TaskLocal static var currentLifecycleCorrelation: LifecycleCorrelation?
    @TaskLocal static var currentFileSystemPublicationCorrelation: LifecycleCorrelation?
    @TaskLocal static var currentSink: (any WorkspaceRuntimeDiagnosticsSink)?

    package static var activeSink: (any WorkspaceRuntimeDiagnosticsSink)? {
        currentSink ?? WorkspaceRuntimeProcessDiagnostics.shared.current()
    }

    package static func installProcessSink(_ sink: any WorkspaceRuntimeDiagnosticsSink) {
        WorkspaceRuntimeProcessDiagnostics.shared.install(sink)
    }

    package static func withLifecycleCorrelation<T>(
        id: UUID?,
        operation: () async throws -> T
    ) async rethrows -> T {
        guard let id else { return try await operation() }
        return try await $currentLifecycleCorrelation.withValue(LifecycleCorrelation(id: id)) {
            try await operation()
        }
    }

    package struct IntervalState {
        let correlationID: UUID?
        let intervalID: UUID
    }

    package struct Dimensions {
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

        init(
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
            barrierSequence: UInt64? = nil
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

    package enum Stage {
        enum MCPToolCall {
            static let total: StaticString = "EditFlow.MCPToolCall.Total"
            static let normalizeArgs: StaticString = "EditFlow.MCPToolCall.NormalizeArgs"
            static let logicalContextResolution: StaticString = "EditFlow.MCPToolCall.LogicalContextResolution"
            static let policyGating: StaticString = "EditFlow.MCPToolCall.PolicyGating"
            static let effectivePolicySnapshot: StaticString = "EditFlow.MCPToolCall.EffectivePolicySnapshot"
            static let routingSnapshot: StaticString = "EditFlow.MCPToolCall.RoutingSnapshot"
            static let preLimiterEnvelope: StaticString = "EditFlow.MCPToolCall.PreLimiterEnvelope"
            static let limiterResolution: StaticString = "EditFlow.MCPToolCall.LimiterResolution"
            static let limiterEnvelope: StaticString = "EditFlow.MCPToolCall.LimiterEnvelope"
            static let limiterWait: StaticString = "EditFlow.MCPToolCall.LimiterWait"
            static let permitBodyEnvelope: StaticString = "EditFlow.MCPToolCall.PermitBodyEnvelope"
            static let permitPreDispatchEnvelope: StaticString = "EditFlow.MCPToolCall.PermitPreDispatchEnvelope"
            static let enabledStateSnapshot: StaticString = "EditFlow.MCPToolCall.EnabledStateSnapshot"
            static let windowRunResolution: StaticString = "EditFlow.MCPToolCall.WindowRunResolution"
            static let observerCallbacks: StaticString = "EditFlow.MCPToolCall.ObserverCallbacks"
            static let ownershipPurposeResolution: StaticString = "EditFlow.MCPToolCall.OwnershipPurposeResolution"
            static let toolCallRecording: StaticString = "EditFlow.MCPToolCall.ToolCallRecording"
            static let runScopedTabRebindFallback: StaticString = "EditFlow.MCPToolCall.RunScopedTabRebindFallback"
            static let legacyTabBindingCompatibility: StaticString = "EditFlow.MCPToolCall.LegacyTabBindingCompatibility"
            static let serviceToolLookup: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup"
            static let serviceToolLookupServiceToolsAwait: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.ServiceToolsAwait"
            static let serviceToolLookupToolDefinitionScan: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.ToolDefinitionScan"
            static let serviceToolLookupPublicWindowIDInjection: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.PublicWindowIDInjection"
            static let serviceToolLookupAppSettingsToolsBuild: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.AppSettingsToolsBuild"
            static let serviceToolLookupWindowRoutingToolsCacheActorBody: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.WindowRoutingToolsCacheActorBody"
            static let serviceToolLookupWindowCatalogToolsActorBodyTotal: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsActorBodyTotal"
            static let serviceToolLookupWindowCatalogToolsMaterialization: StaticString = "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsMaterialization"
            static let dispatch: StaticString = "EditFlow.MCPToolCall.Dispatch"
            static let resolvedProviderDispatch: StaticString = "EditFlow.MCPToolCall.ResolvedProviderDispatch"
            static let handlerResultHandoff: StaticString = "EditFlow.MCPToolCall.HandlerResultHandoff"
            static let permitPostDispatchEnvelope: StaticString = "EditFlow.MCPToolCall.PermitPostDispatchEnvelope"
            static let completionObservers: StaticString = "EditFlow.MCPToolCall.CompletionObservers"
            static let completionObserverResultEncoding: StaticString = "EditFlow.MCPToolCall.CompletionObserverResultEncoding"
            static let completionObserverCallbacks: StaticString = "EditFlow.MCPToolCall.CompletionObserverCallbacks"
            static let preToolFilesystemFlush: StaticString = "EditFlow.MCPToolCall.PreToolFilesystemFlush"
            static let runToolSetup: StaticString = "EditFlow.MCPToolCall.RunToolSetup"
            static let runToolRegistration: StaticString = "EditFlow.MCPToolCall.RunToolRegistration"
            static let providerExecution: StaticString = "EditFlow.MCPToolCall.ProviderExecution"
            static let runToolTimeoutEnvelope: StaticString = "EditFlow.MCPToolCall.RunToolTimeoutEnvelope"
            static let runToolCompletionCleanup: StaticString = "EditFlow.MCPToolCall.RunToolCompletionCleanup"
            static let formatResult: StaticString = "EditFlow.MCPToolCall.FormatResult"
        }

        enum MCPWindowToolCatalog {
            static let construction: StaticString = "EditFlow.MCPWindowToolCatalog.Construction"
            static let invalidateToolsCache: StaticString = "EditFlow.MCPWindowToolCatalog.InvalidateToolsCache"
            static let invalidationToolSummariesChange: StaticString = "EditFlow.MCPWindowToolCatalog.Invalidation.ToolSummariesChange"
            static let invalidationToolRegistrationUpdate: StaticString = "EditFlow.MCPWindowToolCatalog.Invalidation.ToolRegistrationUpdate"
            static let registrationUpdateWindowToolsEnabledDidSet: StaticString = "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.WindowToolsEnabledDidSet"
            static let registrationUpdateAgentBootstrap: StaticString = "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.AgentBootstrap"
            static let readinessWarmAccess: StaticString = "EditFlow.MCPWindowToolCatalog.ReadinessWarmAccess"
            static let serviceRegistryToolsPublication: StaticString = "EditFlow.MCPWindowToolCatalog.ServiceRegistryToolsPublication"
            static let codexTurnMCPServerEnable: StaticString = "EditFlow.MCPWindowToolCatalog.CodexTurnMCPServerEnable"
        }

        enum ApplyEdits {
            static let serviceRun: StaticString = "EditFlow.ApplyEdits.ServiceRun"
            static let servicePreview: StaticString = "EditFlow.ApplyEdits.ServicePreview"
            static let requestBuild: StaticString = "EditFlow.ApplyEdits.RequestBuild"
            static let hostRead: StaticString = "EditFlow.ApplyEdits.HostRead"
            static let hostWrite: StaticString = "EditFlow.ApplyEdits.HostWrite"
            static let engineApply: StaticString = "EditFlow.ApplyEdits.EngineApply"
            static let diffGeneration: StaticString = "EditFlow.ApplyEdits.DiffGeneration"
            static let patchApply: StaticString = "EditFlow.ApplyEdits.PatchApply"
            static let toolCardDiff: StaticString = "EditFlow.ApplyEdits.ToolCardDiff"
            static let format: StaticString = "EditFlow.ApplyEdits.Format"
            static let formatDecode: StaticString = "EditFlow.ApplyEdits.FormatDecode"
            static let formatMarkdown: StaticString = "EditFlow.ApplyEdits.FormatMarkdown"
            static let formatResource: StaticString = "EditFlow.ApplyEdits.FormatResource"
            static let approvalWait: StaticString = "EditFlow.ApplyEdits.ApprovalWait"
            static let flushDeltas: StaticString = "EditFlow.ApplyEdits.FlushDeltas"
        }

        enum Search {
            static let broadAdmissionWait: StaticString = "EditFlow.Search.BroadAdmissionWait"
            static let broadAdmissionLeaseHold: StaticString = "EditFlow.Search.BroadAdmissionLeaseHold"
            static let contentFetchAdmissionWait: StaticString = "EditFlow.Search.ContentFetchAdmissionWait"
            static let contentFetchLeaseHold: StaticString = "EditFlow.Search.ContentFetchLeaseHold"
            static let ingressFreshnessWait: StaticString = "EditFlow.Search.IngressFreshnessWait"
            static let contentFreshnessValidation: StaticString = "EditFlow.Search.ContentFreshnessValidation"
            static let contentFreshnessValidationStoreActorBody: StaticString = "EditFlow.Search.ContentFreshnessValidation.StoreActorBody"
            static let contentFreshnessValidationRootActorBody: StaticString = "EditFlow.Search.ContentFreshnessValidation.RootActorBody"
            static let contentScanTotal: StaticString = "EditFlow.Search.ContentScanTotal"
            static let resultConstruction: StaticString = "EditFlow.Search.ResultConstruction"
            static let entrypoint: StaticString = "EditFlow.Search.Entrypoint"
            static let scopeFiltering: StaticString = "EditFlow.Search.ScopeFiltering"
            static let actorSearchCall: StaticString = "EditFlow.Search.ActorSearchCall"
            static let actorSearchUnified: StaticString = "EditFlow.Search.ActorSearchUnified"
            static let contentBatch: StaticString = "EditFlow.Search.ContentBatch"
            static let pathBatch: StaticString = "EditFlow.Search.PathBatch"
            static let fileContentFetch: StaticString = "EditFlow.Search.FileContentFetch"
            static let lineIndexCacheKey: StaticString = "EditFlow.Search.LineIndexCacheKey"
            static let lineIndexLookup: StaticString = "EditFlow.Search.LineIndexLookup"
            static let lineIndexBuild: StaticString = "EditFlow.Search.LineIndexBuild"
            static let countOnlyFastPath: StaticString = "EditFlow.Search.CountOnlyFastPath"
            static let regexFullBufferScan: StaticString = "EditFlow.Search.RegexFullBufferScan"
            static let regexLineByLineScan: StaticString = "EditFlow.Search.RegexLineByLineScan"
            static let literalScan: StaticString = "EditFlow.Search.LiteralScan"
            static let materializeMatches: StaticString = "EditFlow.Search.MaterializeMatches"
            static let catalogSnapshot: StaticString = "EditFlow.Search.CatalogSnapshot"
            static let dtoBuild: StaticString = "EditFlow.Search.DTOBuild"
            static let dtoRootRefSnapshotLookup: StaticString = "EditFlow.Search.DTOBuild.RootRefSnapshotLookup"
            static let dtoDisplayResolverPreparation: StaticString = "EditFlow.Search.DTOBuild.DisplayResolverPreparation"
            static let dtoPathDisplayProjection: StaticString = "EditFlow.Search.DTOBuild.PathDisplayProjection"
            static let dtoCapAccounting: StaticString = "EditFlow.Search.DTOBuild.CapAccounting"
            static let dtoAssembly: StaticString = "EditFlow.Search.DTOBuild.Assembly"
            static let providerTotal: StaticString = "EditFlow.Search.ProviderTotal"
            static let providerWorkspaceSearchAwait: StaticString = "EditFlow.Search.ProviderWorkspaceSearchAwait"
            static let providerAutoSelection: StaticString = "EditFlow.Search.ProviderAutoSelection"
            static let providerValueEncoding: StaticString = "EditFlow.Search.ProviderValueEncoding"

            enum AutoSelect {
                static let shapeEligibility: StaticString = "EditFlow.Search.AutoSelect.ShapeEligibility"
                static let agentEligibility: StaticString = "EditFlow.Search.AutoSelect.AgentEligibility"
                static let mutation: StaticString = "EditFlow.Search.AutoSelect.Mutation"
            }
        }

        enum ReadFile {
            static let providerTotal: StaticString = "EditFlow.ReadFile.ProviderTotal"
            static let providerArgumentParsing: StaticString = "EditFlow.ReadFile.ProviderArgumentParsing"
            static let providerRequestMetadata: StaticString = "EditFlow.ReadFile.ProviderRequestMetadata"
            static let providerLookupContextResolution: StaticString = "EditFlow.ReadFile.ProviderLookupContextResolution"
            static let providerPathTranslation: StaticString = "EditFlow.ReadFile.ProviderPathTranslation"
            static let providerReadEnvelope: StaticString = "EditFlow.ReadFile.ProviderReadEnvelope"
            static let providerReplyProjection: StaticString = "EditFlow.ReadFile.ProviderReplyProjection"
            static let providerAutoSelect: StaticString = "EditFlow.ReadFile.ProviderAutoSelect"
            static let providerValueEncoding: StaticString = "EditFlow.ReadFile.ProviderValueEncoding"
            static let explicitIngressFreshnessWait: StaticString = "EditFlow.ReadFile.ExplicitIngressFreshnessWait"
            static let exactCatalogShortcut: StaticString = "EditFlow.ReadFile.ExactCatalogShortcut"
            static let storeReadContentForwardAwait: StaticString = "EditFlow.ReadFile.StoreReadContentForwardAwait"
            static let folderResolutionGeneralLookupFallback: StaticString = "EditFlow.ReadFile.FolderResolutionGeneralLookupFallback"
            static let pathLookupStaticSnapshotBuild: StaticString = "EditFlow.ReadFile.PathLookupStaticSnapshotBuild"
            static let resolveReadableFile: StaticString = "EditFlow.ReadFile.ResolveReadableFile"
            static let exactPathIssueDetection: StaticString = "EditFlow.ReadFile.ExactPathIssueDetection"
            static let rootRefsLookup: StaticString = "EditFlow.ReadFile.RootRefsLookup"
            static let folderResolution: StaticString = "EditFlow.ReadFile.FolderResolution"
            static let externalFolderGuard: StaticString = "EditFlow.ReadFile.ExternalFolderGuard"
            static let readableServiceResolution: StaticString = "EditFlow.ReadFile.ReadableServiceResolution"
            static let exactCatalogLookupAwait: StaticString = "EditFlow.ReadFile.ExactCatalogLookupAwait"
            static let exactCatalogLookupActorBody: StaticString = "EditFlow.ReadFile.ExactCatalogLookupActorBody"
            static let explicitMaterialization: StaticString = "EditFlow.ReadFile.ExplicitMaterialization"
            static let generalLookupFallback: StaticString = "EditFlow.ReadFile.GeneralLookupFallback"
            static let externalFileFallback: StaticString = "EditFlow.ReadFile.ExternalFileFallback"
            static let workspaceContentLoad: StaticString = "EditFlow.ReadFile.WorkspaceContentLoad"
            static let splitPreservingLineEndings: StaticString = "EditFlow.ReadFile.SplitPreservingLineEndings"
            static let buildSlice: StaticString = "EditFlow.ReadFile.BuildSlice"

            enum AutoSelect {
                static let total: StaticString = "EditFlow.ReadFile.AutoSelect.Total"
                static let eligibilityResolution: StaticString = "EditFlow.ReadFile.AutoSelect.EligibilityResolution"
                static let selectionProjection: StaticString = "EditFlow.ReadFile.AutoSelect.SelectionProjection"
                static let fullFlowTotal: StaticString = "EditFlow.ReadFile.AutoSelect.FullFlowTotal"
                static let fullRequestMetadata: StaticString = "EditFlow.ReadFile.AutoSelect.FullRequestMetadata"
                static let fullLookupContext: StaticString = "EditFlow.ReadFile.AutoSelect.FullLookupContext"
                static let fullSnapshotResolution: StaticString = "EditFlow.ReadFile.AutoSelect.FullSnapshotResolution"
                static let structuralAddTotal: StaticString = "EditFlow.ReadFile.AutoSelect.StructuralAddTotal"
                static let candidateResolutionTotal: StaticString = "EditFlow.ReadFile.AutoSelect.CandidateResolutionTotal"
                static let structuralMerge: StaticString = "EditFlow.ReadFile.AutoSelect.StructuralMerge"
                static let autoCodemapRecomputeTotal: StaticString = "EditFlow.ReadFile.AutoSelect.AutoCodemapRecomputeTotal"
                static let selectedFileLookup: StaticString = "EditFlow.ReadFile.AutoSelect.SelectedFileLookup"
                static let codemapAPILoad: StaticString = "EditFlow.ReadFile.AutoSelect.CodemapAPILoad"

                enum AllCodemapFileAPIs {
                    static let actorBodyTotal: StaticString = "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.ActorBodyTotal"
                    static let stateSnapshot: StaticString = "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.StateSnapshot"
                    static let materialization: StaticString = "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.Materialization"
                }

                static let referencedPathResolution: StaticString = "EditFlow.ReadFile.AutoSelect.ReferencedPathResolution"
                static let acceptedFileAPIFilter: StaticString = "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter"

                enum AcceptedFileAPIFilter {
                    static let pathGrouping: StaticString = "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter.PathGrouping"
                    static let selectedRecordProjection: StaticString = "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter.SelectedRecordProjection"
                }

                static let autoReferencedAPIComputation: StaticString = "EditFlow.ReadFile.AutoSelect.AutoReferencedAPIComputation"
                static let fullSliceClearing: StaticString = "EditFlow.ReadFile.AutoSelect.FullSliceClearing"
                static let finalSelectionEquality: StaticString = "EditFlow.ReadFile.AutoSelect.FinalSelectionEquality"
                static let persistence: StaticString = "EditFlow.ReadFile.AutoSelect.Persistence"
                static let responseEnqueue: StaticString = "EditFlow.ReadFile.AutoSelect.ResponseEnqueue"
                static let canonicalQueueWait: StaticString = "EditFlow.ReadFile.AutoSelect.CanonicalQueueWait"
                static let canonicalMutation: StaticString = "EditFlow.ReadFile.AutoSelect.CanonicalMutation"
                static let canonicalStoredCommit: StaticString = "EditFlow.ReadFile.AutoSelect.CanonicalStoredCommit"
                static let mirrorEnqueue: StaticString = "EditFlow.ReadFile.AutoSelect.MirrorEnqueue"
                static let mirrorQueueWait: StaticString = "EditFlow.ReadFile.AutoSelect.MirrorQueueWait"
                static let mirrorApply: StaticString = "EditFlow.ReadFile.AutoSelect.MirrorApply"
                static let drainWait: StaticString = "EditFlow.ReadFile.AutoSelect.DrainWait"
                static let sliceFlowTotal: StaticString = "EditFlow.ReadFile.AutoSelect.SliceFlowTotal"
            }
        }

        enum FileSystem {
            static let contentLoadTotal: StaticString = "EditFlow.FileSystem.ContentLoadTotal"
            static let contentLoadActorBody: StaticString = "EditFlow.FileSystem.ContentLoadActorBody"
            static let contentReadRequestPreparation: StaticString = "EditFlow.FileSystem.ContentReadRequestPreparation"
            static let contentReadOffActorAwait: StaticString = "EditFlow.FileSystem.ContentReadOffActorAwait"
            static let contentModificationDateLookup: StaticString = "EditFlow.FileSystem.ContentModificationDateLookup"
            static let contentReadWorkerPermitWait: StaticString = "EditFlow.FileSystem.ContentReadWorkerPermitWait"
            static let contentReadWorkerBody: StaticString = "EditFlow.FileSystem.ContentReadWorkerBody"
        }

        enum Bootstrap {
            static let handshakeIOQueueEnvelope: StaticString = "EditFlow.Bootstrap.HandshakeIOQueueEnvelope"
            static let handshakeIOBlockingRead: StaticString = "EditFlow.Bootstrap.HandshakeIOBlockingRead"
            static let admission: StaticString = "EditFlow.Bootstrap.Admission"
            static let postAcceptStartup: StaticString = "EditFlow.Bootstrap.PostAcceptStartup"
        }

        enum WorkspaceDurability {
            static let flushWait: StaticString = "EditFlow.WorkspaceDurability.FlushWait"
            static let atomicWrite: StaticString = "EditFlow.WorkspaceDurability.AtomicWrite"
        }

        enum Transcript {
            static let scheduleRefresh: StaticString = "EditFlow.Transcript.ScheduleRefresh"
            static let refreshTotal: StaticString = "EditFlow.Transcript.RefreshTotal"
            static let importTranscript: StaticString = "EditFlow.Transcript.ImportTranscript"
            static let incrementalImport: StaticString = "EditFlow.Transcript.IncrementalImport"
            static let payloadMap: StaticString = "EditFlow.Transcript.PayloadMap"
            static let sanitize: StaticString = "EditFlow.Transcript.Sanitize"
            static let projectionBuild: StaticString = "EditFlow.Transcript.ProjectionBuild"
            static let publish: StaticString = "EditFlow.Transcript.Publish"
            static let toolProcessing: StaticString = "EditFlow.Transcript.ToolProcessing"
        }

        enum Parser {
            static let chatContentParse: StaticString = "EditFlow.Parser.ChatContentParse"
            static let diffParseChanges: StaticString = "EditFlow.Parser.DiffParseChanges"
            static let diffRegexCacheLookup: StaticString = "EditFlow.Parser.DiffRegexCacheLookup"
        }

        enum Finalization {
            static let watchdogArm: StaticString = "EditFlow.Finalization.WatchdogArm"
            static let watchdogSkip: StaticString = "EditFlow.Finalization.WatchdogSkip"
            static let watchdogCancel: StaticString = "EditFlow.Finalization.WatchdogCancel"
            static let watchdogComplete: StaticString = "EditFlow.Finalization.WatchdogComplete"
        }

        enum UnifiedDiff {
            static let parseForRender: StaticString = "EditFlow.UnifiedDiff.ParseForRender"
            static let attributedBuild: StaticString = "EditFlow.UnifiedDiff.AttributedBuild"
        }

        enum Git {
            static let hunkParsing: StaticString = "EditFlow.Git.HunkParsing"
        }
    }

    package enum Lifecycle {
        enum MCPToolCall {
            static let received: StaticString = "MCP.ToolCall.Received"
            static let routingSnapshotCompleted: StaticString = "MCP.ToolCall.RoutingSnapshotCompleted"
            static let limiterWaitBegan: StaticString = "MCP.ToolCall.LimiterWaitBegan"
            static let limiterAcquired: StaticString = "MCP.ToolCall.LimiterAcquired"
            static let completionObserverReturned: StaticString = "MCP.ToolCall.CompletionObserverReturned"
            static let formatResultReturned: StaticString = "MCP.ToolCall.FormatResultReturned"
            static let resolvedProviderBegan: StaticString = "MCP.ToolCall.ResolvedProviderBegan"
            static let resolvedProviderEnded: StaticString = "MCP.ToolCall.ResolvedProviderEnded"
            static let handlerResultReady: StaticString = "MCP.ToolCall.HandlerResultReady"
        }

        enum MCPRunTool {
            static let preflushBegan: StaticString = "MCP.RunTool.PreflushBegan"
            static let preflushEnded: StaticString = "MCP.RunTool.PreflushEnded"
            static let registrationScheduled: StaticString = "MCP.RunTool.RegistrationScheduled"
            static let registrationMainActorEntered: StaticString = "MCP.RunTool.RegistrationMainActorEntered"
            static let registrationEnded: StaticString = "MCP.RunTool.RegistrationEnded"
            static let providerBegan: StaticString = "MCP.RunTool.ProviderBegan"
            static let providerEnded: StaticString = "MCP.RunTool.ProviderEnded"
            static let cleanupScheduled: StaticString = "MCP.RunTool.CleanupScheduled"
            static let cleanupMainActorEntered: StaticString = "MCP.RunTool.CleanupMainActorEntered"
            static let unregister: StaticString = "MCP.RunTool.Unregister"
            static let idleWaitersResumed: StaticString = "MCP.RunTool.IdleWaitersResumed"
            static let cleanupEnded: StaticString = "MCP.RunTool.CleanupEnded"
            static let returned: StaticString = "MCP.RunTool.Return"
        }

        enum FileSystem {
            static let callbackAccepted: StaticString = "FileSystem.CallbackAccepted"
            static let serviceEnqueueEntered: StaticString = "FileSystem.ServiceEnqueueEntered"
            static let servicePublish: StaticString = "FileSystem.ServicePublish"
            static let contentLoadEntered: StaticString = "FileSystem.ContentLoadEntered"
            static let contentReadRequestPrepared: StaticString = "FileSystem.ContentReadRequestPrepared"
            static let contentReadOffActorScheduled: StaticString = "FileSystem.ContentReadOffActorScheduled"
            static let contentReadWorkerReturned: StaticString = "FileSystem.ContentReadWorkerReturned"
            static let contentLoadReturned: StaticString = "FileSystem.ContentLoadReturned"
            static let contentReadWorkerPermitWaitBegan: StaticString = "FileSystem.ContentReadWorkerPermitWaitBegan"
            static let contentReadWorkerPermitAcquired: StaticString = "FileSystem.ContentReadWorkerPermitAcquired"
            static let contentReadWorkerPermitCancelled: StaticString = "FileSystem.ContentReadWorkerPermitCancelled"
        }

        enum Search {
            static let contentFreshnessStoreEntered: StaticString = "Search.ContentFreshnessStoreEntered"
            static let contentFreshnessStoreReturned: StaticString = "Search.ContentFreshnessStoreReturned"
            static let contentFreshnessRootEntered: StaticString = "Search.ContentFreshnessRootEntered"
            static let contentFreshnessRootReturned: StaticString = "Search.ContentFreshnessRootReturned"
            static let broadAdmissionWaitBegan: StaticString = "Search.BroadAdmissionWaitBegan"
            static let broadAdmissionPermitAcquired: StaticString = "Search.BroadAdmissionPermitAcquired"
            static let broadAdmissionPermitCancelled: StaticString = "Search.BroadAdmissionPermitCancelled"
            static let broadAdmissionPermitReleased: StaticString = "Search.BroadAdmissionPermitReleased"
            static let broadAdmissionOverloaded: StaticString = "Search.BroadAdmissionOverloaded"
            static let broadAdmissionWaitExpired: StaticString = "Search.BroadAdmissionWaitExpired"
            static let contentFetchWaitBegan: StaticString = "Search.ContentFetchWaitBegan"
            static let contentFetchPermitAcquired: StaticString = "Search.ContentFetchPermitAcquired"
            static let contentFetchPermitCancelled: StaticString = "Search.ContentFetchPermitCancelled"
            static let contentFetchPermitReleased: StaticString = "Search.ContentFetchPermitReleased"
            static let contentFetchOverloaded: StaticString = "Search.ContentFetchOverloaded"
            static let contentFetchWaitExpired: StaticString = "Search.ContentFetchWaitExpired"
            static let providerEntered: StaticString = "Search.ProviderEntered"
            static let providerWorkspaceSearchReturned: StaticString = "Search.ProviderWorkspaceSearchReturned"
            static let providerDTOReady: StaticString = "Search.ProviderDTOReady"
            static let providerAutoSelectionReturned: StaticString = "Search.ProviderAutoSelectionReturned"
            static let providerResultReady: StaticString = "Search.ProviderResultReady"
        }

        enum ReadFile {
            static let providerEntered: StaticString = "ReadFile.ProviderEntered"
            static let explicitFreshnessBegan: StaticString = "ReadFile.ExplicitFreshnessBegan"
            static let explicitFreshnessEnded: StaticString = "ReadFile.ExplicitFreshnessEnded"
            static let exactCatalogLookupResolved: StaticString = "ReadFile.ExactCatalogLookupResolved"
            static let exactCatalogShortcutResolved: StaticString = "ReadFile.ExactCatalogShortcutResolved"
            static let folderResolutionReturned: StaticString = "ReadFile.FolderResolutionReturned"
            static let readableServiceResolutionReturned: StaticString = "ReadFile.ReadableServiceResolutionReturned"
            static let storeReadContentEntered: StaticString = "ReadFile.StoreReadContentEntered"
            static let storeReadContentReturned: StaticString = "ReadFile.StoreReadContentReturned"
            static let providerResultReady: StaticString = "ReadFile.ProviderResultReady"
        }

        enum Bootstrap {
            static let socketAccepted: StaticString = "Bootstrap.SocketAccepted"
            static let handshakeIOQueued: StaticString = "Bootstrap.HandshakeIOQueued"
            static let handshakeIOBegan: StaticString = "Bootstrap.HandshakeIOBegan"
            static let handshakeIOEnded: StaticString = "Bootstrap.HandshakeIOEnded"
            static let admissionBegan: StaticString = "Bootstrap.AdmissionBegan"
            static let admissionEnded: StaticString = "Bootstrap.AdmissionEnded"
            static let acceptedResponseSent: StaticString = "Bootstrap.AcceptedResponseSent"
            static let ownershipTransferred: StaticString = "Bootstrap.OwnershipTransferred"
            static let postAcceptStartupBegan: StaticString = "Bootstrap.PostAcceptStartupBegan"
            static let postAcceptStartupEnded: StaticString = "Bootstrap.PostAcceptStartupEnded"
        }

        enum WorkspaceIngress {
            static let storeSinkScheduled: StaticString = "WorkspaceIngress.StoreSinkScheduled"
            static let storeSinkBegan: StaticString = "WorkspaceIngress.StoreSinkBegan"
            static let storeCanonicalApplyCompleted: StaticString = "WorkspaceIngress.StoreCanonicalApplyCompleted"
            static let rootFlushBegan: StaticString = "WorkspaceIngress.RootFlushBegan"
            static let rootFlushEnded: StaticString = "WorkspaceIngress.RootFlushEnded"
        }

        enum ReadFileAutoSelect {
            static let enqueueAccepted: StaticString = "ReadFile.AutoSelect.EnqueueAccepted"
            static let enqueueCoalesced: StaticString = "ReadFile.AutoSelect.EnqueueCoalesced"
            static let canonicalApplyBegan: StaticString = "ReadFile.AutoSelect.CanonicalApplyBegan"
            static let canonicalApplyEnded: StaticString = "ReadFile.AutoSelect.CanonicalApplyEnded"
            static let mirrorScheduled: StaticString = "ReadFile.AutoSelect.MirrorScheduled"
            static let mirrorCoalesced: StaticString = "ReadFile.AutoSelect.MirrorCoalesced"
            static let mirrorApplyBegan: StaticString = "ReadFile.AutoSelect.MirrorApplyBegan"
            static let mirrorApplyEnded: StaticString = "ReadFile.AutoSelect.MirrorApplyEnded"
            static let drainBegan: StaticString = "ReadFile.AutoSelect.DrainBegan"
            static let drainEnded: StaticString = "ReadFile.AutoSelect.DrainEnded"
        }

        enum WorkspaceDurability {
            static let flushBegan: StaticString = "WorkspaceDurability.FlushBegan"
            static let flushEnded: StaticString = "WorkspaceDurability.FlushEnded"
            static let writeBegan: StaticString = "WorkspaceDurability.WriteBegan"
            static let writeEnded: StaticString = "WorkspaceDurability.WriteEnded"
        }
    }

    @discardableResult
    package static func begin(
        _ name: StaticString,
        _ dimensions: @autoclosure () -> Dimensions = Dimensions()
    ) -> IntervalState? {
        guard let sink = activeSink else { return nil }
        let correlation = currentLifecycleCorrelation
        let intervalID = UUID()
        sink.record(WorkspaceRuntimeDiagnosticEvent(
            subsystem: subsystem(for: name),
            name: String(describing: name),
            kind: .intervalBegan,
            correlationID: correlation?.id,
            intervalID: intervalID,
            fields: diagnosticFields(dimensions())
        ))
        return IntervalState(correlationID: correlation?.id, intervalID: intervalID)
    }

    package static func end(
        _ name: StaticString,
        _ state: IntervalState?,
        _ dimensions: @autoclosure () -> Dimensions = Dimensions()
    ) {
        guard let sink = activeSink, let state else { return }
        sink.record(WorkspaceRuntimeDiagnosticEvent(
            subsystem: subsystem(for: name),
            name: String(describing: name),
            kind: .intervalEnded,
            correlationID: state.correlationID,
            intervalID: state.intervalID,
            fields: diagnosticFields(dimensions())
        ))
    }

    package static func makeLifecycleCorrelationIfActive() -> LifecycleCorrelation? {
        activeSink == nil ? nil : LifecycleCorrelation()
    }

    package static func measure<T>(
        _ name: StaticString,
        operation: () throws -> T
    ) rethrows -> T {
        let state = begin(name)
        defer { end(name, state) }
        return try operation()
    }

    package static func measure<T>(
        _ name: StaticString,
        _ dimensions: @autoclosure () -> Dimensions,
        operation: () throws -> T
    ) rethrows -> T {
        let state = begin(name, dimensions())
        defer { end(name, state) }
        return try operation()
    }

    package static func measure<T>(
        _ name: StaticString,
        operation: () async throws -> T
    ) async rethrows -> T {
        let state = begin(name)
        defer { end(name, state) }
        return try await operation()
    }

    package static func measure<T>(
        _ name: StaticString,
        _ dimensions: @autoclosure () -> Dimensions,
        operation: () async throws -> T
    ) async rethrows -> T {
        let state = begin(name, dimensions())
        defer { end(name, state) }
        return try await operation()
    }

    package static func lifecycleEvent(
        _ name: StaticString,
        correlation: LifecycleCorrelation? = currentLifecycleCorrelation,
        _ dimensions: @autoclosure () -> Dimensions = Dimensions()
    ) {
        guard let sink = activeSink else { return }
        sink.record(WorkspaceRuntimeDiagnosticEvent(
            subsystem: subsystem(for: name),
            name: String(describing: name),
            kind: .lifecycle,
            correlationID: correlation?.id,
            fields: diagnosticFields(dimensions())
        ))
    }

    package static func withSink<T>(
        _ sink: any WorkspaceRuntimeDiagnosticsSink,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentSink.withValue(sink) { try await operation() }
    }

    private static func diagnosticFields(_ dimensions: Dimensions) -> [String: String] {
        dimensions.logDescription.isEmpty ? [:] : ["dimensions": dimensions.logDescription]
    }

    private static func subsystem(for name: StaticString) -> String {
        String(describing: name).split(separator: ".").dropFirst().first.map(String.init) ?? "runtime"
    }
}
