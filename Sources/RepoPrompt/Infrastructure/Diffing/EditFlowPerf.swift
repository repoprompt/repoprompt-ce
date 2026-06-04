import Foundation
#if DEBUG
    import Synchronization
#endif
#if DEBUG || EDIT_FLOW_PERF
    import os
#endif

/// Lightweight, gated instrumentation for hot-path diagnostics.
///
/// Keep this utility safe for broad use:
/// - disabled by default and cheap on the fast path;
/// - stage names are static;
/// - dimensions are coarse counts/status labels only;
/// - never pass raw paths, patterns, replacement text, file content, or diffs.
enum EditFlowPerf {
    #if DEBUG || EDIT_FLOW_PERF
        struct IntervalState {
            let signpostState: OSSignpostIntervalState?
            #if DEBUG
                let debugCaptureEpoch: UInt64?
                let debugCaptureStartNanoseconds: UInt64?
                let debugCaptureStageName: String
                let debugCaptureDimensions: String
            #endif
        }
    #else
        struct IntervalState {}
    #endif

    struct Dimensions {
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
        var isError: Bool?
        var isForced: Bool?
        var isAgentMode: Bool?
        var includesToolCardDiff: Bool?
        var searchMode: String?
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
            isError: Bool? = nil,
            isForced: Bool? = nil,
            isAgentMode: Bool? = nil,
            includesToolCardDiff: Bool? = nil,
            searchMode: String? = nil,
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
            pendingRawEventCount: Int? = nil
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
            self.isError = isError
            self.isForced = isForced
            self.isAgentMode = isAgentMode
            self.includesToolCardDiff = includesToolCardDiff
            self.searchMode = Self.sanitizedLabel(searchMode)
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
            append("isError", isError, to: &parts)
            append("isForced", isForced, to: &parts)
            append("isAgentMode", isAgentMode, to: &parts)
            append("includesToolCardDiff", includesToolCardDiff, to: &parts)
            append("searchMode", searchMode, to: &parts)
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

        private func append(_ key: String, _ value: Bool?, to parts: inout [String]) {
            guard let value else { return }
            parts.append("\(key)=\(value ? "true" : "false")")
        }
    }

    enum Stage {
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
            static let permitPostDispatchEnvelope: StaticString = "EditFlow.MCPToolCall.PermitPostDispatchEnvelope"
            static let completionObservers: StaticString = "EditFlow.MCPToolCall.CompletionObservers"
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
                static let sliceFlowTotal: StaticString = "EditFlow.ReadFile.AutoSelect.SliceFlowTotal"
            }
        }

        enum FileSystem {
            static let contentLoadActorBody: StaticString = "EditFlow.FileSystem.ContentLoadActorBody"
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

    #if DEBUG
        struct DebugCaptureStageAggregate {
            let stageName: String
            let sanitizedDimensions: String
            let sampleCount: Int
            let p50MS: Double
            let p95MS: Double
            let maxMS: Double
            let totalMS: Double

            var payload: [String: Any] {
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

        struct DebugCaptureSnapshot {
            let label: String
            let active: Bool
            let startedAt: Date?
            let finishedAt: Date?
            let maxSamples: Int
            let retainedSampleCount: Int
            let droppedSampleCount: Int
            let stages: [DebugCaptureStageAggregate]

            var payload: [String: Any] {
                [
                    "label": label,
                    "active": active,
                    "started_at": startedAt?.timeIntervalSince1970 ?? NSNull(),
                    "finished_at": finishedAt?.timeIntervalSince1970 ?? NSNull(),
                    "max_samples": maxSamples,
                    "retained_sample_count": retainedSampleCount,
                    "dropped_sample_count": droppedSampleCount,
                    "stages": stages.map(\.payload)
                ]
            }
        }

        enum DebugCaptureBeginResult {
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

            init() {
                if #available(macOS 15.0, *) {
                    storage = AtomicStorage()
                } else {
                    storage = nil
                }
            }

            func loadIfAvailable() -> Bool? {
                if #available(macOS 15.0, *), let storage = storage as? AtomicStorage {
                    return storage.value.load(ordering: .acquiring)
                }
                return nil
            }

            func store(_ active: Bool) {
                if #available(macOS 15.0, *), let storage = storage as? AtomicStorage {
                    storage.value.store(active, ordering: .releasing)
                }
            }
        }

        private final class DebugCaptureRecorder {
            private static let sampleLimitRange = 100 ... 100_000

            private let lock = NSLock()
            private let activeHint = DebugCaptureActiveHint()
            private var active = false
            private var captureEpoch: UInt64 = 0
            private var label = ""
            private var startedAt: Date?
            private var finishedAt: Date?
            private var maxSamples = 20000
            private var retainedSampleCount = 0
            private var droppedSampleCount = 0
            private var samplesByKey: [DebugCaptureKey: [Double]] = [:]

            var isActive: Bool {
                if let active = activeHint.loadIfAvailable() {
                    return active
                }
                lock.lock()
                defer { lock.unlock() }
                return active
            }

            func begin(label: String, maxSamples: Int) -> DebugCaptureBeginResult {
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
                retainedSampleCount = 0
                droppedSampleCount = 0
                samplesByKey.removeAll(keepingCapacity: true)
                activeHint.store(true)
                return .started(snapshotLocked())
            }

            func snapshot(finish: Bool) -> DebugCaptureSnapshot {
                lock.lock()
                defer { lock.unlock() }
                if finish, active {
                    active = false
                    activeHint.store(false)
                    finishedAt = Date()
                }
                return snapshotLocked()
            }

            func resetForTesting() {
                lock.lock()
                active = false
                activeHint.store(false)
                label = ""
                startedAt = nil
                finishedAt = nil
                maxSamples = 20000
                retainedSampleCount = 0
                droppedSampleCount = 0
                samplesByKey.removeAll(keepingCapacity: false)
                lock.unlock()
            }

            func startTimestampIfActive() -> DebugCaptureStart? {
                if let active = activeHint.loadIfAvailable(), !active { return nil }
                lock.lock()
                defer { lock.unlock() }
                guard active else { return nil }
                return DebugCaptureStart(epoch: captureEpoch, startNanoseconds: DispatchTime.now().uptimeNanoseconds)
            }

            func record(stageName: String, sanitizedDimensions: String, captureEpoch: UInt64, startNanoseconds: UInt64) {
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
                    stages: stages
                )
            }

            private func nearestRank(_ sorted: [Double], percentile: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                let rank = Int(ceil(percentile * Double(sorted.count))) - 1
                return sorted[min(max(rank, 0), sorted.count - 1)]
            }
        }

        private static let debugCaptureRecorder = DebugCaptureRecorder()

        static var isDebugCaptureActive: Bool {
            debugCaptureRecorder.isActive
        }

        static func beginDebugCapture(label: String, maxSamples: Int) -> DebugCaptureBeginResult {
            debugCaptureRecorder.begin(label: label, maxSamples: maxSamples)
        }

        static func debugCaptureSnapshot(finish: Bool) -> DebugCaptureSnapshot {
            debugCaptureRecorder.snapshot(finish: finish)
        }

        static func resetDebugCaptureForTesting() {
            debugCaptureRecorder.resetForTesting()
        }
    #endif

    #if DEBUG || EDIT_FLOW_PERF
        private static let signposter = OSSignposter(subsystem: "com.repoprompt.edit-flow", category: "perf")
        private static let logger = Logger(subsystem: "com.repoprompt.edit-flow", category: "perf")
        private static let environmentEnabled: Bool = {
            guard let raw = ProcessInfo.processInfo.environment["REPOPROMPT_EDIT_FLOW_PERF"] else {
                return false
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "y", "on"].contains(value)
        }()

        static var isEnabled: Bool {
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
        static func begin(_ name: StaticString) -> IntervalState? {
            guard isEnabled || shouldCaptureIntervals else { return nil }
            return makeIntervalState(name, dimensions: Dimensions())
        }

        @discardableResult
        static func begin(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) -> IntervalState? {
            guard isEnabled || shouldCaptureIntervals else { return nil }
            let renderedDimensions = dimensions()
            if isEnabled {
                logDimensions(renderedDimensions)
            }
            return makeIntervalState(name, dimensions: renderedDimensions)
        }

        static func end(_ name: StaticString, _ state: IntervalState?) {
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

        static func end(_ name: StaticString, _ state: IntervalState?, _ dimensions: @autoclosure () -> Dimensions) {
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

        static func event(_ name: StaticString) {
            guard isEnabled else { return }
            signposter.emitEvent(name)
        }

        static func event(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) {
            guard isEnabled else { return }
            logDimensions(dimensions())
            signposter.emitEvent(name)
        }

        static func measure<T>(
            _ name: StaticString,
            operation: () throws -> T
        ) rethrows -> T {
            let state = begin(name)
            defer { end(name, state) }
            return try operation()
        }

        static func measure<T>(
            _ name: StaticString,
            _ dimensions: @autoclosure () -> Dimensions,
            operation: () throws -> T
        ) rethrows -> T {
            let state = begin(name, dimensions())
            defer { end(name, state) }
            return try operation()
        }

        static func measure<T>(
            _ name: StaticString,
            operation: () async throws -> T
        ) async rethrows -> T {
            let state = begin(name)
            defer { end(name, state) }
            return try await operation()
        }

        static func measure<T>(
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
        static var isEnabled: Bool {
            false
        }

        @discardableResult
        @inline(__always)
        static func begin(_ name: StaticString) -> IntervalState? {
            nil
        }

        @discardableResult
        @inline(__always)
        static func begin(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) -> IntervalState? {
            nil
        }

        @inline(__always)
        static func end(_ name: StaticString, _ state: IntervalState?) {}

        @inline(__always)
        static func end(_ name: StaticString, _ state: IntervalState?, _ dimensions: @autoclosure () -> Dimensions) {}

        @inline(__always)
        static func event(_ name: StaticString) {}

        @inline(__always)
        static func event(_ name: StaticString, _ dimensions: @autoclosure () -> Dimensions) {}

        @inline(__always)
        static func measure<T>(
            _ name: StaticString,
            operation: () throws -> T
        ) rethrows -> T {
            try operation()
        }

        @inline(__always)
        static func measure<T>(
            _ name: StaticString,
            _ dimensions: @autoclosure () -> Dimensions,
            operation: () throws -> T
        ) rethrows -> T {
            try operation()
        }

        @inline(__always)
        static func measure<T>(
            _ name: StaticString,
            operation: () async throws -> T
        ) async rethrows -> T {
            try await operation()
        }

        @inline(__always)
        static func measure<T>(
            _ name: StaticString,
            _ dimensions: @autoclosure () -> Dimensions,
            operation: () async throws -> T
        ) async rethrows -> T {
            try await operation()
        }
    #endif
}
