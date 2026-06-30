import Darwin
import Foundation
import MCP
@testable import RepoPrompt
import RepoPromptShared
import XCTest

private extension ToolResultDTOs.CodeStructureReplyDTO {
    var fileCount: Int {
        summary.returnedFiles
    }

    var content: String {
        files.map(\.content).joined(separator: "\n")
    }

    var pendingPaths: [String]? {
        issuePaths { $0.retryable }
    }

    var unmappedPaths: [String]? {
        issuePaths { issue in
            guard !issue.retryable else { return false }
            switch issue.code {
            case "path_not_found", "outside_root_scope", "unsupported_file",
                 "artifact_unavailable", "git_root_unavailable":
                return true
            default:
                return false
            }
        }
    }

    private func issuePaths(
        matching predicate: (ToolResultDTOs.CodeStructureReplyDTO.IssueDTO) -> Bool
    ) -> [String]? {
        let paths = issues.compactMap { issue -> String? in
            guard predicate(issue) else { return nil }
            return issue.path
        }
        return paths.isEmpty ? nil : paths
    }
}

@MainActor
final class MCPCodeStructureWorktreeTests: XCTestCase {
    func testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logical = try repositories.makeRepository(
            named: "logical",
            files: ["Sources/App.swift": "struct CanonicalOnly {}\n"]
        )
        let physical = try repositories.makeRepository(
            named: "physical-secret",
            files: [
                "Sources/App.swift": "protocol AppProtocol { func run() }\nstruct WorktreeApp: AppProtocol { func run() {} }\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: logical)
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logical.path
        )
        let setupPhysicalRoot = try await store.loadRoot(path: physical.path, kind: .sessionWorktree)
        let setupFile = try await fileRecord(
            at: physical.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: .allLoaded
        )
        let setupTicket = try await readyTicket(
            store: store,
            fileID: setupFile.id,
            timeout: .seconds(30)
        )
        _ = await store.cancelCodemapArtifactDemand(setupTicket)
        await store.unloadRoot(id: setupPhysicalRoot.id)

        let physicalRoot = try await store.loadRoot(path: physical.path, kind: .sessionWorktree)
        let projection = makeProjection(
            logicalRoot: logicalRoot,
            physicalRoot: physicalRoot,
            worktreeID: "logical-result"
        )
        let context = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let file = try await fileRecord(
            at: physical.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let structureRequest = request()
        let firstDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: structureRequest,
            includePathNotFoundIssue: true,
            lookupContext: context
        )
        let secondDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: structureRequest,
            includePathNotFoundIssue: true,
            lookupContext: context
        )

        for dto in [firstDTO, secondDTO] {
            XCTAssertEqual(dto.status, "ready")
            XCTAssertEqual(dto.files.count, 1)
            let renderedFile = try XCTUnwrap(dto.files.first)
            XCTAssertEqual(renderedFile.path, "\(logicalRoot.name)/Sources/App.swift")
            XCTAssertEqual(renderedFile.role, "seed")
            XCTAssertEqual(renderedFile.depth, 0)
            XCTAssertTrue(renderedFile.content.contains("WorktreeApp"), renderedFile.content)
            XCTAssertFalse(renderedFile.content.contains("CanonicalOnly"), renderedFile.content)
            XCTAssertFalse(renderedFile.content.contains(physical.standardizedFileURL.path), renderedFile.content)
            XCTAssertEqual(dto.summary.codemapContentTokens, renderedFile.tokens)
            let mapping = try XCTUnwrap(dto.worktreeScope?.rootMappings.first)
            XCTAssertEqual(mapping.logicalRootPath, logicalRoot.name)
            XCTAssertEqual(mapping.effectiveRootPath, "session-bound")
            XCTAssertEqual(mapping.worktreeID, "logical-result")
            XCTAssertFalse(mapping.logicalRootPath.contains(physical.standardizedFileURL.path))
        }

        let rootLifetimeID = try await store.rootLifetimeIDForTesting(rootID: physicalRoot.id)
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: physicalRoot.id,
            rootLifetimeID: rootLifetimeID
        )
        let markerBeforeTreeValue = await store.codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: rootEpoch
        )
        let markerBeforeTree = try XCTUnwrap(markerBeforeTreeValue)
        XCTAssertEqual(markerBeforeTree.changes.map(\.fileID), [file.id])
        XCTAssertEqual(markerBeforeTree.changes.map(\.state), [.ready])
        let storeWorkBeforeTree = await store.codemapPresentationOperationCountsForTesting()
        let engineWorkBeforeTreeValue = await store.codemapBindingEngineAccountingForTesting(
            rootID: physicalRoot.id
        )
        let engineWorkBeforeTree = try XCTUnwrap(engineWorkBeforeTreeValue)

        let tree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: StoredSelection(),
            request: WorkspaceFileTreePresentationRequest(
                mode: .full,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: true,
                rootScope: projection.lookupRootScope
            ),
            lookupContext: context,
            profile: .mcpRead
        )

        XCTAssertTrue(tree.content.contains("App.swift +"), tree.content)
        XCTAssertTrue(tree.content.contains("(+ denotes code-map available)"), tree.content)
        XCTAssertTrue(tree.content.contains(logicalRoot.name), tree.content)
        XCTAssertFalse(tree.content.contains(physical.standardizedFileURL.path), tree.content)
        XCTAssertFalse(tree.content.contains("physical-secret"), tree.content)
        let markerAfterTree = await store.codemapMarkerReadinessSnapshotForTesting(rootEpoch: rootEpoch)
        XCTAssertEqual(markerAfterTree?.revision, markerBeforeTree.revision)
        XCTAssertEqual(markerAfterTree?.changes, markerBeforeTree.changes)
        let storeWorkAfterTree = await store.codemapPresentationOperationCountsForTesting()
        // Ready codemap demand publication owns graph publication asynchronously. This
        // passive tree render must not request fresh structure/demand/candidate work, but
        // awaiting the snapshot/logical-root presentation may give an already-scheduled
        // graph worker one chance to drain.
        XCTAssertEqual(
            storeWorkAfterTree.structureSeedAdmissionRequests,
            storeWorkBeforeTree.structureSeedAdmissionRequests
        )
        XCTAssertEqual(
            storeWorkAfterTree.selectedMetadataResolutionRequests,
            storeWorkBeforeTree.selectedMetadataResolutionRequests
        )
        XCTAssertEqual(
            storeWorkAfterTree.presentationCandidateRequests,
            storeWorkBeforeTree.presentationCandidateRequests
        )
        XCTAssertEqual(storeWorkAfterTree.artifactDemandRequests, storeWorkBeforeTree.artifactDemandRequests)
        XCTAssertEqual(
            storeWorkAfterTree.presentationFreezeRequests,
            storeWorkBeforeTree.presentationFreezeRequests
        )
        XCTAssertEqual(storeWorkAfterTree.setupTasksCreated, storeWorkBeforeTree.setupTasksCreated)
        XCTAssertEqual(storeWorkAfterTree.demandTasksCreated, storeWorkBeforeTree.demandTasksCreated)
        XCTAssertEqual(storeWorkAfterTree.targetedReadyFreezes, storeWorkBeforeTree.targetedReadyFreezes)
        XCTAssertEqual(storeWorkAfterTree.graphBatchSignals, storeWorkBeforeTree.graphBatchSignals)
        XCTAssertEqual(
            storeWorkAfterTree.projectionRecoveryObserversStarted,
            storeWorkBeforeTree.projectionRecoveryObserversStarted
        )
        XCTAssertEqual(
            storeWorkAfterTree.projectionRecoveryObserverRearms,
            storeWorkBeforeTree.projectionRecoveryObserverRearms
        )
        let graphDrainDeltas = [
            storeWorkAfterTree.fullRootGraphFreezes - storeWorkBeforeTree.fullRootGraphFreezes,
            storeWorkAfterTree.graphBatchFlushes - storeWorkBeforeTree.graphBatchFlushes,
            storeWorkAfterTree.graphWorkerStarts - storeWorkBeforeTree.graphWorkerStarts
        ]
        XCTAssertTrue(
            graphDrainDeltas.allSatisfy { 0 ... 1 ~= $0 },
            "Unexpected graph-worker drain deltas: \(graphDrainDeltas)"
        )
        XCTAssertEqual(
            Set(graphDrainDeltas).count,
            1,
            "Graph-worker drain counters should advance together: \(graphDrainDeltas)"
        )
        let engineWorkAfterTree = await store.codemapBindingEngineAccountingForTesting(
            rootID: physicalRoot.id
        )
        XCTAssertEqual(engineWorkAfterTree, engineWorkBeforeTree)
    }

    func testNonGitRootReturnsTypedUnavailableWithoutLegacySnapshotBuild() async throws {
        let root = try makeTemporaryRoot(name: "NonGit")
        let fileURL = root.appendingPathComponent("Sources/App.swift")
        try write("struct PlainFile {}\n", to: fileURL)
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        _ = try await fileRecord(at: fileURL, store: store, rootScope: .visibleWorkspace)

        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "code-structure-zero-git",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.getCodeStructure })
        let requestIdentity = MCPRequestTimelineIdentity(
            jsonRPCRequestID: .number(8001),
            connectionID: connectionID.uuidString,
            connectionGeneration: 1,
            appInvocationID: UUID().uuidString,
            requestOrdinal: 1
        )
        MCPToolWorkCountDiagnostics.resetForTesting()

        let value = try await MCPRequestTimelineContext.$current.withValue(requestIdentity) {
            try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool([
                    "scope": .string("paths"),
                    "paths": .array([.string(fileURL.path)])
                ])
            }
        }

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "unavailable")
        XCTAssertTrue(object["files"]?.arrayValue?.isEmpty == true)
        let issueCodes = object["issues"]?.arrayValue?.compactMap {
            $0.objectValue?["code"]?.stringValue
        }
        XCTAssertTrue(issueCodes?.contains("git_root_unavailable") == true)
        let invocations = MCPToolWorkCountDiagnostics.debugSnapshots().git
        XCTAssertEqual(invocations.count, 1)
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(invocation.operation, MCPWindowToolName.getCodeStructure)
        assertNonGitEligibilityDiagnosticShape(invocation)
        XCTAssertEqual(invocation.outcome, "success")
        XCTAssertEqual(invocation.requestIdentity, requestIdentity)

        let repeatedRequestIdentity = MCPRequestTimelineIdentity(
            jsonRPCRequestID: .number(8002),
            connectionID: connectionID.uuidString,
            connectionGeneration: 1,
            appInvocationID: UUID().uuidString,
            requestOrdinal: 2
        )
        let repeatedValue = try await MCPRequestTimelineContext.$current.withValue(repeatedRequestIdentity) {
            try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool([
                    "scope": .string("paths"),
                    "paths": .array([.string(fileURL.path)])
                ])
            }
        }
        let repeatedObject = try XCTUnwrap(repeatedValue.objectValue)
        XCTAssertEqual(repeatedObject["status"]?.stringValue, "unavailable")
        XCTAssertTrue(repeatedObject["issues"]?.arrayValue?.contains {
            $0.objectValue?["code"]?.stringValue == "git_root_unavailable"
        } == true)
        let repeatedInvocations = MCPToolWorkCountDiagnostics.debugSnapshots().git
        XCTAssertEqual(repeatedInvocations.count, 2)
        for invocation in repeatedInvocations {
            assertNonGitEligibilityDiagnosticShape(invocation)
        }
        XCTAssertEqual(repeatedInvocations.map(\.requestIdentity), [requestIdentity, repeatedRequestIdentity])
    }

    func testWaitMillisecondsParameterIsNotExposedAndIsRejected() async throws {
        let root = try makeTemporaryRoot(name: "WaitPolicy")
        let fileURL = root.appendingPathComponent("Sources/App.swift")
        try write("struct PlainFile {}\n", to: fileURL)
        let window = try await makeWindow(root: root)
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "code-structure-wait-policy",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.getCodeStructure })
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        let limitsSchema = try XCTUnwrap(properties["limits"]?.objectValue)
        let limitProperties = try XCTUnwrap(limitsSchema["properties"]?.objectValue)
        XCTAssertNil(limitProperties["wait_ms"])
        let invoke: ([String: Value]?) async throws -> Value = { submittedLimits in
            var arguments: [String: Value] = [
                "scope": .string("paths"),
                "paths": .array([.string(fileURL.path)])
            ]
            if let submittedLimits {
                arguments["limits"] = .object(submittedLimits)
            }
            return try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool(arguments)
            }
        }

        window.mcpServer.resetLastCodeStructureRequestForTesting()
        _ = try await invoke(nil)
        XCTAssertEqual(window.mcpServer.capturedCodeStructureRequestForTesting(), request())

        window.mcpServer.resetLastCodeStructureRequestForTesting()
        do {
            _ = try await invoke(["wait_ms": .int(10000)])
            XCTFail("Expected wait_ms to be rejected as an unknown limits parameter")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("unknown limits parameter"),
                "Unexpected error: \(error)"
            )
        }
        XCTAssertNil(window.mcpServer.capturedCodeStructureRequestForTesting())
    }

    func testReadinessPressureDTOsAreTypedEmptyAndRetryConsistent() throws {
        let rendered = try renderedStructureEntry()
        let cases: [(
            outcome: WorkspaceCodemapStructureOutcome,
            issue: WorkspaceCodemapStructureIssue,
            status: String,
            code: String,
            retryAfterMilliseconds: Int?
        )] = [
            (.busy, .busy(retryAfterMilliseconds: 1), "busy", "codemap_busy", 25),
            (
                .timeout,
                .readinessTimeout(
                    elapsedMilliseconds: 9876,
                    limitMilliseconds: 10000,
                    retryAfterMilliseconds: 5000
                ),
                "timeout",
                "readiness_timeout",
                1000
            ),
            (
                .unavailable,
                .projectionUnavailable(reason: .generationMismatch, retryAfterMilliseconds: 75),
                "unavailable",
                "projection_unavailable",
                75
            ),
            (
                .unavailable,
                .projectionUnavailable(reason: .capabilityUnavailable, retryAfterMilliseconds: nil),
                "unavailable",
                "projection_unavailable",
                nil
            )
        ]

        for item in cases {
            let presentation = WorkspaceCodemapStructurePresentation(
                outcome: item.outcome,
                entries: [rendered],
                issues: [item.issue],
                requestedSeedCount: 1,
                resolvedSeedCount: 1,
                examinedEdgeCount: 9,
                codemapTokenCount: 7
            )
            let dto = MCPServerViewModel.codeStructureReplyDTO(
                presentation: presentation,
                logicalPathsByFileID: [rendered.entry.fileID: rendered.entry.logicalPath.displayPath],
                worktreeScope: nil
            )

            XCTAssertEqual(dto.status, item.status)
            XCTAssertTrue(dto.files.isEmpty)
            XCTAssertEqual(dto.summary.returnedFiles, 0)
            XCTAssertEqual(dto.summary.codemapContentTokens, 0)
            XCTAssertEqual(dto.summary.examinedEdges, 0)
            let issue = try XCTUnwrap(dto.issues.first { $0.code == item.code })
            XCTAssertEqual(issue.retryable, item.retryAfterMilliseconds != nil)
            XCTAssertEqual(issue.retryAfterMilliseconds, item.retryAfterMilliseconds)
            XCTAssertEqual(dto.retry?.retryAfterMilliseconds, item.retryAfterMilliseconds)
            XCTAssertEqual(dto.retry?.retryable, item.retryAfterMilliseconds == nil ? nil : true)
            if item.code == "readiness_timeout" {
                XCTAssertEqual(issue.attempted, 9876)
                XCTAssertEqual(issue.limit, 10000)
            }
        }

        for legacyOutcome in [WorkspaceCodemapStructureOutcome.partial, .pending] {
            let dto = MCPServerViewModel.codeStructureReplyDTO(
                presentation: WorkspaceCodemapStructurePresentation(
                    outcome: legacyOutcome,
                    entries: [rendered],
                    issues: [],
                    requestedSeedCount: 1,
                    resolvedSeedCount: 1,
                    examinedEdgeCount: 9,
                    codemapTokenCount: 7
                ),
                logicalPathsByFileID: [rendered.entry.fileID: rendered.entry.logicalPath.displayPath],
                worktreeScope: nil
            )
            XCTAssertEqual(dto.status, "timeout")
            XCTAssertTrue(dto.files.isEmpty)
            XCTAssertEqual(dto.issues.map(\.code), ["readiness_timeout"])
            XCTAssertEqual(dto.issues.first?.attempted, 10000)
            XCTAssertEqual(dto.issues.first?.limit, 10000)
            XCTAssertNotNil(dto.retry?.retryAfterMilliseconds)
        }

        let projectionBudget = WorkspaceCodemapProjectionBudget(
            dimension: .retainedProjectionBytes,
            attempted: 2049,
            limit: 2048
        )
        let budgetDTO = MCPServerViewModel.codeStructureReplyDTO(
            presentation: WorkspaceCodemapStructurePresentation(
                outcome: .budget,
                entries: [],
                issues: [.projectionBudget(projectionBudget)],
                requestedSeedCount: 1,
                resolvedSeedCount: 0,
                examinedEdgeCount: 0,
                codemapTokenCount: 0
            ),
            logicalPathsByFileID: [:],
            worktreeScope: nil
        )
        XCTAssertEqual(budgetDTO.status, "budget")
        XCTAssertEqual(budgetDTO.issues.map(\.code), ["projection_budget"])
        XCTAssertEqual(budgetDTO.issues.first?.attempted, 2049)
        XCTAssertEqual(budgetDTO.issues.first?.limit, 2048)
        XCTAssertNil(budgetDTO.retry)
    }

    func testStrictTokenBudgetNeverAdmitsOversizedFirstEntry() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Large.swift": (0 ..< 80).map {
                    "struct Type\($0) { func method\($0)() -> String { \"\($0)\" } }"
                }.joined(separator: "\n")
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let file = try await fileRecord(
            at: root.appendingPathComponent("Sources/Large.swift"),
            store: store,
            rootScope: .visibleWorkspace
        )
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let primed = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumCodemapTokens: 6000),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        XCTAssertEqual(primed.status, "ready")
        XCTAssertTrue(primed.content.contains("Type0"), primed.content)

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumCodemapTokens: 1),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(dto.status, "budget")
        XCTAssertTrue(dto.files.isEmpty)
        XCTAssertEqual(dto.summary.codemapContentTokens, 0)
        XCTAssertTrue(dto.issues.contains { $0.code == "token_limit" })
    }

    func testBoundedDirectoryExpansionRejectsAtLimitPlusOneBeforeDownstreamWork() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": "struct One {}\n",
                "Sources/Nested/Two.swift": "struct Two {}\n",
                "Sources/Three.swift": "struct Three {}\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "bounded-code-structure",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first {
            $0.name == MCPWindowToolName.getCodeStructure
        })
        window.mcpServer.resetCodeStructureAdmissionWorkCountsForTesting()

        let value = try await ServerNetworkManager.withConnectionID(connectionID) {
            try await tool([
                "scope": .string("paths"),
                "paths": .array([.string(root.appendingPathComponent("Sources").path)]),
                "limits": .object(["max_files": .int(1)])
            ])
        }

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "budget")
        XCTAssertTrue(object["files"]?.arrayValue?.isEmpty == true)
        let issue = try XCTUnwrap(object["issues"]?.arrayValue?.compactMap(\.objectValue).first {
            $0["phase"]?.stringValue == "seed_demand"
        })
        XCTAssertEqual(issue["code"]?.stringValue, "hard_budget_exceeded")
        XCTAssertEqual(issue["attempted"]?.intValue, 2)
        XCTAssertEqual(issue["limit"]?.intValue, 1)

        let admission = window.mcpServer.codeStructureAdmissionWorkCountsForTesting()
        XCTAssertEqual(admission.uniqueSeedCandidatesVisited, 2)
        XCTAssertEqual(admission.logicalPathComputations, 0)
        XCTAssertEqual(admission.coordinatorInvocations, 0)
    }

    func testSelectedScopeRejectsAtLimitPlusOneWithoutContentOrCodemapWork() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": "struct One {}\n",
                "Sources/Two.swift": "struct Two {}\n",
                "Sources/Three.swift": "struct Three {}\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let rootRefs = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(rootRefs.first)
        let files = await store.files(inRoot: loadedRoot.id).sorted {
            $0.standardizedFullPath < $1.standardizedFullPath
        }
        XCTAssertEqual(files.count, 3)
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        var composeTab = try XCTUnwrap(window.workspaceManager.composeTab(with: tabID))
        composeTab.selection = StoredSelection(selectedPaths: files.map(\.standardizedFullPath))
        window.workspaceManager.updateComposeTab(composeTab, markDirty: false)

        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "bounded-selected-code-structure",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first { $0.name == MCPWindowToolName.getCodeStructure })
        let contentReads = CodeStructureContentReadCounter()
        let fileSystemServiceCandidate = await store.fileSystemServiceForTesting(rootID: loadedRoot.id)
        let fileSystemService = try XCTUnwrap(fileSystemServiceCandidate)
        await fileSystemService.setContentReadChunkHandlerForTesting { _ in
            await contentReads.increment()
        }
        window.mcpServer.resetCodeStructureAdmissionWorkCountsForTesting()

        let value = try await ServerNetworkManager.withConnectionID(connectionID) {
            try await tool([
                "scope": .string("selected"),
                "limits": .object(["max_files": .int(1)])
            ])
        }
        await fileSystemService.setContentReadChunkHandlerForTesting(nil)

        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["status"]?.stringValue, "budget")
        let issue = try XCTUnwrap(object["issues"]?.arrayValue?.compactMap(\.objectValue).first {
            $0["phase"]?.stringValue == "seed_demand"
        })
        XCTAssertEqual(issue["code"]?.stringValue, "hard_budget_exceeded")
        XCTAssertEqual(issue["attempted"]?.intValue, 2)
        XCTAssertEqual(issue["limit"]?.intValue, 1)
        let contentReadCount = await contentReads.value
        XCTAssertEqual(contentReadCount, 0)

        let admission = window.mcpServer.codeStructureAdmissionWorkCountsForTesting()
        XCTAssertEqual(admission.uniqueSeedCandidatesVisited, 2)
        XCTAssertEqual(admission.logicalPathComputations, 0)
        XCTAssertEqual(admission.coordinatorInvocations, 0)
    }

    func testSelectedScopeStaleFolderIsIgnoredWhileExactRootAliasResolves() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "CurrentParent/SelectedFolder/Only.swift": "struct Only {}\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let rootRefs = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(rootRefs.first)
        let staleFolderPath = "StaleParent/SelectedFolder"

        let staleResolution = await store.resolveSelectedCodeStructureFiles(
            atPaths: [staleFolderPath],
            rootScope: .visibleWorkspace,
            maximumUniqueFileCount: 10
        )
        XCTAssertFalse(staleResolution.didExceedLimit)
        XCTAssertTrue(staleResolution.files.isEmpty)
        XCTAssertEqual(staleResolution.visitedUniqueFileCount, 0)

        let exactAliasResolution = await store.resolveSelectedCodeStructureFiles(
            atPaths: ["\(loadedRoot.name)/CurrentParent/SelectedFolder"],
            rootScope: .visibleWorkspace,
            maximumUniqueFileCount: 10
        )
        XCTAssertFalse(exactAliasResolution.didExceedLimit)
        XCTAssertEqual(
            exactAliasResolution.files.map(\.standardizedRelativePath),
            ["CurrentParent/SelectedFolder/Only.swift"]
        )
    }

    func testPhysicalPathDedupAvoidsFalseOverflowAcrossOverlappingRoots() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: ["Sources/Shared.swift": "struct Shared {}\n"]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let outerRoot = try XCTUnwrap(roots.first { $0.standardizedFullPath == root.standardizedFileURL.path })
        let nestedRoot = try await store.loadRoot(path: root.appendingPathComponent("Sources").path)
        let outerFiles = await store.files(inRoot: outerRoot.id)
        let nestedFiles = await store.files(inRoot: nestedRoot.id)
        let outerFile = try XCTUnwrap(outerFiles.first)
        let nestedFile = try XCTUnwrap(nestedFiles.first)
        XCTAssertNotEqual(outerFile.id, nestedFile.id)
        XCTAssertEqual(outerFile.standardizedFullPath, nestedFile.standardizedFullPath)

        let boundedExpansion = await store.expandFolderInputToFiles(
            root.appendingPathComponent("Sources").path,
            rootScope: .allLoaded,
            profile: .mcpSelection,
            excludingStandardizedFullPaths: [nestedFile.standardizedFullPath],
            maximumUniqueFileCount: 0
        )
        XCTAssertTrue(boundedExpansion.handled)
        XCTAssertFalse(boundedExpansion.didExceedLimit)
        XCTAssertTrue(boundedExpansion.files.isEmpty)
        XCTAssertEqual(boundedExpansion.visitedUniqueFileCount, 0)

        window.mcpServer.resetCodeStructureAdmissionWorkCountsForTesting()
        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [outerFile, nestedFile],
            request: request(maximumFiles: 1, maximumCodemapTokens: 0),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        )

        XCTAssertFalse(dto.issues.contains { $0.code == "hard_budget_exceeded" })
        XCTAssertTrue(dto.issues.contains { $0.code == "token_limit" })
        let admission = window.mcpServer.codeStructureAdmissionWorkCountsForTesting()
        XCTAssertEqual(admission.logicalPathComputations, 1)
        XCTAssertEqual(admission.coordinatorInvocations, 1)
    }

    func testSeedDemandBudgetRejectsExpandedSeedsBeforeDemand() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/One.swift": "struct One {}\n",
                "Sources/Two.swift": "struct Two {}\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        XCTAssertEqual(files.count, 2)

        window.mcpServer.resetCodeStructureAdmissionWorkCountsForTesting()
        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            request: request(maximumFiles: 1),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(dto.status, "budget")
        XCTAssertTrue(dto.files.isEmpty)
        XCTAssertEqual(dto.summary.resolvedSeeds, 0)
        let issue = try XCTUnwrap(dto.issues.first { $0.phase == "seed_demand" })
        XCTAssertEqual(issue.code, "hard_budget_exceeded")
        XCTAssertEqual(issue.attempted, 2)
        XCTAssertEqual(issue.limit, 1)
        let admission = window.mcpServer.codeStructureAdmissionWorkCountsForTesting()
        XCTAssertEqual(admission.logicalPathComputations, 0)
        XCTAssertEqual(admission.coordinatorInvocations, 0)
    }

    func testSeedOrderingAndOutputAreDeterministic() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Zeta.swift": "struct Zeta { func zeta() {} }\n",
                "Sources/Alpha.swift": "struct Alpha { func alpha() {} }\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        XCTAssertEqual(files.count, 2)
        let tickets = try await files.asyncMap { try await readyTicket(store: store, fileID: $0.id) }
        defer {
            Task {
                for ticket in tickets {
                    _ = await store.cancelCodemapArtifactDemand(ticket)
                }
            }
        }

        let first = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: Array(files.reversed()),
            request: request(),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        let second = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            request: request(),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.status, "ready")
        XCTAssertEqual(first.files.count, 2)
        XCTAssertTrue(first.files[0].path.hasSuffix("Sources/Alpha.swift"), first.files[0].path)
        XCTAssertTrue(first.files[1].path.hasSuffix("Sources/Zeta.swift"), first.files[1].path)
    }

    func testResidentForwardAndReverseExpansionUseRootLocalBoundedTraversal() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: [
                "Sources/Source.swift": """
                struct Source {
                    let target: Target
                }
                """,
                "Sources/Target.swift": "struct Target { func targetMethod() {} }\n"
            ]
        )
        addTeardownBlock { repositories.cleanup() }
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        let source = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Source.swift"
        })
        let target = try XCTUnwrap(files.first {
            $0.standardizedRelativePath == "Sources/Target.swift"
        })
        let sourceTicket = try await readyTicket(store: store, fileID: source.id)
        let targetTicket = try await readyTicket(store: store, fileID: target.id)
        addTeardownBlock {
            _ = await store.cancelCodemapArtifactDemand(sourceTicket)
            _ = await store.cancelCodemapArtifactDemand(targetTicket)
        }
        let graphClock = ContinuousClock()
        let graphReady = await store.waitForCodemapGraphPublication(
            rootEpoch: sourceTicket.rootEpoch,
            deadline: graphClock.now.advanced(by: .seconds(8))
        )
        XCTAssertTrue(graphReady, "Timed out waiting for root-local codemap graph publication")

        let forward = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [source],
            request: request(direction: .referencedDefinitions, maximumDepth: 2),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        XCTAssertEqual(forward.status, "ready")
        XCTAssertTrue(forward.issues.isEmpty)
        XCTAssertEqual(forward.files.count, 2)
        XCTAssertEqual(forward.files.map(\.path), [
            "repository/Sources/Source.swift",
            "repository/Sources/Target.swift"
        ])
        XCTAssertEqual(forward.files.map(\.role), ["seed", "related"])
        XCTAssertEqual(forward.files.map(\.depth), [0, 1])
        let forwardRelated = try XCTUnwrap(forward.files.first { $0.role == "related" })
        XCTAssertEqual(forwardRelated.reachedBy, ["referenced_definitions"])

        let reverse = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [target],
            request: request(direction: .referrers, maximumDepth: 2),
            includePathNotFoundIssue: true,
            lookupContext: .visibleWorkspace
        )
        XCTAssertEqual(reverse.status, "ready")
        XCTAssertTrue(reverse.issues.isEmpty)
        XCTAssertEqual(reverse.files.count, 2)
        XCTAssertEqual(reverse.files.map(\.path), [
            "repository/Sources/Target.swift",
            "repository/Sources/Source.swift"
        ])
        XCTAssertEqual(reverse.files.map(\.role), ["seed", "related"])
        XCTAssertEqual(reverse.files.map(\.depth), [0, 1])
        let reverseRelated = try XCTUnwrap(reverse.files.first { $0.role == "related" })
        XCTAssertEqual(reverseRelated.reachedBy, ["referrers"])
    }

    func testStoreCanScanSessionWorktreeRoot() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let worktreeRootURL = try repositories.makeRepository(
            named: "direct-scan-worktree",
            files: [
                "App.swift": "struct DirectSessionWorktreeType {\n    func directMethod() {}\n}\n"
            ]
        )
        defer { repositories.cleanup() }

        let codemapFixture = try MCPCodeStructureCodemapRuntimeFixture(name: #function)
        addTeardownBlock {
            await codemapFixture.shutdown()
        }
        let store = codemapFixture.makeStore()
        let root = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let content = try await store.readContent(rootID: root.id, relativePath: "App.swift", workloadClass: .codemap)
        XCTAssertTrue(content?.contains("DirectSessionWorktreeType") == true)
        let loadedFile = await store.file(rootID: root.id, relativePath: "App.swift")
        let file = try XCTUnwrap(loadedFile)
        let ticket = try await readyTicket(store: store, fileID: file.id, timeout: .seconds(30))
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let presentation = try await WorkspaceCodemapPresentationCoordinator(store: store)
            .presentation(
                for: .exact(fileIDs: [file.id], completeRootSet: false),
                rootScope: .allLoaded
            )
        XCTAssertEqual(presentation.coverage, .complete)
        let rendered = try XCTUnwrap(presentation.orderedEntries.first)
        XCTAssertTrue(rendered.text.contains("DirectSessionWorktreeType"), rendered.text)
    }

    func testMissingWorktreeSnapshotReturnsPendingThenRendersRefreshedLogicalPath() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: [
                "Sources/App.swift": "struct CanonicalOnlyType {\n    func canonicalMethod() {}\n}\n"
            ]
        )
        let worktreeRootURL = try repositories.makeRepository(
            named: "worktree",
            files: [
                "Sources/App.swift": "struct WorktreeOnlyType {\n    func worktreeMethod() {}\n}\n"
            ]
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "worktree")
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let file = try await fileRecord(
            at: worktreeRootURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )

        let pendingDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        if pendingDTO.status == "pending" {
            XCTAssertEqual(pendingDTO.fileCount, 0)
            XCTAssertEqual(pendingDTO.pendingPaths, ["Sources/App.swift"])
            XCTAssertNil(pendingDTO.unmappedPaths)
        } else {
            XCTAssertEqual(pendingDTO.status, "ready")
        }
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let refreshedDTO = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        XCTAssertEqual(refreshedDTO.status, "ready")
        XCTAssertEqual(refreshedDTO.fileCount, 1)
        XCTAssertTrue(refreshedDTO.content.contains("WorktreeOnlyType"), refreshedDTO.content)
        XCTAssertFalse(refreshedDTO.content.contains("CanonicalOnlyType"), refreshedDTO.content)
        XCTAssertTrue(refreshedDTO.content.contains("Sources/App.swift"), refreshedDTO.content)
        XCTAssertFalse(refreshedDTO.content.contains(worktreeRoot.standardizedFullPath), refreshedDTO.content)
        XCTAssertNil(refreshedDTO.pendingPaths)
        let mapping = try XCTUnwrap(refreshedDTO.worktreeScope?.rootMappings.first)
        XCTAssertEqual(mapping.effectiveRootPath, "session-bound")
    }

    func testSwitchingCodeStructureScopeFromWorktreeAToBDoesNotReuseA() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: ["Sources/App.swift": "struct CanonicalSwitchType {}\n"]
        )
        let worktreeAURL = try repositories.makeRepository(
            named: "switch-a",
            files: ["Sources/App.swift": "struct WorktreeAType {\n    func branchAMethod() {}\n}\n"]
        )
        let worktreeBURL = try repositories.makeRepository(
            named: "switch-b",
            files: ["Sources/App.swift": "struct WorktreeBType {\n    func branchBMethod() {}\n}\n"]
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let logicalRef = WorkspaceRootRef(
            id: logicalRoot.id,
            name: logicalRoot.name,
            fullPath: logicalRoot.standardizedFullPath
        )
        let sessionID = UUID()
        let materializedA = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [makeBinding(
                logicalRoot: logicalRef,
                physicalRoot: WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: worktreeAURL.path),
                worktreeID: "A"
            )]
        )
        let projectionA = try XCTUnwrap(materializedA)
        let fileA = try await fileRecord(
            at: worktreeAURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projectionA.lookupRootScope
        )
        let ticketA = try await readyTicket(store: store, fileID: fileA.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticketA) } }
        let dtoA = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [fileA],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: projectionA.lookupRootScope, bindingProjection: projectionA)
        )
        XCTAssertEqual(dtoA.status, "ready")
        XCTAssertTrue(dtoA.content.contains("WorktreeAType"), dtoA.content)

        let materializedB = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [makeBinding(
                logicalRoot: logicalRef,
                physicalRoot: WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: worktreeBURL.path),
                worktreeID: "B"
            )]
        )
        let projectionB = try XCTUnwrap(materializedB)
        let fileB = try await fileRecord(
            at: worktreeBURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projectionB.lookupRootScope
        )
        let ticketB = try await readyTicket(store: store, fileID: fileB.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticketB) } }
        let dtoB = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [fileA, fileB],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: projectionB.lookupRootScope, bindingProjection: projectionB)
        )

        XCTAssertEqual(dtoB.status, "ready")
        XCTAssertEqual(dtoB.fileCount, 1)
        XCTAssertTrue(dtoB.content.contains("WorktreeBType"), dtoB.content)
        XCTAssertFalse(dtoB.content.contains("WorktreeAType"), dtoB.content)
        XCTAssertFalse(dtoB.content.contains("CanonicalSwitchType"), dtoB.content)
        XCTAssertEqual(dtoB.worktreeScope?.rootMappings.first?.worktreeID, "B")
    }

    func testDeletedMaterializedWorktreeFailsClosedInsteadOfReturningCachedStructure() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: [
                "Sources/App.swift": "struct CanonicalDeletedType {\n    func canonicalMethod() {}\n}\n"
            ]
        )
        let worktreeRootURL = try repositories.makeRepository(
            named: "deleted-worktree",
            files: [
                "Sources/App.swift": "struct CachedDeletedWorktreeType {\n    func cachedMethod() {}\n}\n"
            ]
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let worktreeRoot = try await store.loadRoot(path: worktreeRootURL.path, kind: .sessionWorktree)
        let projection = makeProjection(logicalRoot: logicalRoot, physicalRoot: worktreeRoot, worktreeID: "deleted")
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let file = try await fileRecord(
            at: worktreeRootURL.appendingPathComponent("Sources/App.swift"),
            store: store,
            rootScope: projection.lookupRootScope
        )
        let ticket = try await readyTicket(store: store, fileID: file.id)
        defer { Task { _ = await store.cancelCodemapArtifactDemand(ticket) } }

        let primed = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        XCTAssertEqual(primed.status, "ready")
        XCTAssertTrue(primed.content.contains("CachedDeletedWorktreeType"), primed.content)
        try FileManager.default.removeItem(at: worktreeRootURL)

        let unavailable = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: lookupContext
        )
        XCTAssertEqual(unavailable.status, "unavailable")
        XCTAssertTrue(unavailable.files.isEmpty)
        XCTAssertTrue(unavailable.issues.contains { $0.code == "git_root_unavailable" })
        XCTAssertFalse(unavailable.issues.contains { $0.message.contains(worktreeRootURL.standardizedFileURL.path) })

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        XCTAssertEqual(
            availability,
            .sessionWorktreeUnavailable(missingPhysicalRootPaths: [worktreeRootURL.standardizedFileURL.path])
        )
    }

    func testTargetedSelfHealingIsBoundedByMaxResults() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let root = try repositories.makeRepository(
            named: "repository",
            files: Dictionary(uniqueKeysWithValues: (1 ... 3).map { index in
                (
                    "Sources/File\(index).swift",
                    "struct BoundedType\(index) {\n    func boundedMethod\(index)() {}\n}\n"
                )
            })
        )
        defer { repositories.cleanup() }

        let window = try await makeWindow(root: root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let loadedRoot = try XCTUnwrap(roots.first)
        let files = await store.files(inRoot: loadedRoot.id)
        XCTAssertEqual(files.count, 3)

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: files,
            request: request(maximumFiles: 1),
            includePathNotFoundIssue: false,
            lookupContext: .visibleWorkspace
        )

        XCTAssertEqual(dto.status, "budget")
        XCTAssertEqual(dto.fileCount, 0)
        XCTAssertNil(dto.pendingPaths)
        XCTAssertNil(dto.unmappedPaths)
        // Seed admission reports the bounded overflow sentinel (limit + 1), not the full input count.
        XCTAssertEqual(dto.summary.requestedSeeds, 2)
        XCTAssertEqual(dto.summary.resolvedSeeds, 0)
        let issue = try XCTUnwrap(dto.issues.first { $0.phase == "seed_demand" })
        XCTAssertEqual(issue.code, "hard_budget_exceeded")
        XCTAssertEqual(issue.attempted, 2)
        XCTAssertEqual(issue.limit, 1)
    }

    func testUnavailableWorktreeReturnsTypedIssueBeforeCanonicalRead() async throws {
        let repositories = try ReviewGitRepositoryFixture(name: #function)
        let logicalRootURL = try repositories.makeRepository(
            named: "logical",
            files: ["Sources/App.swift": "struct CanonicalUnavailableType {}\n"]
        )
        defer { repositories.cleanup() }
        let missingWorktreeURL = logicalRootURL.deletingLastPathComponent()
            .appendingPathComponent("Missing-\(UUID().uuidString)", isDirectory: true)

        let window = try await makeWindow(root: logicalRootURL)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let store = window.workspaceFileContextStore
        let logicalRoot = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: logicalRootURL.path
        )
        let logicalRef = WorkspaceRootRef(id: logicalRoot.id, name: logicalRoot.name, fullPath: logicalRoot.standardizedFullPath)
        let missingRef = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: missingWorktreeURL.path)
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRef,
                    physicalRoot: missingRef,
                    binding: makeBinding(logicalRoot: logicalRef, physicalRoot: missingRef, worktreeID: "missing")
                )
            ],
            visibleLogicalRoots: [logicalRef]
        )

        let dto = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [],
            request: request(maximumFiles: 10),
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        )
        XCTAssertEqual(dto.status, "unavailable")
        XCTAssertTrue(dto.files.isEmpty)
        XCTAssertEqual(dto.issues.map(\.code), ["git_root_unavailable"])
        XCTAssertFalse(dto.issues.contains { $0.message.contains(logicalRootURL.standardizedFileURL.path) })
        XCTAssertFalse(dto.issues.contains { $0.message.contains(missingWorktreeURL.standardizedFileURL.path) })

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        XCTAssertEqual(
            availability,
            .sessionWorktreeUnavailable(missingPhysicalRootPaths: [missingWorktreeURL.standardizedFileURL.path])
        )
    }

    private func assertNonGitEligibilityDiagnosticShape(
        _ invocation: MCPToolWorkCountDiagnostics.GitInvocationSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let commands = invocation.commands
        if invocation.commandCount == 0, commands.isEmpty {
            return
        }

        // This accepted three-command shape is non-git eligibility probing after
        // proof invalidation, not legacy snapshot-build work.
        let expectedFallbackCommands = [
            "rev-parse --show-toplevel",
            "rev-parse --show-toplevel",
            "rev-parse --is-bare-repository"
        ]
        if invocation.commandCount == expectedFallbackCommands.count,
           commands == expectedFallbackCommands
        {
            return
        }

        XCTFail(
            "Expected no git commands or exact non-git eligibility fallback commands; " +
                "got count \(invocation.commandCount):\n\(commands.joined(separator: "\n"))",
            file: file,
            line: line
        )
    }

    private func request(
        direction: WorkspaceCodemapStructureTraversalDirection? = nil,
        maximumDepth: Int = 0,
        maximumFiles: Int = 10,
        maximumCodemapTokens: Int = 6000
    ) -> MCPServerViewModel.CodeStructureRequest {
        .init(
            direction: direction,
            maximumDepth: maximumDepth,
            maximumFiles: maximumFiles,
            maximumEdges: 500,
            maximumCodemapTokens: maximumCodemapTokens
        )
    }

    private func readyTicket(
        store: WorkspaceFileContextStore,
        fileID: UUID,
        timeout: Duration = .seconds(8)
    ) async throws -> WorkspaceCodemapArtifactDemandTicket {
        var activeTicket: WorkspaceCodemapArtifactDemandTicket?
        let clock = ContinuousClock()

        do {
            var result = await store.requestCodemapArtifact(forFileID: fileID)
            var lastResultDescription = String(describing: result)
            let timeoutDescription = String(describing: timeout)
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                try Task.checkCancellation()
                lastResultDescription = String(describing: result)
                switch result {
                case let .ready(ready):
                    return ready.ticket
                case let .pending(ticket):
                    activeTicket = ticket
                    try await Task.sleep(for: .milliseconds(25))
                    result = await store.codemapArtifactDemandStatus(ticket)
                case let .unavailable(.busy(retryAfterMilliseconds)):
                    let delayMilliseconds = min(max(retryAfterMilliseconds ?? 100, 25), 1000)
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                    if let activeTicket {
                        result = await store.retryBusyCodemapArtifactDemand(activeTicket, priority: .demand)
                    } else {
                        result = await store.requestCodemapArtifact(forFileID: fileID)
                    }
                    switch result {
                    case let .ready(ready):
                        return ready.ticket
                    case let .pending(ticket):
                        activeTicket = ticket
                    case .unavailable:
                        break
                    }
                case let .unavailable(reason):
                    XCTFail("Expected ready codemap demand, got \(reason)")
                    throw NSError(domain: "MCPCodeStructureWorktreeTests", code: 2)
                }
            }
            XCTFail(
                "Timed out waiting for ready codemap demand after \(timeoutDescription); last result: \(lastResultDescription)"
            )
            throw NSError(domain: "MCPCodeStructureWorktreeTests", code: 3)
        } catch {
            if let ticket = activeTicket {
                activeTicket = nil
                _ = await store.cancelCodemapArtifactDemand(
                    ticket,
                    deadline: clock.now.advanced(by: .seconds(5))
                )
            }
            throw error
        }
    }

    private func makeWindow(root: URL) async throws -> WindowState {
        let codemapFixture = try MCPCodeStructureCodemapRuntimeFixture(name: "MCPCodeStructureWorktreeTests")
        addTeardownBlock {
            await codemapFixture.shutdown()
        }
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState(workspaceFileContextStore: codemapFixture.makeStore())
        WindowStatesManager.shared.registerWindowState(window)
        addTeardownBlock { @MainActor in
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Code Structure Worktree \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "mcpCodeStructureWorktreeTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )
        return window
    }

    private func makeProjection(
        logicalRoot: WorkspaceRootRecord,
        physicalRoot: WorkspaceRootRecord,
        worktreeID: String
    ) -> WorkspaceRootBindingProjection {
        let logicalRef = WorkspaceRootRef(
            id: logicalRoot.id,
            name: logicalRoot.name,
            fullPath: logicalRoot.standardizedFullPath
        )
        let physicalRef = WorkspaceRootRef(
            id: physicalRoot.id,
            name: logicalRoot.name,
            fullPath: physicalRoot.standardizedFullPath
        )
        return WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRef,
                    physicalRoot: physicalRef,
                    binding: makeBinding(logicalRoot: logicalRef, physicalRoot: physicalRef, worktreeID: worktreeID)
                )
            ],
            visibleLogicalRoots: [logicalRef]
        )
    }

    private func makeBinding(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef,
        worktreeID: String
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(worktreeID)",
            repositoryID: "repo-\(worktreeID)",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.standardizedFullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: worktreeID,
            worktreeRootPath: physicalRoot.standardizedFullPath,
            worktreeName: URL(fileURLWithPath: physicalRoot.standardizedFullPath).lastPathComponent,
            branch: "feature/\(worktreeID)",
            source: "test"
        )
    }

    private func renderedStructureEntry() throws -> WorkspaceCodemapStructureRenderedEntry {
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "LogicalRoot",
            standardizedRelativePath: "Sources/App.swift"
        ))
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        return WorkspaceCodemapStructureRenderedEntry(
            entry: WorkspaceCodemapOperationRenderedEntry(
                bundleID: WorkspaceCodemapFrozenPresentationBundleID(),
                fileID: UUID(),
                rootEpoch: rootEpoch,
                artifactKey: CodeMapArtifactKey(
                    rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: 1, count: 32)),
                    rawByteCount: 16,
                    pipelineIdentity: pipeline
                ),
                logicalPath: logicalPath,
                text: "struct App {}",
                tokenCount: 7
            ),
            isSeed: true,
            depth: 0,
            reachedBy: []
        )
    }

    private func fileRecord(
        at url: URL,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope
    ) async throws -> WorkspaceFileRecord {
        let result = await store.lookupPath(url.path, profile: .mcpRead, rootScope: rootScope)
        return try XCTUnwrap(result?.file)
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPCodeStructureWorktreeTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

#if DEBUG
    private actor AsyncGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func markStartedAndWaitForRelease() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }

            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(underestimatedCount)
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}

private actor CodeStructureContentReadCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class MCPCodeStructureCodemapRuntimeFixture: @unchecked Sendable {
    private let sandbox: URL
    private let provider: CodeMapArtifactRuntimeProvider

    init(name: String) throws {
        let sandbox = try Self.makeSecureDirectory(name: name)
        do {
            let artifactRoot = try Self.makeSecureDirectory(in: sandbox, named: "artifacts")
            let registry = WorkspaceCodemapBindingIntegrationRegistry()
            self.sandbox = sandbox
            provider = CodeMapArtifactRuntimeProvider {
                try CodeMapArtifactRuntime(
                    rootURL: artifactRoot,
                    bindingIntegrationRegistry: registry,
                    bindingEngineFactory: { runtime in
                        WorkspaceCodemapBindingEngine(
                            runtime: runtime,
                            capabilityService: WorkspaceCodemapGitCapabilityService(
                                namespaceSalt: Data(
                                    repeating: 0x4D,
                                    count: GitBlobRepositoryNamespace.saltByteCount
                                )
                            ),
                            sourceReader: registry.makeValidatedSourceReaderClient(),
                            catalogClient: registry.makeBindingCatalogClient()
                        )
                    }
                )
            }
            _ = try provider.runtime()
        } catch {
            try? FileManager.default.removeItem(at: sandbox)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeStore() -> WorkspaceFileContextStore {
        let provider = provider
        return WorkspaceFileContextStore(
            enableCatalogShardShadowValidation: false,
            codemapRuntimeProvider: {
                try provider.runtime()
            },
            codemapProjectionPreloadLaunchPolicyForTesting: .disabled
        )
    }

    func shutdown() async {
        if let runtime = try? provider.runtime(),
           let engine = try? runtime.bindingEngine()
        {
            await engine.shutdown()
        }
        try? FileManager.default.removeItem(at: sandbox)
    }

    private static func makeSecureDirectory(name: String) throws -> URL {
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(sanitized)-codemap-runtime-\(UUID().uuidString)",
                isDirectory: true
            )
        return try createSecureDirectory(directory, withIntermediateDirectories: true)
    }

    private static func makeSecureDirectory(in parent: URL, named name: String) throws -> URL {
        try createSecureDirectory(
            parent.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: false
        )
    }

    private static func createSecureDirectory(
        _ directory: URL,
        withIntermediateDirectories: Bool
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: withIntermediateDirectories,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedPath = try directory.path.withCString { pointer -> String in
            guard let resolved = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }
}
