import MCP
@testable import RepoPromptApp
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

final class MCPMutationRetryableFailureTests: XCTestCase {
    func testMutationFreshnessTimeoutHasHeadroomBeforeBoundedToolWatchdog() {
        XCTAssertLessThan(
            MCPTimeoutPolicy.mutationPreflightFreshnessWaitTimeoutSeconds,
            MCPTimeoutPolicy.boundedToolExecutionDeadlineSeconds
        )
    }

    func testMutationScopeFailureClassifiesFailClosedAndMissingWorktreeScopes() async {
        let store = WorkspaceFileContextStore()

        let failClosed = await MCPMutationRetryableFailure.mutationScopeFailure(
            for: AgentWorkspaceLookupContextResolver.failClosedLookupContext,
            store: store
        )
        XCTAssertEqual(failClosed?.errorCode, "worktree_scope_unavailable")
        XCTAssertEqual(failClosed?.retryable, true)
        XCTAssertEqual(failClosed?.retryAfterMilliseconds, 1000)
        XCTAssertTrue(failClosed?.errorMessage.contains("stopped before path translation") ?? false, failClosed?.errorMessage ?? "nil")
        XCTAssertTrue(failClosed?.errorMessage.contains("canonical checkout") ?? false, failClosed?.errorMessage ?? "nil")

        let missingPhysicalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-worktree-\(UUID().uuidString)")
            .path
        let missingScope = WorkspaceLookupContext(
            rootScope: .sessionBoundWorkspace(
                canonicalRootPaths: [FileManager.default.temporaryDirectory.path],
                physicalRootPaths: [missingPhysicalRoot]
            ),
            bindingProjection: nil
        )

        // The unavailable-scope contract is store visibility, not raw disk existence:
        // an unregistered physical worktree root must fail closed before mutation.
        let missing = await MCPMutationRetryableFailure.mutationScopeFailure(
            for: missingScope,
            store: store
        )
        XCTAssertEqual(missing?.errorCode, "worktree_scope_unavailable")
        XCTAssertEqual(missing?.retryable, true)
        XCTAssertTrue(missing?.errorMessage.contains("physical") ?? false, missing?.errorMessage ?? "nil")
    }

    func testWorkspaceFreshnessFailureIsExplicitlyPreMutationAndSafeToRetry() {
        let failure = MCPMutationRetryableFailure.workspaceFreshnessUnavailable()
        XCTAssertEqual(failure.errorCode, "workspace_freshness_timeout")
        XCTAssertTrue(failure.retryable)
        XCTAssertTrue(failure.errorMessage.contains("No filesystem mutation was started"))
        XCTAssertTrue(failure.suggestion.contains("replay is safe"))
    }

    func testUnhydratedInactiveAgentRouteFailsRetryablyBeforeLookupHydration() {
        let snapshot = MCPServerViewModel.TabContextSnapshot(
            tabID: UUID(),
            windowID: 1,
            workspaceID: UUID(),
            promptText: "",
            selection: StoredSelection(),
            selectedMetaPromptIDs: [],
            tabName: "Inactive Agent",
            runID: nil,
            activeAgentSessionID: UUID(),
            worktreeBindingState: .unhydrated,
            explicitlyBound: true
        )

        let failure = MCPMutationRetryableFailure.unresolvedRouteFailure(for: snapshot)

        XCTAssertEqual(failure?.errorCode, "worktree_scope_hydrating")
        XCTAssertEqual(failure?.retryable, true)
        XCTAssertTrue(failure?.errorMessage.contains("No filesystem mutation was started") == true)
    }

    func testApplyEditsProviderStopsOnMutationScopeFailureBeforeFreshnessOrExactResolution() throws {
        let source = try Self.source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPApplyEditsToolProvider.swift")
        let body = try XCTUnwrap(source.slice(
            from: "    private func executeApplyEdits(args: [String: Value]) async throws -> EditSummary {",
            to: "    private static func resolveApplyEditsAgentModeTabID("
        ))

        try Self.assertOrdered([
            "let (resolvedContext, lookupContext) = try await dependencies.selection.resolveMutationFileToolContext(",
            "MCPMutationRetryableFailure.unresolvedRouteFailure(",
            "return Self.retryableFailureSummary(request: request, failure: failure)",
            "if let failure = await MCPMutationRetryableFailure.mutationScopeFailure(",
            "return Self.retryableFailureSummary(request: request, failure: failure)",
            "WorkspaceExactFileInput.parse(request.path)",
            "let namespace = lookupContext.exactFileNamespace(storeRoots: roots)",
            "awaitAppliedIngressForExplicitRequest(",
            "mutationService.resolveExactExistingFile(exactInput, namespace: namespace)",
            "effectivePath = lookupContext.translateInputPath(request.path)",
            "target = .create(path: effectivePath)"
        ], in: body)
    }

    func testFileActionsProviderStopsOnMutationScopeFailureBeforeTranslationOrFreshness() throws {
        let source = try Self.source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
        let body = try XCTUnwrap(source.slice(
            from: "    private func performFileAction(\n",
            to: "    /// Creates a **new** file"
        ))

        try Self.assertOrdered([
            "var (resolvedContext, lookupContext) = try await resolveMutationFileToolContext(",
            "MCPMutationRetryableFailure.unresolvedRouteFailure(",
            "throw failure",
            "if let failure = await MCPMutationRetryableFailure.mutationScopeFailure(",
            "throw failure",
            "let effectivePath = lookupContext.translateInputPath(path)",
            "awaitAppliedIngressForExplicitRequests("
        ], in: body)
    }

    func testMoveUsesOneSharedFreshnessDeadlineForSourceAndDestination() throws {
        let source = try Self.source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
        let body = try XCTUnwrap(source.slice(
            from: "    private func performFileAction(\n",
            to: "    /// Creates a **new** file"
        ))

        let preflight = try XCTUnwrap(body.slice(
            from: "        await MCPToolExecutionHandlerPhaseContext.report(.fileActionsCatalogEligibility)\n",
            to: "        await MCPToolExecutionHandlerPhaseContext.report(.fileActionsCatalogEligibility, transition: .completed)"
        ))
        XCTAssertTrue(preflight.contains("let mutationPaths = [effectivePath] + (effectiveNewPath.map { [$0] } ?? [])"))
        XCTAssertTrue(preflight.contains("awaitAppliedIngressForExplicitRequests(\n                userPaths: mutationPaths"))
        XCTAssertEqual(
            preflight.components(separatedBy: "mutationPreflightFreshnessWaitTimeout").count - 1,
            1,
            "source and destination must share one timeout race so the structured freshness failure wins before the outer watchdog"
        )
        XCTAssertFalse(preflight.contains("awaitAppliedIngressForExplicitRequest(\n"))
        try Self.assertOrdered([
            "let mutationPaths = [effectivePath] + (effectiveNewPath.map { [$0] } ?? [])",
            "awaitAppliedIngressForExplicitRequests(",
            "catch is WorkspaceAppliedIngressWaitError",
            "throw MCPMutationRetryableFailure.workspaceFreshnessUnavailable()"
        ], in: preflight)
    }

    func testCreateSelectionUsesCanonicalPersistencePath() throws {
        let source = try Self.source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
        let body = try XCTUnwrap(source.slice(
            from: "    private func performFileAction(\n",
            to: "    /// Creates a **new** file"
        ))

        try Self.assertOrdered([
            "let freshness = \"fresh\"",
            "let baseSelection = resolvedContext.snapshot.selection",
            "let requestedSelection = addResult.selection",
            "resolvedContext.snapshot.selection = requestedSelection",
            "persistResolvedTabContextSnapshot(resolvedContext, metadata: metadata, mutated: true)",
            "requireCanonicalSelection(",
            "warning: acknowledgementWarnings.isEmpty ? nil"
        ], in: body)
        XCTAssertFalse(body.contains("private discovery selection"))
        XCTAssertTrue(body.contains("use operation ID \\(operationID) only to correlate this result"))
        XCTAssertFalse(body.contains("reconcile using operation ID"))
    }

    func testManageSelectionPromoteDemotePersistOnlyWhenMutationOccurs() throws {
        let source = try Self.source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPSelectionToolProvider.swift")
        let promote = try XCTUnwrap(source.slice(from: "        case \"promote\":", to: "        case \"demote\":"))
        try Self.assertOrdered([
            "let promoteResult = await dependencies.selection.promoteStoredSelectionPaths(",
            "if promoteResult.validCandidateCount == 0",
            "throw Self.invalidOnlySelectionError(",
            "persistAndReply(",
            "mutated: promoteResult.mutated"
        ], in: promote)
        XCTAssertFalse(promote.contains("if strict, !promoteResult.mutated"))

        let demote = try XCTUnwrap(source.slice(from: "        case \"demote\":", to: "        case \"clear\":"))
        try Self.assertOrdered([
            "let demoteResult = await dependencies.selection.demoteStoredSelectionPaths(",
            "if demoteResult.validCandidateCount == 0",
            "throw Self.invalidOnlySelectionError(",
            "persistAndReply(",
            "mutated: demoteResult.mutated"
        ], in: demote)
        XCTAssertFalse(demote.contains("if strict, !demoteResult.mutated"))

        let persistence = try XCTUnwrap(source.slice(
            from: "    private func persistAndReply(",
            to: "    static func requireCanonicalSelection("
        ))
        try Self.assertOrdered([
            "} else if mutated {",
            "persistResolvedTabContextSnapshot(",
            "} else {",
            "canonicalSelection = baseContext.selection"
        ], in: persistence)
        XCTAssertEqual(
            persistence.components(separatedBy: "persistResolvedTabContextSnapshot(").count - 1,
            1
        )
    }

    func testPromoteDemoteInvalidOnlyDiagnosticsMapToInvalidParamsToolErrors() {
        let error = MCPSelectionToolProvider.invalidOnlySelectionError(
            invalidPaths: ["outside/Sources/A.swift"],
            fallback: "unused fallback"
        )
        XCTAssertEqual(
            String(describing: error),
            "[-32602] Invalid params: Invalid selection inputs: outside/Sources/A.swift"
        )

        let fallback = MCPSelectionToolProvider.invalidOnlySelectionError(
            invalidPaths: [],
            fallback: "promote could not resolve any files"
        )
        XCTAssertEqual(
            String(describing: fallback),
            "[-32602] Invalid params: promote could not resolve any files"
        )
    }

    func testCloseTabRepairsBoundNonActiveContextAfterCommit() throws {
        let source = try Self.source("Sources/RepoPromptMCP/DirectHeadlessWorkspaceBackends.swift")
        let body = try XCTUnwrap(source.slice(
            from: "        var selectedContextID: UUID?",
            to: "    private func resolveWorkspace("
        ))

        try Self.assertOrdered([
            "var expectedClosedBinding: DomainBinding?",
            "closedContextID = targetID",
            "scope.binding.ordinaryContextMatches(",
            "let outcome = await runtime.workspaceStore.execute(",
            "command: .replaceWorkingDocument(replacement)",
            "try requireApplied(outcome)",
            "compareAndSetBinding(",
            "expectedBinding: expectedClosedBinding",
            "repairedBinding = casResult.snapshot.binding",
            "result[\"binding\"] = bindingValue(repairedBinding)",
            "if action == \"create_tab\", let selectedContextID"
        ], in: body)
        XCTAssertFalse(body.contains("let boundContext = bindingContext(scope.binding)"))
        XCTAssertFalse(body.contains("standaloneScopeCoordinator.unbind(scopeID: scopeID)"))
    }

    func testDurableFileActionDoesNotReenterStoreForPostMutationIngress() throws {
        let source = try Self.source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
        let body = try XCTUnwrap(source.slice(
            from: "    private func performFileAction(\n",
            to: "    /// Creates a **new** file"
        ))
        let postMutation = try XCTUnwrap(body.slice(
            from: "        // The filesystem mutation is durable.",
            to: "        var acknowledgementWarnings: [String] = []"
        ))

        XCTAssertTrue(postMutation.contains("let freshness = \"fresh\""))
        XCTAssertFalse(postMutation.contains("awaitAppliedIngressForExplicitRequest"))
        XCTAssertFalse(postMutation.contains("awaitAppliedIngressForExplicitRequests"))
        try Self.assertOrdered([
            "MCPToolExecutionHandlerPhaseContext.report(.fileActionsPostMutationCatalog)",
            "let freshness = \"fresh\"",
            "MCPToolExecutionHandlerPhaseContext.report(.fileActionsPostMutationCatalog, transition: .completed)"
        ], in: postMutation)
    }

    func testFileActionsOperationIDSchemaDescribesCorrelationWithoutJournalSemantics() throws {
        let source = try Self.source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
        let body = try XCTUnwrap(source.privateFunction(named: "fileActionsTool"))

        XCTAssertTrue(body.contains("caller-stable correlation ID"))
        XCTAssertTrue(body.contains("not a deduplication or status lookup key"))
        XCTAssertFalse(body.contains("reconciling a lost mutation reply"))
    }

    func testFileActionsToolConvertsRetryableMutationFailureToStructuredReply() throws {
        let source = try Self.source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift")
        let body = try XCTUnwrap(source.privateFunction(named: "fileActionsTool"))

        try Self.assertOrdered([
            "let acknowledgement = try await dependencies.files.performFileAction(action, path, content, newPath, ifExists, operationID)",
            "catch let failure as MCPMutationRetryableFailure",
            "ToolResultDTOs.FileActionReply.retryableFailure(",
            "failure: failure"
        ], in: body)
    }

    func testAgentModeUnresolvedFileToolContextFailsClosedInsteadOfVisibleWorkspaceFallback() throws {
        let source = try Self.source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift")
        let body = try XCTUnwrap(source.slice(
            from: "        guard let resolved else {",
            to: "        if let frozenLookupContext = resolved.snapshot.frozenLookupContext"
        ))

        try Self.assertOrdered([
            "guard let resolved else {",
            "if purpose == .agentModeRun",
            "return AgentWorkspaceLookupContextResolver.failClosedLookupContext",
            "return WorkspaceLookupContext(rootScope: baseScope, bindingProjection: nil)"
        ], in: body)
    }

    func testFileActionRetryableFailureDTOAndFormatterExposeCode() throws {
        let failure = MCPMutationRetryableFailure.worktreeScopeUnavailable(missingPhysicalRootPaths: [])
        let dto = ToolResultDTOs.FileActionReply.retryableFailure(
            action: "create",
            path: "Sources/New.swift",
            newPath: nil,
            failure: failure
        )
        let value = try Value(dto)

        let decoded = try XCTUnwrap(value.decode(ToolResultDTOs.FileActionReply.self))
        XCTAssertEqual(decoded.status, "failed")
        XCTAssertEqual(decoded.errorCode, "worktree_scope_unavailable")
        XCTAssertEqual(decoded.retryable, true)
        XCTAssertEqual(decoded.retryAfterMilliseconds, 1000)

        let text = try Self.onlyText(ToolOutputFormatter.formatFileAction(value: value))
        XCTAssertTrue(text.contains("## File Action ❌"), text)
        XCTAssertTrue(text.contains("**Code**: worktree_scope_unavailable"), text)
        XCTAssertTrue(text.contains("Retryable: yes"), text)
        XCTAssertTrue(text.contains("Retry after: 1000 ms"), text)
    }

    func testApplyEditsFailureSummaryFormattingExposesRetryableCode() throws {
        let failure = MCPMutationRetryableFailure.worktreeScopeUnavailable(missingPhysicalRootPaths: [])
        let dto = ToolResultDTOs.EditSummary(
            status: "failed",
            editsRequested: 1,
            editsApplied: 0,
            addedLines: nil,
            deletedLines: nil,
            totalLinesChanged: nil,
            totalChunks: nil,
            results: nil,
            unifiedDiff: nil,
            cardUnifiedDiff: nil,
            note: nil,
            fileCreated: nil,
            fileOverwritten: nil,
            reviewStatus: nil,
            rejectionReason: nil,
            requiresUserApproval: nil,
            errorMessage: failure.errorMessage,
            errorCode: failure.errorCode,
            retryable: failure.retryable,
            retryAfterMilliseconds: failure.retryAfterMilliseconds,
            suggestion: failure.suggestion
        )
        let value = try Value(dto)

        let decoded = try XCTUnwrap(value.decode(ToolResultDTOs.EditSummary.self))
        XCTAssertEqual(decoded.status, "failed")
        XCTAssertEqual(decoded.errorCode, "worktree_scope_unavailable")
        XCTAssertEqual(decoded.retryable, true)

        let text = try Self.onlyText(ToolOutputFormatter.formatApplyEdits(value: value, emitResources: false))
        XCTAssertTrue(text.contains("### Error"), text)
        XCTAssertFalse(text.contains("### Notes"), text)
        XCTAssertEqual(text.components(separatedBy: failure.errorMessage).count - 1, 1, text)
        XCTAssertTrue(text.contains("**Code**: worktree_scope_unavailable"), text)
        XCTAssertTrue(text.contains("Retryable: yes"), text)
        XCTAssertTrue(text.contains("Retry after: 1000 ms"), text)
    }

    func testApplyEditsFailedWithoutErrorMetadataOmitsEmptyErrorHeading() throws {
        let dto = ToolResultDTOs.EditSummary(
            status: "failed",
            editsRequested: 1,
            editsApplied: 0,
            addedLines: nil,
            deletedLines: nil,
            totalLinesChanged: nil,
            totalChunks: nil,
            results: nil,
            unifiedDiff: nil,
            cardUnifiedDiff: nil,
            note: nil,
            fileCreated: nil,
            fileOverwritten: nil,
            reviewStatus: nil,
            rejectionReason: nil,
            requiresUserApproval: nil,
            errorMessage: nil,
            errorCode: nil,
            retryable: nil,
            retryAfterMilliseconds: nil,
            suggestion: nil
        )
        let value = try Value(dto)

        let text = try Self.onlyText(ToolOutputFormatter.formatApplyEdits(value: value, emitResources: false))
        XCTAssertFalse(text.contains("### Error"), text)
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: RepoRoot.url().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func assertOrdered(
        _ needles: [String],
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var lowerBound = source.startIndex
        for needle in needles {
            let range = try XCTUnwrap(
                source.range(of: needle, range: lowerBound ..< source.endIndex),
                "Missing ordered source fragment: \(needle)",
                file: file,
                line: line
            )
            lowerBound = range.upperBound
        }
    }

    private static func onlyText(_ content: [MCP.Tool.Content]) throws -> String {
        guard content.count == 1 else {
            XCTFail("Expected one content block, got \(content.count)")
            return ""
        }
        guard case let .text(text, _, _) = content[0] else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let startRange = range(of: startMarker),
              let endRange = range(of: endMarker, range: startRange.upperBound ..< endIndex)
        else {
            return nil
        }
        return String(self[startRange.lowerBound ..< endRange.lowerBound])
    }

    func privateFunction(named name: String) -> String? {
        let startMarker = "    private func \(name)"
        guard let startRange = range(of: startMarker) else { return nil }
        let nextFunctionMarker = "\n    private func "
        let nextSearchStart = startRange.upperBound
        let end = range(of: nextFunctionMarker, range: nextSearchStart ..< endIndex)?.lowerBound ?? endIndex
        return String(self[startRange.lowerBound ..< end])
    }
}
