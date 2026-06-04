#if DEBUG
    @testable import RepoPrompt
    import XCTest

    final class MCPReadSearchLatencyDiagnosticsGuardTests: XCTestCase {
        override func tearDown() {
            EditFlowPerf.resetDebugCaptureForTesting()
            super.tearDown()
        }

        func testHiddenDispatcherRecognizesReadSearchCaptureOperations() throws {
            let diagnostics = try diagnosticsSource()
            XCTAssertTrue(diagnostics.contains("mcp_read_search_capture_begin"))
            XCTAssertTrue(diagnostics.contains("mcp_read_search_capture_snapshot"))

            let sibling = try source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift")
            XCTAssertTrue(sibling.contains("#if DEBUG"))
            XCTAssertTrue(sibling.contains("100 ... 100_000"))
        }

        func testExpectedAttributionStagesRemainPresent() throws {
            let perf = try source("Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift")
            for stage in [
                "EditFlow.MCPToolCall.PreToolFilesystemFlush",
                "EditFlow.MCPToolCall.EffectivePolicySnapshot",
                "EditFlow.MCPToolCall.RoutingSnapshot",
                "EditFlow.MCPToolCall.PreLimiterEnvelope",
                "EditFlow.MCPToolCall.LimiterResolution",
                "EditFlow.MCPToolCall.LimiterEnvelope",
                "EditFlow.MCPToolCall.LimiterWait",
                "EditFlow.MCPToolCall.PermitBodyEnvelope",
                "EditFlow.MCPToolCall.PermitPreDispatchEnvelope",
                "EditFlow.MCPToolCall.EnabledStateSnapshot",
                "EditFlow.MCPToolCall.WindowRunResolution",
                "EditFlow.MCPToolCall.OwnershipPurposeResolution",
                "EditFlow.MCPToolCall.ToolCallRecording",
                "EditFlow.MCPToolCall.RunScopedTabRebindFallback",
                "EditFlow.MCPToolCall.LegacyTabBindingCompatibility",
                "EditFlow.MCPToolCall.ServiceToolLookup",
                "EditFlow.MCPToolCall.ServiceToolLookup.ServiceToolsAwait",
                "EditFlow.MCPToolCall.ServiceToolLookup.ToolDefinitionScan",
                "EditFlow.MCPToolCall.ServiceToolLookup.PublicWindowIDInjection",
                "EditFlow.MCPToolCall.ServiceToolLookup.AppSettingsToolsBuild",
                "EditFlow.MCPToolCall.ServiceToolLookup.WindowRoutingToolsCacheActorBody",
                "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsActorBodyTotal",
                "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsMaterialization",
                "EditFlow.MCPWindowToolCatalog.Construction",
                "EditFlow.MCPWindowToolCatalog.InvalidateToolsCache",
                "EditFlow.MCPWindowToolCatalog.Invalidation.ToolSummariesChange",
                "EditFlow.MCPWindowToolCatalog.Invalidation.ToolRegistrationUpdate",
                "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.WindowToolsEnabledDidSet",
                "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.AgentBootstrap",
                "EditFlow.MCPWindowToolCatalog.ReadinessWarmAccess",
                "EditFlow.MCPWindowToolCatalog.ServiceRegistryToolsPublication",
                "EditFlow.MCPWindowToolCatalog.CodexTurnMCPServerEnable",
                "EditFlow.MCPToolCall.PermitPostDispatchEnvelope",
                "EditFlow.MCPToolCall.CompletionObservers",
                "EditFlow.MCPToolCall.RunToolSetup",
                "EditFlow.MCPToolCall.RunToolRegistration",
                "EditFlow.MCPToolCall.ProviderExecution",
                "EditFlow.MCPToolCall.RunToolTimeoutEnvelope",
                "EditFlow.MCPToolCall.RunToolCompletionCleanup",
                "EditFlow.MCPToolCall.FormatResult",
                "EditFlow.ReadFile.ProviderTotal",
                "EditFlow.ReadFile.ProviderArgumentParsing",
                "EditFlow.ReadFile.ProviderRequestMetadata",
                "EditFlow.ReadFile.ProviderLookupContextResolution",
                "EditFlow.ReadFile.ProviderPathTranslation",
                "EditFlow.ReadFile.ProviderReadEnvelope",
                "EditFlow.ReadFile.ProviderReplyProjection",
                "EditFlow.ReadFile.ProviderAutoSelect",
                "EditFlow.ReadFile.ProviderValueEncoding",
                "EditFlow.ReadFile.ResolveReadableFile",
                "EditFlow.ReadFile.ExactPathIssueDetection",
                "EditFlow.ReadFile.RootRefsLookup",
                "EditFlow.ReadFile.FolderResolution",
                "EditFlow.ReadFile.ExternalFolderGuard",
                "EditFlow.ReadFile.ReadableServiceResolution",
                "EditFlow.ReadFile.ExactCatalogLookupAwait",
                "EditFlow.ReadFile.ExactCatalogLookupActorBody",
                "EditFlow.ReadFile.ExplicitMaterialization",
                "EditFlow.ReadFile.GeneralLookupFallback",
                "EditFlow.ReadFile.ExternalFileFallback",
                "EditFlow.ReadFile.WorkspaceContentLoad",
                "EditFlow.ReadFile.SplitPreservingLineEndings",
                "EditFlow.ReadFile.BuildSlice",
                "EditFlow.Search.CatalogSnapshot",
                "EditFlow.Search.DTOBuild",
                "EditFlow.FileSystem.ContentLoadActorBody"
            ] {
                XCTAssertTrue(perf.contains(stage), "Missing attribution stage: \(stage)")
            }
        }

        func testMCPCallDispatchDecompositionHooksRemainScopedAndResolvedToolDirect() throws {
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            for hook in [
                "effectivePolicySnapshot",
                "routingSnapshot",
                "limiterWait",
                "windowRunResolution",
                "serviceToolLookup",
                "completionObservers"
            ] {
                XCTAssertTrue(manager.contains(hook), "Missing MCP call decomposition hook: \(hook)")
            }

            let limiterBegin = try XCTUnwrap(manager.range(of: "let limiterWaitState = EditFlowPerf.begin("))
            let withPermit = try XCTUnwrap(manager.range(of: "return await limiter.withPermit {", range: limiterBegin.upperBound ..< manager.endIndex))
            let limiterEnd = try XCTUnwrap(manager.range(of: "EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.limiterWait, limiterWaitState)", range: withPermit.upperBound ..< manager.endIndex))
            XCTAssertLessThan(limiterBegin.lowerBound, withPermit.lowerBound)
            XCTAssertLessThan(withPermit.lowerBound, limiterEnd.lowerBound)

            let lookupBegin = try XCTUnwrap(manager.range(of: "let serviceToolLookupState = EditFlowPerf.begin("))
            let directInvocation = try XCTUnwrap(manager.range(of: "toolDef.callAsFunction(effectiveArgs)", range: lookupBegin.upperBound ..< manager.endIndex))
            XCTAssertLessThan(lookupBegin.lowerBound, directInvocation.lowerBound)
            XCTAssertTrue(manager.contains("EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookup, serviceToolLookupState)"))
            XCTAssertFalse(manager.contains("service.call("))
        }

        func testMCPCallOuterEnvelopeHooksRemainNestedCloseOnceAndSanitized() throws {
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            let handlerStart = try XCTUnwrap(manager.range(of: "let totalState = EditFlowPerf.begin("))
            let handlerEnd = try XCTUnwrap(manager.range(of: "/// Update the enabled state", range: handlerStart.upperBound ..< manager.endIndex))
            let handler = String(manager[handlerStart.lowerBound ..< handlerEnd.lowerBound])

            var searchStart = handler.startIndex
            for hook in [
                "let totalState = EditFlowPerf.begin(",
                "let preLimiterEnvelopeState = EditFlowPerf.begin(",
                "EditFlowPerf.Stage.MCPToolCall.normalizeArgs",
                "EditFlowPerf.Stage.MCPToolCall.limiterResolution",
                "endPreLimiterEnvelopeIfNeeded()",
                "EditFlowPerf.Stage.MCPToolCall.limiterEnvelope",
                "let limiterWaitState = EditFlowPerf.begin(",
                "await limiter.withPermit {",
                "EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.limiterWait, limiterWaitState)",
                "EditFlowPerf.Stage.MCPToolCall.permitBodyEnvelope",
                "let permitPreDispatchEnvelopeState = EditFlowPerf.begin(",
                "EditFlowPerf.Stage.MCPToolCall.enabledStateSnapshot",
                "EditFlowPerf.Stage.MCPToolCall.windowRunResolution",
                "EditFlowPerf.Stage.MCPToolCall.observerCallbacks",
                "EditFlowPerf.Stage.MCPToolCall.ownershipPurposeResolution",
                "EditFlowPerf.Stage.MCPToolCall.toolCallRecording",
                "EditFlowPerf.Stage.MCPToolCall.runScopedTabRebindFallback",
                "EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility",
                "let serviceToolLookupState = EditFlowPerf.begin(",
                "toolDef.callAsFunction(effectiveArgs)",
                "EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope"
            ] {
                let match = try XCTUnwrap(handler.range(of: hook, range: searchStart ..< handler.endIndex), "Missing or out-of-order outer-envelope hook: \(hook)")
                searchStart = match.upperBound
            }

            XCTAssertEqual(handler.components(separatedBy: "endPreLimiterEnvelopeIfNeeded()").count - 1, 3)
            XCTAssertEqual(handler.components(separatedBy: "endPermitPreDispatchEnvelopeIfNeeded()").count - 1, 4)
            XCTAssertEqual(handler.components(separatedBy: "outcome: \"success\"").count - 1, 2)
            XCTAssertEqual(handler.components(separatedBy: "outcome: \"dispatchError\"").count - 1, 2)
            XCTAssertEqual(handler.components(separatedBy: "outcome: \"toolNotFound\"").count - 1, 1)
            XCTAssertEqual(handler.components(separatedBy: "outcome: shouldAttemptRunScopedTabRebindFallback ? \"attempted\" : \"skipped\"").count - 1, 1)
            XCTAssertEqual(handler.components(separatedBy: "outcome: shouldAttemptLegacyTabBindingCompatibility ? \"attempted\" : \"skipped\"").count - 1, 1)
            XCTAssertTrue(handler.contains("toolDef.callAsFunction(effectiveArgs)"))
            XCTAssertFalse(handler.contains("service.call("))
        }

        func testRoutinePerCallRunScopedTabRebindFallbackSkipClassifierRemainsNarrowlyWired() throws {
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            let handlerStart = try XCTUnwrap(manager.range(of: "let totalState = EditFlowPerf.begin("))
            let handlerEnd = try XCTUnwrap(manager.range(of: "/// Update the enabled state", range: handlerStart.upperBound ..< manager.endIndex))
            let handler = String(manager[handlerStart.lowerBound ..< handlerEnd.lowerBound])
            let decisionStart = try XCTUnwrap(handler.range(of: "let shouldAttemptRunScopedTabRebindFallback ="))
            let fallbackEnd = try XCTUnwrap(handler.range(of: "// Legacy compatibility: sticky tab binding via hidden _tabID", range: decisionStart.upperBound ..< handler.endIndex))
            let fallback = String(handler[decisionStart.lowerBound ..< fallbackEnd.lowerBound])
            let classifierCall = "Self.shouldSkipPerCallRunScopedTabRebindFallback(\n                                        toolName: toolName,\n                                        purpose: policy.purpose\n                                    )"

            XCTAssertEqual(handler.components(separatedBy: "Self.shouldSkipPerCallRunScopedTabRebindFallback(").count - 1, 1)
            XCTAssertTrue(fallback.contains("capturedTabID == nil"))
            XCTAssertTrue(fallback.contains("observerRunIDForCallbacksFinal != nil"))
            XCTAssertTrue(fallback.contains("chosenID != nil"))
            XCTAssertTrue(fallback.contains("&& !\(classifierCall)"))
            XCTAssertTrue(fallback.contains("outcome: shouldAttemptRunScopedTabRebindFallback ? \"attempted\" : \"skipped\""))
            XCTAssertTrue(fallback.contains("_ = await self.ensureTabBoundForRunIfPossible("))
            XCTAssertTrue(handler[fallbackEnd.lowerBound...].contains("EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility"))
            XCTAssertTrue(handler.contains("toolDef.callAsFunction(effectiveArgs)"))
            XCTAssertFalse(handler.contains("service.call("))
        }

        func testRunToolDecompositionHooksRemainScopedAndProviderExecutionIsDimensioned() throws {
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            for hook in [
                "runToolSetup",
                "runToolRegistration",
                "runToolTimeoutEnvelope",
                "runToolCompletionCleanup"
            ] {
                XCTAssertTrue(viewModel.contains(hook), "Missing runTool decomposition hook: \(hook)")
            }
            XCTAssertTrue(viewModel.contains("EditFlowPerf.Stage.MCPToolCall.providerExecution,\n                    EditFlowPerf.Dimensions(toolName: name)"))
            XCTAssertTrue(viewModel.contains("result = try await withThrowingTaskGroup(of: T.self)"))
            XCTAssertEqual(viewModel.components(separatedBy: "EditFlowPerf.Stage.MCPToolCall.runToolCompletionCleanup,").count - 1, 4)
        }

        func testNewReadDispatchStageRecorderCapturesToolDimensionAndFinishes() throws {
            _ = startedCapture(label: "dispatch-decomposition", maxSamples: 100)
            EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookup,
                EditFlowPerf.Dimensions(toolName: "read_file")
            ) {}

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            XCTAssertEqual(aggregate.stageName, "EditFlow.MCPToolCall.ServiceToolLookup")
            XCTAssertEqual(aggregate.sanitizedDimensions, "tool=read_file")
            XCTAssertEqual(aggregate.sampleCount, 1)
        }

        func testServiceToolLookupInnerAttributionRecorderUsesStaticEmptyDimensions() {
            _ = startedCapture(label: "service-tool-lookup-inner", maxSamples: 100)
            for stage in [
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupPublicWindowIDInjection,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupAppSettingsToolsBuild,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowRoutingToolsCacheActorBody,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsActorBodyTotal,
                EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsMaterialization
            ] {
                EditFlowPerf.measure(stage) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 7)
            XCTAssertEqual(
                Set(snapshot.stages.map(\.stageName)),
                Set([
                    "EditFlow.MCPToolCall.ServiceToolLookup.ServiceToolsAwait",
                    "EditFlow.MCPToolCall.ServiceToolLookup.ToolDefinitionScan",
                    "EditFlow.MCPToolCall.ServiceToolLookup.PublicWindowIDInjection",
                    "EditFlow.MCPToolCall.ServiceToolLookup.AppSettingsToolsBuild",
                    "EditFlow.MCPToolCall.ServiceToolLookup.WindowRoutingToolsCacheActorBody",
                    "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsActorBodyTotal",
                    "EditFlow.MCPToolCall.ServiceToolLookup.WindowCatalogToolsMaterialization"
                ])
            )
            XCTAssertTrue(snapshot.stages.allSatisfy(\.sanitizedDimensions.isEmpty))
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
        }

        func testServiceToolLookupInnerAttributionHooksRemainCompileGatedOwnedAndReleaseEquivalent() throws {
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            let lookupBegin = try XCTUnwrap(manager.range(of: "let serviceToolLookupState = EditFlowPerf.begin("))
            let directInvocation = try XCTUnwrap(manager.range(of: "try await toolDef.callAsFunction(effectiveArgs)", range: lookupBegin.upperBound ..< manager.endIndex))
            let lookup = String(manager[lookupBegin.lowerBound ..< directInvocation.lowerBound])

            var searchStart = lookup.startIndex
            for hook in [
                "let serviceToolsAwaitState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait)",
                "let serviceTools = await service.tools",
                "EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupServiceToolsAwait, serviceToolsAwaitState)",
                "let toolDefinitionScanState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan)",
                "guard let toolDef = serviceTools.first(where: { $0.name == toolName }) else {",
                "EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupToolDefinitionScan, toolDefinitionScanState)",
                "let publicWindowIDInjectionState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupPublicWindowIDInjection)",
                "let routingWindowID: Int? = {",
                "let selectedSchemaDeclaresWindowID =",
                "routingWindowID != nil",
                "capturedArguments[\"window_id\"] == nil",
                "capturedArgsForFormatter[\"window_id\"] == nil",
                "self.schemaDeclaresWindowID(schema: toolDef.inputSchema)",
                "schemaDeclaresWindowID: selectedSchemaDeclaresWindowID",
                "args: capturedArguments",
                "schemaDeclaresWindowID: selectedSchemaDeclaresWindowID",
                "args: capturedArgsForFormatter",
                "EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupPublicWindowIDInjection, publicWindowIDInjectionState)",
                "EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookup, serviceToolLookupState)"
            ] {
                let match = try XCTUnwrap(lookup.range(of: hook, range: searchStart ..< lookup.endIndex), "Missing or out-of-order ServiceToolLookup attribution hook: \(hook)")
                searchStart = match.upperBound
            }

            XCTAssertEqual(manager.components(separatedBy: "let serviceTools = await service.tools").count - 1, 1)
            XCTAssertEqual(manager.components(separatedBy: "guard let toolDef = serviceTools.first(where: { $0.name == toolName })").count - 1, 1)
            XCTAssertEqual(lookup.components(separatedBy: "self.schemaDeclaresWindowID(schema: toolDef.inputSchema)").count - 1, 1)
            XCTAssertEqual(lookup.components(separatedBy: "schemaDeclaresWindowID: selectedSchemaDeclaresWindowID").count - 1, 2)
            XCTAssertEqual(lookup.components(separatedBy: "args: capturedArguments").count - 1, 1)
            XCTAssertEqual(lookup.components(separatedBy: "args: capturedArgsForFormatter").count - 1, 1)
            XCTAssertEqual(manager.components(separatedBy: "try await toolDef.callAsFunction(effectiveArgs)").count - 1, 2)
            XCTAssertEqual(lookup.components(separatedBy: "serviceToolLookupServiceToolsAwait").count - 1, 2)
            XCTAssertEqual(lookup.components(separatedBy: "serviceToolLookupToolDefinitionScan").count - 1, 3)
            XCTAssertEqual(lookup.components(separatedBy: "serviceToolLookupPublicWindowIDInjection").count - 1, 2)
            XCTAssertGreaterThanOrEqual(lookup.components(separatedBy: "#if DEBUG || EDIT_FLOW_PERF").count - 1, 7)
            XCTAssertFalse(manager.contains("service.call("))

            let injectionHelperBegin = try XCTUnwrap(manager.range(of: "    private nonisolated func injectWindowIDIfNeeded("))
            let injectionHelperEnd = try XCTUnwrap(manager.range(of: "\n    func registerExpectedAgentPID", range: injectionHelperBegin.upperBound ..< manager.endIndex))
            let injectionHelper = String(manager[injectionHelperBegin.lowerBound ..< injectionHelperEnd.lowerBound])
            XCTAssertTrue(injectionHelper.contains("schemaDeclaresWindowID: Bool"))
            XCTAssertTrue(injectionHelper.contains("if args[\"window_id\"] != nil { return args }"))
            XCTAssertFalse(injectionHelper.contains("schema: JSONSchema"))

            let appSettings = try source("Sources/RepoPrompt/Infrastructure/MCP/AppSettingsMCPService.swift")
            XCTAssertEqual(appSettings.components(separatedBy: "serviceToolLookupAppSettingsToolsBuild").count - 1, 2)
            XCTAssertTrue(appSettings.contains("#if DEBUG || EDIT_FLOW_PERF\n                let appSettingsToolsBuildState"))
            XCTAssertTrue(appSettings.contains("return makeTools()"))

            let routing = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowRoutingService.swift")
            let toolsCacheStart = try XCTUnwrap(routing.range(of: "private actor ToolsCache"))
            let toolsCacheEnd = try XCTUnwrap(routing.range(of: "private extension Array", range: toolsCacheStart.upperBound ..< routing.endIndex))
            let toolsCache = String(routing[toolsCacheStart.lowerBound ..< toolsCacheEnd.lowerBound])
            XCTAssertEqual(routing.components(separatedBy: "serviceToolLookupWindowRoutingToolsCacheActorBody").count - 1, 2)
            XCTAssertTrue(toolsCache.contains("#if DEBUG || EDIT_FLOW_PERF"))
            XCTAssertTrue(toolsCache.contains("return tools"))

            let catalog = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolCatalogService.swift")
            XCTAssertEqual(catalog.components(separatedBy: "serviceToolLookupWindowCatalogToolsActorBodyTotal").count - 1, 2)
            XCTAssertEqual(catalog.components(separatedBy: "serviceToolLookupWindowCatalogToolsMaterialization").count - 1, 2)
            let cacheHitReturn = try XCTUnwrap(catalog.range(of: "if let toolsCache {\n                return toolsCache\n            }"))
            let materialization = try XCTUnwrap(catalog.range(of: "let materializationState = EditFlowPerf.begin(", range: cacheHitReturn.upperBound ..< catalog.endIndex))
            let providersGrouping = try XCTUnwrap(catalog.range(of: "var providersByGroup:", range: materialization.upperBound ..< catalog.endIndex))
            XCTAssertLessThan(cacheHitReturn.lowerBound, materialization.lowerBound)
            XCTAssertLessThan(materialization.lowerBound, providersGrouping.lowerBound)
            XCTAssertTrue(catalog.contains("#if DEBUG || EDIT_FLOW_PERF"))
            XCTAssertTrue(catalog.contains("toolsCache = built\n            return built"))
        }

        func testMCPWindowToolCatalogLifecycleAttributionRecorderUsesStaticEmptyDimensions() {
            _ = startedCapture(label: "window-tool-catalog-lifecycle", maxSamples: 100)
            for stage in [
                EditFlowPerf.Stage.MCPWindowToolCatalog.construction,
                EditFlowPerf.Stage.MCPWindowToolCatalog.invalidateToolsCache,
                EditFlowPerf.Stage.MCPWindowToolCatalog.invalidationToolSummariesChange,
                EditFlowPerf.Stage.MCPWindowToolCatalog.invalidationToolRegistrationUpdate,
                EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateWindowToolsEnabledDidSet,
                EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateAgentBootstrap,
                EditFlowPerf.Stage.MCPWindowToolCatalog.readinessWarmAccess,
                EditFlowPerf.Stage.MCPWindowToolCatalog.serviceRegistryToolsPublication,
                EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable
            ] {
                EditFlowPerf.measure(stage) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 9)
            XCTAssertEqual(
                Set(snapshot.stages.map(\.stageName)),
                Set([
                    "EditFlow.MCPWindowToolCatalog.Construction",
                    "EditFlow.MCPWindowToolCatalog.InvalidateToolsCache",
                    "EditFlow.MCPWindowToolCatalog.Invalidation.ToolSummariesChange",
                    "EditFlow.MCPWindowToolCatalog.Invalidation.ToolRegistrationUpdate",
                    "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.WindowToolsEnabledDidSet",
                    "EditFlow.MCPWindowToolCatalog.RegistrationUpdate.AgentBootstrap",
                    "EditFlow.MCPWindowToolCatalog.ReadinessWarmAccess",
                    "EditFlow.MCPWindowToolCatalog.ServiceRegistryToolsPublication",
                    "EditFlow.MCPWindowToolCatalog.CodexTurnMCPServerEnable"
                ])
            )
            XCTAssertTrue(snapshot.stages.allSatisfy(\.sanitizedDimensions.isEmpty))
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
        }

        func testMCPWindowToolCatalogLifecycleHooksRemainCompileGatedOwnedAndReleaseEquivalent() throws {
            let catalog = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolCatalogService.swift")
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            let readiness = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPToolCatalogReadiness.swift")
            let registry = try source("Sources/RepoPrompt/Infrastructure/MCP/ServiceRegistry.swift")
            let codexRunner = try source("Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/CodexIntegratedAgentModeRunner.swift")

            XCTAssertEqual(viewModel.components(separatedBy: "MCPWindowToolCatalogService(").count - 1, 1)
            XCTAssertTrue(viewModel.contains("private lazy var windowToolCatalogService = MCPWindowToolCatalogService("))
            XCTAssertEqual(catalog.components(separatedBy: "toolsCache = nil").count - 1, 1)
            XCTAssertEqual(catalog.components(separatedBy: "MCPWindowToolCatalog.construction").count - 1, 2)
            XCTAssertEqual(catalog.components(separatedBy: "MCPWindowToolCatalog.invalidateToolsCache").count - 1, 2)
            XCTAssertTrue(catalog.contains("self.windowID = windowID\n        self.providers = providers"))

            XCTAssertEqual(viewModel.components(separatedBy: "MCPWindowToolCatalog.invalidationToolSummariesChange").count - 1, 2)
            XCTAssertEqual(viewModel.components(separatedBy: "MCPWindowToolCatalog.invalidationToolRegistrationUpdate").count - 1, 2)
            XCTAssertEqual(viewModel.components(separatedBy: "MCPWindowToolCatalog.registrationUpdateWindowToolsEnabledDidSet").count - 1, 2)
            XCTAssertEqual(viewModel.components(separatedBy: "MCPWindowToolCatalog.registrationUpdateAgentBootstrap").count - 1, 2)
            XCTAssertEqual(viewModel.components(separatedBy: "self?.invalidateToolsCache()").count - 1, 1)
            XCTAssertEqual(viewModel.components(separatedBy: "windowToolCatalogService.invalidateToolsCache()").count - 1, 1)
            XCTAssertTrue(viewModel.contains("#else\n                Task { await updateToolRegistration() }"))
            XCTAssertEqual(viewModel.components(separatedBy: "await updateToolRegistration()").count - 1, 2)
            XCTAssertTrue(viewModel.contains("private func updateToolRegistration(invalidateCatalogBeforeUpdate: Bool = true) async {"))
            XCTAssertTrue(viewModel.contains("let invalidateCatalogBeforeUpdate = !windowToolsEnabled\n            || !ServiceRegistry.services.contains { service in\n                (service as AnyObject) === (windowToolCatalogService as AnyObject)\n            }"))
            XCTAssertEqual(viewModel.components(separatedBy: "await updateToolRegistration(invalidateCatalogBeforeUpdate:").count - 1, 1)
            XCTAssertTrue(viewModel.contains("await updateToolRegistration(invalidateCatalogBeforeUpdate: invalidateCatalogBeforeUpdate)\n        #if DEBUG || EDIT_FLOW_PERF\n            EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.registrationUpdateAgentBootstrap"))

            let bootstrapStart = try XCTUnwrap(viewModel.range(of: "func ensureServerReadyForAgentBootstrap() async {"))
            let predicate = try XCTUnwrap(viewModel.range(of: "let invalidateCatalogBeforeUpdate = !windowToolsEnabled", range: bootstrapStart.upperBound ..< viewModel.endIndex))
            let bootstrapEnable = try XCTUnwrap(viewModel.range(of: "if !windowToolsEnabled {\n            windowToolsEnabled = true\n        }", range: predicate.upperBound ..< viewModel.endIndex))
            let update = try XCTUnwrap(viewModel.range(of: "await updateToolRegistration(invalidateCatalogBeforeUpdate: invalidateCatalogBeforeUpdate)", range: bootstrapEnable.upperBound ..< viewModel.endIndex))
            let bootstrapEnd = try XCTUnwrap(viewModel.range(of: "    /// Disables tools for this window.", range: update.upperBound ..< viewModel.endIndex))
            let bootstrap = viewModel[bootstrapStart.lowerBound ..< bootstrapEnd.lowerBound]
            XCTAssertLessThan(predicate.lowerBound, bootstrapEnable.lowerBound)
            XCTAssertLessThan(bootstrapEnable.lowerBound, update.lowerBound)
            XCTAssertFalse(bootstrap.contains("return"))

            let helperStart = try XCTUnwrap(viewModel.range(of: "private func updateToolRegistration(invalidateCatalogBeforeUpdate: Bool = true) async {"))
            let policy = try XCTUnwrap(viewModel.range(of: "if invalidateCatalogBeforeUpdate {", range: helperStart.upperBound ..< viewModel.endIndex))
            let invalidate = try XCTUnwrap(viewModel.range(of: "invalidateToolsCache()", range: policy.upperBound ..< viewModel.endIndex))
            let enabled = try XCTUnwrap(viewModel.range(of: "if windowToolsEnabled {", range: invalidate.upperBound ..< viewModel.endIndex))
            let register = try XCTUnwrap(viewModel.range(of: "ServiceRegistry.register(windowToolCatalogService)", range: enabled.upperBound ..< viewModel.endIndex))
            let join = try XCTUnwrap(viewModel.range(of: "try await service.join(windowID: windowID)", range: register.upperBound ..< viewModel.endIndex))
            let enabledRefresh = try XCTUnwrap(viewModel.range(of: "await service.refreshState()", range: join.upperBound ..< viewModel.endIndex))
            let unregister = try XCTUnwrap(viewModel.range(of: "ServiceRegistry.unregister(windowToolCatalogService)", range: enabledRefresh.upperBound ..< viewModel.endIndex))
            let leave = try XCTUnwrap(viewModel.range(of: "await service.leave(windowID: windowID)", range: unregister.upperBound ..< viewModel.endIndex))
            let disabledRefresh = try XCTUnwrap(viewModel.range(of: "await service.refreshState()", range: leave.upperBound ..< viewModel.endIndex))
            XCTAssertLessThan(policy.lowerBound, invalidate.lowerBound)
            XCTAssertLessThan(invalidate.lowerBound, enabled.lowerBound)
            XCTAssertLessThan(enabled.lowerBound, register.lowerBound)
            XCTAssertLessThan(register.lowerBound, join.lowerBound)
            XCTAssertLessThan(join.lowerBound, enabledRefresh.lowerBound)
            XCTAssertLessThan(enabledRefresh.lowerBound, unregister.lowerBound)
            XCTAssertLessThan(unregister.lowerBound, leave.lowerBound)
            XCTAssertLessThan(leave.lowerBound, disabledRefresh.lowerBound)

            XCTAssertEqual(readiness.components(separatedBy: "MCPWindowToolCatalog.readinessWarmAccess").count - 1, 2)
            XCTAssertTrue(readiness.contains("_ = await mcpServer.windowMCPTools"))

            let dedupe = try XCTUnwrap(registry.range(of: "if _services.contains(where:"))
            let append = try XCTUnwrap(registry.range(of: "_services.append(service)", range: dedupe.upperBound ..< registry.endIndex))
            let publication = try XCTUnwrap(registry.range(of: "MCPWindowToolCatalog.serviceRegistryToolsPublication", range: append.upperBound ..< registry.endIndex))
            let broadcast = try XCTUnwrap(registry.range(of: "await ServerNetworkManager.shared.broadcastToolListChanged()", range: publication.upperBound ..< registry.endIndex))
            XCTAssertLessThan(dedupe.lowerBound, append.lowerBound)
            XCTAssertLessThan(append.lowerBound, publication.lowerBound)
            XCTAssertLessThan(publication.lowerBound, broadcast.lowerBound)
            XCTAssertEqual(registry.components(separatedBy: "MCPWindowToolCatalog.serviceRegistryToolsPublication").count - 1, 1)
            XCTAssertTrue(registry.contains("#else\n                await ToolAvailabilityStore.shared.registerTools(service.tools)"))

            let enable = try XCTUnwrap(codexRunner.range(of: "await mcpServerEnabler()"))
            let send = try XCTUnwrap(codexRunner.range(of: "let outcome = await codexCoordinator.sendCodexNativeMessage(", range: enable.upperBound ..< codexRunner.endIndex))
            XCTAssertLessThan(enable.lowerBound, send.lowerBound)
            XCTAssertEqual(codexRunner.components(separatedBy: "MCPWindowToolCatalog.codexTurnMCPServerEnable").count - 1, 2)
        }

        func testOuterEnvelopeRecorderCapturesCombinedToolAndSanitizedOutcomes() throws {
            _ = startedCapture(label: "outer-envelope", maxSamples: 100)
            EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.preLimiterEnvelope,
                EditFlowPerf.Dimensions(toolName: "read_file")
            ) {}
            for outcome in ["attempted", "skipped"] {
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.runScopedTabRebindFallback,
                    EditFlowPerf.Dimensions(toolName: "read_file", outcome: outcome)
                ) {}
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.legacyTabBindingCompatibility,
                    EditFlowPerf.Dimensions(toolName: "read_file", outcome: outcome)
                ) {}
            }
            for outcome in ["success", "dispatchError", "toolNotFound"] {
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.permitPostDispatchEnvelope,
                    EditFlowPerf.Dimensions(toolName: "read_file", outcome: outcome)
                ) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 8)

            let plain = try XCTUnwrap(snapshot.stages.first { $0.stageName == "EditFlow.MCPToolCall.PreLimiterEnvelope" })
            XCTAssertEqual(plain.sanitizedDimensions, "tool=read_file")
            XCTAssertEqual(plain.sampleCount, 1)

            let expectedCombinedDimensions = [
                "tool=read_file outcome=attempted",
                "tool=read_file outcome=dispatchError",
                "tool=read_file outcome=skipped",
                "tool=read_file outcome=success",
                "tool=read_file outcome=toolNotFound"
            ]
            let combinedRows = snapshot.stages.filter { $0.stageName != "EditFlow.MCPToolCall.PreLimiterEnvelope" }
            XCTAssertTrue(combinedRows.allSatisfy { $0.sampleCount == 1 })
            XCTAssertTrue(combinedRows.allSatisfy { expectedCombinedDimensions.contains($0.sanitizedDimensions) })
            XCTAssertTrue(combinedRows.allSatisfy { !$0.sanitizedDimensions.contains("/") && !$0.sanitizedDimensions.contains("payload") })
            XCTAssertEqual(
                Set(combinedRows.map(\.sanitizedDimensions)),
                Set(expectedCombinedDimensions)
            )
        }

        func testReadFileProviderHooksRemainScopedOrderedAndConditional() throws {
            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            let methodStart = try XCTUnwrap(provider.range(of: "private func executeReadFile(args:"))
            let nextMethod = try XCTUnwrap(provider.range(of: "private func fileSearchTool()", range: methodStart.upperBound ..< provider.endIndex))
            let method = String(provider[methodStart.lowerBound ..< nextMethod.lowerBound])

            var searchStart = method.startIndex
            for hook in [
                "providerTotal",
                "providerArgumentParsing",
                "providerRequestMetadata",
                "providerLookupContextResolution",
                "providerPathTranslation",
                "providerReadEnvelope",
                "providerReplyProjection",
                "providerAutoSelect",
                "providerValueEncoding"
            ] {
                let match = try XCTUnwrap(method.range(of: hook, range: searchStart ..< method.endIndex), "Missing or out-of-order provider hook: \(hook)")
                searchStart = match.upperBound
            }

            XCTAssertTrue(method.contains("let providerTotalState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.providerTotal)"))
            XCTAssertTrue(method.contains("defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.providerTotal, providerTotalState) }"))

            let readEnvelope = try XCTUnwrap(method.range(of: "EditFlowPerf.Stage.ReadFile.providerReadEnvelope"))
            let readCall = try XCTUnwrap(method.range(of: "dependencies.readFile", range: readEnvelope.upperBound ..< method.endIndex))
            XCTAssertLessThan(readEnvelope.lowerBound, readCall.lowerBound)

            let autoSelect = try XCTUnwrap(method.range(of: "EditFlowPerf.Stage.ReadFile.providerAutoSelect"))
            let conditional = try XCTUnwrap(method.range(of: "if readResult.shouldAutoSelect", range: autoSelect.upperBound ..< method.endIndex))
            let autoSelectCall = try XCTUnwrap(method.range(of: "await dependencies.maybeAutoSelectReadFileSelection", range: conditional.upperBound ..< method.endIndex))
            XCTAssertLessThan(autoSelect.lowerBound, conditional.lowerBound)
            XCTAssertLessThan(conditional.lowerBound, autoSelectCall.lowerBound)

            let valueEncoding = try XCTUnwrap(method.range(of: "EditFlowPerf.Stage.ReadFile.providerValueEncoding"))
            let valueCall = try XCTUnwrap(method.range(of: "Value(readResult.reply)", range: valueEncoding.upperBound ..< method.endIndex))
            XCTAssertLessThan(valueEncoding.lowerBound, valueCall.lowerBound)
        }

        func testProviderReadRecorderCapturesTotalAndSanitizedAutoSelectOutcomes() throws {
            _ = startedCapture(label: "provider-read-decomposition", maxSamples: 100)
            EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.providerTotal) {}
            EditFlowPerf.measure(
                EditFlowPerf.Stage.ReadFile.providerAutoSelect,
                EditFlowPerf.Dimensions(outcome: "attempted")
            ) {}
            EditFlowPerf.measure(
                EditFlowPerf.Stage.ReadFile.providerAutoSelect,
                EditFlowPerf.Dimensions(outcome: "skipped")
            ) {}

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, 3)

            let total = try XCTUnwrap(snapshot.stages.first { $0.stageName == "EditFlow.ReadFile.ProviderTotal" })
            XCTAssertEqual(total.sanitizedDimensions, "")
            XCTAssertEqual(total.sampleCount, 1)

            let autoSelectRows = snapshot.stages.filter { $0.stageName == "EditFlow.ReadFile.ProviderAutoSelect" }
            XCTAssertEqual(autoSelectRows.map(\.sanitizedDimensions).sorted(), ["outcome=attempted", "outcome=skipped"])
            XCTAssertTrue(autoSelectRows.allSatisfy { $0.sampleCount == 1 })
            XCTAssertTrue(autoSelectRows.allSatisfy { !$0.sanitizedDimensions.contains("/") && !$0.sanitizedDimensions.contains("payload") })
        }

        func testProviderAutoSelectDecompositionStagesRemainStaticCompleteAndScoped() throws {
            let perf = try source("Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift")
            for stage in [
                "EditFlow.ReadFile.AutoSelect.Total",
                "EditFlow.ReadFile.AutoSelect.EligibilityResolution",
                "EditFlow.ReadFile.AutoSelect.SelectionProjection",
                "EditFlow.ReadFile.AutoSelect.FullFlowTotal",
                "EditFlow.ReadFile.AutoSelect.FullRequestMetadata",
                "EditFlow.ReadFile.AutoSelect.FullLookupContext",
                "EditFlow.ReadFile.AutoSelect.FullSnapshotResolution",
                "EditFlow.ReadFile.AutoSelect.StructuralAddTotal",
                "EditFlow.ReadFile.AutoSelect.CandidateResolutionTotal",
                "EditFlow.ReadFile.AutoSelect.StructuralMerge",
                "EditFlow.ReadFile.AutoSelect.AutoCodemapRecomputeTotal",
                "EditFlow.ReadFile.AutoSelect.SelectedFileLookup",
                "EditFlow.ReadFile.AutoSelect.CodemapAPILoad",
                "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.ActorBodyTotal",
                "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.StateSnapshot",
                "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.Materialization",
                "EditFlow.ReadFile.AutoSelect.ReferencedPathResolution",
                "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter",
                "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter.PathGrouping",
                "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter.SelectedRecordProjection",
                "EditFlow.ReadFile.AutoSelect.AutoReferencedAPIComputation",
                "EditFlow.ReadFile.AutoSelect.FullSliceClearing",
                "EditFlow.ReadFile.AutoSelect.FinalSelectionEquality",
                "EditFlow.ReadFile.AutoSelect.Persistence",
                "EditFlow.ReadFile.AutoSelect.SliceFlowTotal"
            ] {
                XCTAssertTrue(perf.contains(stage), "Missing nested auto-select attribution stage: \(stage)")
            }

            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            for hook in [
                "total",
                "eligibilityResolution",
                "selectionProjection",
                "fullFlowTotal",
                "fullRequestMetadata",
                "fullLookupContext",
                "fullSnapshotResolution",
                "structuralAddTotal",
                "fullSliceClearing",
                "finalSelectionEquality",
                "persistence",
                "sliceFlowTotal"
            ] {
                XCTAssertTrue(viewModel.contains("Stage.ReadFile.AutoSelect.\(hook)"), "Missing view-model nested auto-select hook: \(hook)")
            }

            let mutations = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionMutationService.swift")
            for hook in [
                "candidateResolutionTotal",
                "structuralMerge",
                "autoCodemapRecomputeTotal",
                "selectedFileLookup",
                "codemapAPILoad",
                "referencedPathResolution"
            ] {
                XCTAssertTrue(mutations.contains("Stage.ReadFile.AutoSelect.\(hook)"), "Missing mutation-service nested auto-select hook: \(hook)")
            }

            let extractor = try source("Sources/RepoPrompt/Features/CodeMap/CodeMapExtractor.swift")
            let workspaceOverloadStart = try XCTUnwrap(extractor.range(of: "static func resolveReferencedFilePaths(\n        from selectedFiles: [WorkspaceFileRecord]"))
            let workspaceOverloadEnd = try XCTUnwrap(extractor.range(of: "/// Returns the list of file paths", range: workspaceOverloadStart.upperBound ..< extractor.endIndex))
            let workspaceOverload = String(extractor[workspaceOverloadStart.lowerBound ..< workspaceOverloadEnd.lowerBound])
            XCTAssertTrue(workspaceOverload.contains("Stage.ReadFile.AutoSelect.acceptedFileAPIFilter"))
            XCTAssertTrue(workspaceOverload.contains("Stage.ReadFile.AutoSelect.autoReferencedAPIComputation"))

            let fileViewModelOverloadStart = try XCTUnwrap(extractor.range(of: "static func resolveReferencedFilePaths(\n        from selectedFiles: [FileViewModel]"))
            let fileViewModelOverload = String(extractor[fileViewModelOverloadStart.lowerBound ..< workspaceOverloadStart.lowerBound])
            XCTAssertFalse(fileViewModelOverload.contains("Stage.ReadFile.AutoSelect"))

            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            let manager = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift")
            let diagnostics = try diagnosticsSource()
            for forbiddenOwner in [provider, manager, diagnostics] {
                XCTAssertFalse(forbiddenOwner.contains("Stage.ReadFile.AutoSelect"))
                XCTAssertFalse(forbiddenOwner.contains("EditFlow.ReadFile.AutoSelect."))
            }
        }

        func testProviderAutoSelectDecompositionKeepsAwaitOrderingAndCoarseOutcomes() throws {
            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            let replyProjection = try XCTUnwrap(provider.range(of: "EditFlowPerf.Stage.ReadFile.providerReplyProjection"))
            let dependencyAwait = try XCTUnwrap(provider.range(of: "await dependencies.maybeAutoSelectReadFileSelection", range: replyProjection.upperBound ..< provider.endIndex))
            let valueEncoding = try XCTUnwrap(provider.range(of: "EditFlowPerf.Stage.ReadFile.providerValueEncoding", range: dependencyAwait.upperBound ..< provider.endIndex))
            XCTAssertLessThan(replyProjection.lowerBound, dependencyAwait.lowerBound)
            XCTAssertLessThan(dependencyAwait.lowerBound, valueEncoding.lowerBound)

            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            let mutations = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionMutationService.swift")
            let nestedSources = viewModel + mutations
            for outcome in [
                "eligible",
                "ineligible",
                "missing",
                "full",
                "slice",
                "changed",
                "unchanged",
                "attempted",
                "skipped",
                "error"
            ] {
                XCTAssertTrue(nestedSources.contains("\"\(outcome)\""), "Missing approved nested outcome: \(outcome)")
            }
            XCTAssertFalse(nestedSources.contains("EditFlowPerf.Dimensions(path:"))
            XCTAssertFalse(nestedSources.contains("EditFlowPerf.Dimensions(pattern:"))
            XCTAssertFalse(nestedSources.contains("EditFlowPerf.Dimensions(payload:"))
        }

        func testProviderAutoSelectNestedRecorderCapturesRepresentativeSanitizedOutcomes() {
            _ = startedCapture(label: "provider-auto-select-decomposition", maxSamples: 100)
            let samples: [(StaticString, String)] = [
                (EditFlowPerf.Stage.ReadFile.AutoSelect.eligibilityResolution, "eligible"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.selectionProjection, "full"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.fullFlowTotal, "unchanged"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.autoCodemapRecomputeTotal, "attempted"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.finalSelectionEquality, "unchanged"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.persistence, "skipped")
            ]
            for (stage, outcome) in samples {
                EditFlowPerf.measure(stage, EditFlowPerf.Dimensions(outcome: outcome)) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, samples.count)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertTrue(snapshot.stages.allSatisfy { $0.sampleCount == 1 })
            XCTAssertEqual(
                Set(snapshot.stages.map(\.sanitizedDimensions)),
                Set(samples.map { "outcome=\($0.1)" })
            )
            XCTAssertTrue(snapshot.stages.allSatisfy {
                !$0.sanitizedDimensions.contains("/") &&
                    !$0.sanitizedDimensions.contains("payload") &&
                    !$0.sanitizedDimensions.contains("namespace")
            })
        }

        func testAcceptedFileAPIFilterInnerAttributionRemainsBehaviorNeutralScopedAndOrdered() throws {
            let extractor = try source("Sources/RepoPrompt/Features/CodeMap/CodeMapExtractor.swift")
            let helperStart = try XCTUnwrap(extractor.range(of: "    private static func acceptedFileAPIs(from files: [WorkspaceFileRecord], allFileAPIs: [FileAPI]) -> [FileAPI] {"))
            let helperEnd = try XCTUnwrap(extractor.range(of: "    private static func isUnderCurrentRoots", range: helperStart.upperBound ..< extractor.endIndex))
            let helper = String(extractor[helperStart.lowerBound ..< helperEnd.lowerBound])

            var searchStart = helper.startIndex
            for hook in [
                "guard !files.isEmpty, !allFileAPIs.isEmpty else { return [] }",
                "#if DEBUG || EDIT_FLOW_PERF",
                "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.pathGrouping)",
                "let apisByPath = Dictionary(grouping: allFileAPIs, by: { standardizedAPIFilePath($0) })",
                "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.pathGrouping, pathGrouping)",
                "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection)",
                "let selectedAPIs = files.compactMap { file in",
                "apisByPath[file.standardizedFullPath]?.first",
                "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection, selectedRecordProjection)",
                "return selectedAPIs",
                "#else",
                "let apisByPath = Dictionary(grouping: allFileAPIs, by: { standardizedAPIFilePath($0) })",
                "return files.compactMap { file in",
                "apisByPath[file.standardizedFullPath]?.first",
                "#endif"
            ] {
                let match = try XCTUnwrap(helper.range(of: hook, range: searchStart ..< helper.endIndex), "Missing or out-of-order accepted-file attribution hook: \(hook)")
                searchStart = match.upperBound
            }
            for forbidden in [
                "await",
                "Task",
                "cache",
                "generation",
                "UserDefaults",
                "app_settings",
                "nonisolated",
                "EditFlowPerf.Dimensions",
                "print(",
                "Logger",
                "os_log",
                "workspaceFileContextStore",
                "MCP",
                "routing",
                "limiter"
            ] {
                XCTAssertFalse(helper.contains(forbidden), "Forbidden accepted-file attribution semantic: \(forbidden)")
            }

            let indexedHelperStart = try XCTUnwrap(extractor.range(of: "    private static func acceptedFileAPIs(\n        from files: [WorkspaceFileRecord],\n        firstFileAPIByStandardizedNestedPath: [String: FileAPI]"))
            let indexedHelperEnd = try XCTUnwrap(extractor.range(of: "    private static func isUnderCurrentRoots", range: indexedHelperStart.upperBound ..< extractor.endIndex))
            let indexedHelper = String(extractor[indexedHelperStart.lowerBound ..< indexedHelperEnd.lowerBound])
            XCTAssertTrue(indexedHelper.contains("guard !files.isEmpty, !firstFileAPIByStandardizedNestedPath.isEmpty else { return [] }"))
            XCTAssertTrue(indexedHelper.contains("EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection)"))
            XCTAssertTrue(indexedHelper.contains("firstFileAPIByStandardizedNestedPath[file.standardizedFullPath]"))
            XCTAssertTrue(indexedHelper.contains("EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection, selectedRecordProjection)"))
            XCTAssertFalse(indexedHelper.contains("pathGrouping"))
            XCTAssertFalse(indexedHelper.contains("Dictionary(grouping:"))

            let fileViewModelHelperStart = try XCTUnwrap(extractor.range(of: "    private static func acceptedFileAPIs(from files: [FileViewModel]) -> [FileAPI] {"))
            let fileViewModelHelper = String(extractor[fileViewModelHelperStart.lowerBound ..< helperStart.lowerBound])
            XCTAssertFalse(fileViewModelHelper.contains("AcceptedFileAPIFilter"))

            let resolverStart = try XCTUnwrap(extractor.range(of: "static func resolveReferencedFilePaths(\n        from selectedFiles: [WorkspaceFileRecord]"))
            let resolverEnd = try XCTUnwrap(extractor.range(of: "/// Returns the list of file paths", range: resolverStart.upperBound ..< extractor.endIndex))
            let resolver = String(extractor[resolverStart.lowerBound ..< resolverEnd.lowerBound])
            let outerBegin = try XCTUnwrap(resolver.range(of: "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter)"))
            let helperCall = try XCTUnwrap(resolver.range(of: "acceptedFileAPIs(from: selectedFiles, allFileAPIs: allFileAPIs)", range: outerBegin.upperBound ..< resolver.endIndex))
            let outerEnd = try XCTUnwrap(resolver.range(of: "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.acceptedFileAPIFilter, acceptedFileAPIFilter)", range: helperCall.upperBound ..< resolver.endIndex))
            let indexedResolver = try XCTUnwrap(resolver.range(of: "firstFileAPIByStandardizedNestedPath: [String: FileAPI]"))
            let indexedHelperCall = try XCTUnwrap(resolver.range(of: "firstFileAPIByStandardizedNestedPath: firstFileAPIByStandardizedNestedPath", range: indexedResolver.upperBound ..< resolver.endIndex))
            let lowerComputation = try XCTUnwrap(resolver.range(of: "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.autoReferencedAPIComputation)", range: indexedHelperCall.upperBound ..< resolver.endIndex))
            XCTAssertLessThan(outerBegin.lowerBound, helperCall.lowerBound)
            XCTAssertLessThan(helperCall.lowerBound, outerEnd.lowerBound)
            XCTAssertLessThan(outerEnd.lowerBound, indexedResolver.lowerBound)
            XCTAssertLessThan(indexedResolver.lowerBound, indexedHelperCall.lowerBound)
            XCTAssertLessThan(indexedHelperCall.lowerBound, lowerComputation.lowerBound)
        }

        func testAcceptedFileAPIFilterInnerAttributionRecorderCapturesEmptyDimensions() throws {
            _ = startedCapture(label: "accepted-file-api-filter-inner", maxSamples: 100)
            let stages: [(StaticString, String)] = [
                (EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.pathGrouping, "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter.PathGrouping"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.AcceptedFileAPIFilter.selectedRecordProjection, "EditFlow.ReadFile.AutoSelect.AcceptedFileAPIFilter.SelectedRecordProjection")
            ]
            for (stage, _) in stages {
                EditFlowPerf.measure(stage) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, stages.count)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            for (_, stageName) in stages {
                let row = try XCTUnwrap(snapshot.stages.first { $0.stageName == stageName })
                XCTAssertEqual(row.sampleCount, 1)
                XCTAssertEqual(row.sanitizedDimensions, "")
            }
        }

        func testAllCodemapFileAPIsActorOwnedCacheHooksRemainScopedAndExhaustivelyInvalidated() throws {
            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("private var cachedCodemapFileAPIAggregate: WorkspaceCodemapFileAPIAggregate?"))
            XCTAssertFalse(store.contains("private var cachedAllCodemapFileAPIs: [FileAPI]?"))
            XCTAssertEqual(store.components(separatedBy: "invalidateAllCodemapFileAPIsCache").count - 1, 9)

            let invalidatorStart = try XCTUnwrap(store.range(of: "    private func invalidateAllCodemapFileAPIsCache() {"))
            let invalidatorEnd = try XCTUnwrap(store.range(of: "    private func isDiscoverableFileID", range: invalidatorStart.upperBound ..< store.endIndex))
            let invalidator = String(store[invalidatorStart.lowerBound ..< invalidatorEnd.lowerBound])
            XCTAssertTrue(invalidator.contains("cachedCodemapFileAPIAggregate = nil"))
            for forbidden in ["await", "Task", "nonisolated", "generation"] {
                XCTAssertFalse(invalidator.contains(forbidden), "Forbidden aggregate-cache invalidator semantic: \(forbidden)")
            }

            let compatibilityAccessorStart = try XCTUnwrap(store.range(of: "    func allCodemapFileAPIs() -> [FileAPI] {"))
            let accessorStart = try XCTUnwrap(store.range(of: "    func codemapFileAPIAggregate() -> WorkspaceCodemapFileAPIAggregate {", range: compatibilityAccessorStart.upperBound ..< store.endIndex))
            let compatibilityAccessor = String(store[compatibilityAccessorStart.lowerBound ..< accessorStart.lowerBound])
            XCTAssertTrue(compatibilityAccessor.contains("codemapFileAPIAggregate().orderedFileAPIs"))
            let accessorEnd = try XCTUnwrap(store.range(of: "    func codemapSnapshotDictionary()", range: accessorStart.upperBound ..< store.endIndex))
            let accessor = String(store[accessorStart.lowerBound ..< accessorEnd.lowerBound])
            var searchStart = accessor.startIndex
            for hook in [
                "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal)",
                "defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal, actorBodyTotal) }",
                "if let cachedCodemapFileAPIAggregate {",
                "return cachedCodemapFileAPIAggregate",
                "#if DEBUG || EDIT_FLOW_PERF",
                "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot)",
                "codemapSnapshotsByFileID.values",
                ".filter { isDiscoverableFileID($0.fileID) }",
                "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot, stateSnapshot)",
                "EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization)",
                ".sorted { $0.fullPath < $1.fullPath }",
                ".compactMap(\\.fileAPI)",
                "#else",
                "let APIs = allCodemapSnapshots().compactMap(\\.fileAPI)",
                "#endif",
                "var firstFileAPIByStandardizedNestedPath: [String: FileAPI] = [:]",
                "firstFileAPIByStandardizedNestedPath.reserveCapacity(APIs.count)",
                "for api in APIs {",
                "let standardizedNestedPath = StandardizedPath.absolute(api.filePath)",
                "if firstFileAPIByStandardizedNestedPath[standardizedNestedPath] == nil {",
                "firstFileAPIByStandardizedNestedPath[standardizedNestedPath] = api",
                "let aggregate = WorkspaceCodemapFileAPIAggregate(",
                "orderedFileAPIs: APIs,",
                "firstFileAPIByStandardizedNestedPath: firstFileAPIByStandardizedNestedPath",
                "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization, materialization)",
                "cachedCodemapFileAPIAggregate = aggregate",
                "return aggregate"
            ] {
                let match = try XCTUnwrap(accessor.range(of: hook, range: searchStart ..< accessor.endIndex), "Missing or out-of-order allCodemapFileAPIs hook: \(hook)")
                searchStart = match.upperBound
            }
            for forbidden in [
                "await",
                "Task",
                "Array(codemapSnapshotsByFileID.values)",
                "generation",
                "UserDefaults",
                "app_settings",
                "nonisolated",
                "EditFlowPerf.Dimensions",
                "print(",
                "Logger",
                "os_log",
                "Dimensions(path:",
                "Dimensions(fileName:",
                "Dimensions(fileID:",
                "Dimensions(identifier:"
            ] {
                XCTAssertFalse(accessor.contains(forbidden), "Forbidden allCodemapFileAPIs cache semantic: \(forbidden)")
            }

            for requiredInvalidationWiring in [
                "if !snapshotsByRootID.isEmpty {\n            invalidateAllCodemapFileAPIsCache()",
                "if managedOnlyFileIDs.insert(file.id).inserted {\n                    invalidateAllCodemapFileAPIsCache()",
                "codemapFileIDsByRootID[rootID]?.remove(fileID)\n        invalidateAllCodemapFileAPIsCache()",
                "if codemapSnapshotsByFileID.removeValue(forKey: fileID) != nil {\n            invalidateAllCodemapFileAPIsCache()",
                "if managedOnlyFileIDs.remove(file.id) != nil {\n            invalidateAllCodemapFileAPIsCache()",
                "codemapFileIDsByRootID.removeAll(keepingCapacity: false)\n        invalidateAllCodemapFileAPIsCache()",
                "if removedSnapshot {\n            invalidateAllCodemapFileAPIsCache()"
            ] {
                XCTAssertTrue(store.contains(requiredInvalidationWiring), "Missing aggregate-cache invalidation wiring: \(requiredInvalidationWiring)")
            }

            let unloadStart = try XCTUnwrap(store.range(of: "    func unloadRoots(ids rootIDs: [UUID]) async {"))
            let unloadEnd = try XCTUnwrap(store.range(of: "    func file(rootID: UUID, relativePath: String)", range: unloadStart.upperBound ..< store.endIndex))
            let unload = String(store[unloadStart.lowerBound ..< unloadEnd.lowerBound])
            let rootDetach = try XCTUnwrap(unload.range(of: "rootStatesByID.removeValue(forKey: rootID)"))
            let stopWatching = try XCTUnwrap(unload.range(of: "await entry.state.service.stopWatchingForChanges()"))
            let managedOnlyCleanup = try XCTUnwrap(unload.range(of: "managedOnlyFileIDs.remove(fileID)"))
            let rootSnapshotCleanup = try XCTUnwrap(unload.range(of: "removeCodemapSnapshots(forRootID: rootID)"))
            XCTAssertLessThan(rootDetach.lowerBound, stopWatching.lowerBound)
            XCTAssertLessThan(stopWatching.lowerBound, managedOnlyCleanup.lowerBound)
            XCTAssertLessThan(managedOnlyCleanup.lowerBound, rootSnapshotCleanup.lowerBound)
            XCTAssertFalse(String(unload[rootDetach.lowerBound ..< stopWatching.lowerBound]).contains("invalidateAllCodemapFileAPIsCache"))
            XCTAssertFalse(String(unload[managedOnlyCleanup.lowerBound ..< rootSnapshotCleanup.lowerBound]).contains("await"))

            let provider = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
            let mutations = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionMutationService.swift")
            let extractor = try source("Sources/RepoPrompt/Features/CodeMap/CodeMapExtractor.swift")
            let diagnostics = try diagnosticsSource() + source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift")
            for forbiddenOwner in [provider, mutations, extractor, diagnostics] {
                XCTAssertFalse(forbiddenOwner.contains("AllCodemapFileAPIs"))
                XCTAssertFalse(forbiddenOwner.contains("cachedAllCodemapFileAPIs"))
                XCTAssertFalse(forbiddenOwner.contains("cachedCodemapFileAPIAggregate"))
                XCTAssertFalse(forbiddenOwner.contains("invalidateAllCodemapFileAPIsCache"))
            }

            let recomputeStart = try XCTUnwrap(mutations.range(of: "    func recomputeAutoCodemaps("))
            let recompute = String(mutations[recomputeStart.lowerBound ..< mutations.endIndex])
            let outerBegin = try XCTUnwrap(recompute.range(of: "let codemapAPILoad = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.codemapAPILoad)"))
            let outerAwait = try XCTUnwrap(recompute.range(of: "let aggregate = await store.codemapFileAPIAggregate()", range: outerBegin.upperBound ..< recompute.endIndex))
            XCTAssertEqual(recompute.components(separatedBy: "await store.codemapFileAPIAggregate()").count - 1, 1)
            XCTAssertFalse(recompute.contains("await store.allCodemapFileAPIs()"))
            XCTAssertTrue(recompute.contains("among: aggregate.orderedFileAPIs"))
            XCTAssertTrue(recompute.contains("firstFileAPIByStandardizedNestedPath: aggregate.firstFileAPIByStandardizedNestedPath"))
            let outerEnd = try XCTUnwrap(recompute.range(of: "EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.codemapAPILoad, codemapAPILoad)", range: outerAwait.upperBound ..< recompute.endIndex))
            XCTAssertLessThan(outerBegin.lowerBound, outerAwait.lowerBound)
            XCTAssertLessThan(outerAwait.lowerBound, outerEnd.lowerBound)
        }

        func testAllCodemapFileAPIsActorBodyAttributionRecorderCapturesEmptyDimensions() throws {
            _ = startedCapture(label: "all-codemap-file-apis-actor-body", maxSamples: 100)
            let stages: [(StaticString, String)] = [
                (EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal, "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.ActorBodyTotal"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot, "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.StateSnapshot"),
                (EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization, "EditFlow.ReadFile.AutoSelect.AllCodemapFileAPIs.Materialization")
            ]
            for (stage, _) in stages {
                EditFlowPerf.measure(stage) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
            XCTAssertEqual(snapshot.retainedSampleCount, stages.count)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            for (_, stageName) in stages {
                let row = try XCTUnwrap(snapshot.stages.first { $0.stageName == stageName })
                XCTAssertEqual(row.sampleCount, 1)
                XCTAssertEqual(row.sanitizedDimensions, "")
            }
        }

        func testReadResolutionDecompositionHooksRemainOnExpectedLayers() throws {
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            for hook in [
                "resolveReadableFile",
                "exactPathIssueDetection",
                "rootRefsLookup",
                "folderResolution",
                "externalFolderGuard",
                "readableServiceResolution"
            ] {
                XCTAssertTrue(viewModel.contains(hook), "Missing view-model read-resolution hook: \(hook)")
            }

            let readableService = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceReadableFileService.swift")
            for hook in [
                "exactCatalogLookupAwait",
                "explicitMaterialization",
                "generalLookupFallback",
                "externalFileFallback"
            ] {
                XCTAssertTrue(readableService.contains(hook), "Missing readable-service resolution hook: \(hook)")
            }

            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("exactCatalogLookupActorBody"))
            XCTAssertTrue(store.contains("Dimensions(outcome:"))
        }

        func testReadResolutionDecompositionAvoidsOrdinaryReleaseOutcomeBookkeeping() throws {
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            XCTAssertFalse(viewModel.contains("let readableServiceOutcome ="))
            XCTAssertTrue(viewModel.contains("Dimensions(outcome: {\n                    switch readableFile"))

            let readableService = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceReadableFileService.swift")
            XCTAssertFalse(readableService.contains("let exactCatalogLookupOutcome ="))
            XCTAssertFalse(readableService.contains("let explicitMaterializationOutcome ="))
            XCTAssertTrue(readableService.contains("Dimensions(outcome: {\n                switch exactCatalogLookup"))
            XCTAssertTrue(readableService.contains("Dimensions(outcome: {\n                switch materialization"))

            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("#if DEBUG || EDIT_FLOW_PERF\n            var exactCatalogLookupOutcome"))
            XCTAssertTrue(store.contains("#if DEBUG || EDIT_FLOW_PERF\n                exactCatalogLookupOutcome ="))
        }

        func testSearchCatalogSnapshotCacheRemainsBoundedGenerationKeyedAndCoarselyDiagnosed() throws {
            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("private static let maxCachedSearchCatalogSnapshotScopes = 16"))
            XCTAssertTrue(store.contains("private var searchCatalogSnapshotsByScope: [WorkspaceLookupRootScope: SearchCatalogSnapshotCacheEntry] = [:]"))
            XCTAssertTrue(store.contains("case .sessionBoundWorkspace:\n            scopedSnapshotGeneration(scope: .allLoaded)"))
            XCTAssertTrue(store.contains("private func clearSearchCatalogSnapshotCache() {\n        searchCatalogSnapshotsByScope.removeAll(keepingCapacity: true)\n    }"))
            XCTAssertTrue(store.contains("rootStatesByID[originalRootID] = state\n            clearSearchCatalogSnapshotCache()\n            indexed.append(fullPath)"))
            XCTAssertTrue(store.contains("guard !statesToUnload.isEmpty else { return }\n        clearSearchCatalogSnapshotCache()\n        #if DEBUG"))
            XCTAssertTrue(store.contains("bumpCatalogGenerations(affectedRootKinds: affectedRootKinds)\n        clearSearchCatalogSnapshotCache()\n        invalidatePathMatchCache()"))
            XCTAssertTrue(store.contains("#endif\n        invalidatePathMatchCache()\n        finishRootUnload(for: unloadingPaths)"))
            XCTAssertTrue(store.contains("cacheHit: true"))
            XCTAssertTrue(store.contains("cacheHit: false"))
            XCTAssertFalse(store.contains("Dimensions(rootScope:"))
            XCTAssertFalse(store.contains("Dimensions(path:"))
        }

        func testInactiveCaptureFastPathRemainsAtomicAndUnusedOutputBytesIsAbsent() throws {
            let perf = try source("Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift")
            XCTAssertTrue(perf.contains("Lightweight, gated instrumentation for hot-path diagnostics."))
            XCTAssertTrue(perf.contains("private let activeHint = DebugCaptureActiveHint()"))
            XCTAssertTrue(perf.contains("if let active = activeHint.loadIfAvailable(), !active { return nil }"))
            XCTAssertTrue(perf.contains("@available(macOS 15.0, *)"))
            XCTAssertFalse(perf.contains("outputBytes"))
        }

        func testCaptureRejectsConcurrentStartAndFinishDisablesCapture() {
            switch EditFlowPerf.beginDebugCapture(label: "first", maxSamples: 100) {
            case .started:
                break
            case .busy:
                XCTFail("First capture should start.")
            }
            switch EditFlowPerf.beginDebugCapture(label: "second", maxSamples: 100) {
            case .started:
                XCTFail("Concurrent capture should be rejected.")
            case let .busy(snapshot):
                XCTAssertEqual(snapshot.label, "first")
                XCTAssertTrue(snapshot.active)
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
        }

        func testStaleIntervalFromFinishedCaptureDoesNotContaminateNextCapture() throws {
            _ = startedCapture(label: "capture-a", maxSamples: 100)
            let staleState = try XCTUnwrap(EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.providerExecution))
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            _ = startedCapture(label: "capture-b", maxSamples: 100)
            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.providerExecution, staleState)

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.label, "capture-b")
            XCTAssertEqual(snapshot.retainedSampleCount, 0)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertTrue(snapshot.stages.isEmpty)
        }

        func testDirectCaptureSampleLimitIsClampedToDiagnosticBounds() {
            let lowerBound = startedCapture(label: "lower", maxSamples: 1)
            XCTAssertEqual(lowerBound.maxSamples, 100)
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            let upperBound = startedCapture(label: "upper", maxSamples: 100_001)
            XCTAssertEqual(upperBound.maxSamples, 100_000)
        }

        func testUnsafeSyntheticLabelAndDimensionsAreSanitizedAndBounded() throws {
            let unsafe = "synthetic /:|\\n" + String(repeating: "x", count: 100)
            let started = startedCapture(label: unsafe, maxSamples: 100)
            assertPermittedLabel(started.label)

            EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.providerExecution,
                EditFlowPerf.Dimensions(toolName: unsafe, status: unsafe)
            ) {}

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            let components = aggregate.sanitizedDimensions.split(separator: " ")
            XCTAssertEqual(components.count, 2)
            for component in components {
                let parts = component.split(separator: "=", maxSplits: 1)
                XCTAssertEqual(parts.count, 2)
                assertPermittedLabel(String(parts[1]))
            }
        }

        func testBoundedCaptureReportsDroppedSamplesAndSanitizedDimensions() throws {
            switch EditFlowPerf.beginDebugCapture(label: "bounded", maxSamples: 100) {
            case .started:
                break
            case .busy:
                XCTFail("Capture should start.")
            }

            for _ in 0 ..< 101 {
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.providerExecution,
                    EditFlowPerf.Dimensions(toolName: "read_file", status: "ok")
                ) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.retainedSampleCount, 100)
            XCTAssertEqual(snapshot.droppedSampleCount, 1)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            XCTAssertEqual(aggregate.sampleCount, 100)
            XCTAssertTrue(aggregate.sanitizedDimensions.contains("tool=read_file"))
            XCTAssertFalse(aggregate.sanitizedDimensions.contains("/"))
            XCTAssertFalse(aggregate.sanitizedDimensions.contains("namespace"))
        }

        private func startedCapture(label: String, maxSamples: Int) -> EditFlowPerf.DebugCaptureSnapshot {
            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
            case let .started(snapshot):
                return snapshot
            case .busy:
                XCTFail("Capture should start.")
                fatalError("Capture should start.")
            }
        }

        private func assertPermittedLabel(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            XCTAssertLessThanOrEqual(value.unicodeScalars.count, 64, file: file, line: line)
            XCTAssertTrue(value.unicodeScalars.allSatisfy(allowed.contains), "Unexpected unsafe label: \(value)", file: file, line: line)
        }

        private func diagnosticsSource() throws -> String {
            let root = try RepoRoot.url()
            let directory = root.appendingPathComponent("Sources/RepoPrompt/Features/Diagnostics/MCP")
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("MCPConnectionManager+DebugDiagnostics") && $0.pathExtension == "swift" }
                .map { try String(contentsOf: $0, encoding: .utf8) }
                .joined(separator: "\n")
        }

        private func source(_ relativePath: String) throws -> String {
            try String(contentsOf: RepoRoot.url().appendingPathComponent(relativePath), encoding: .utf8)
        }
    }
#endif
