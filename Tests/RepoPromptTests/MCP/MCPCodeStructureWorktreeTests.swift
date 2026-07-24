import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

@MainActor
final class MCPCodeStructureWorktreeTests: XCTestCase {
    func testPublishedSchemaHasExactlyFiveFlatOptionalFieldsAndRejectsDeprecatedUnknownFields() async throws {
        let root = try makeTemporaryRoot(name: #function)
        let fileURL = root.appendingPathComponent("Sources/App.swift")
        try write("struct App {}\n", to: fileURL)
        let window = try await makeWindow(root: root)
        let (tool, connectionID) = try await boundCodeStructureTool(window: window)

        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        XCTAssertEqual(Set(properties.keys), Set(["paths", "expand", "depth", "signatures", "max_tokens"]))
        XCTAssertNotEqual(schema["required"]?.arrayValue?.isEmpty, false)
        XCTAssertEqual(schema["additionalProperties"]?.boolValue, false)
        XCTAssertEqual(
            properties["expand"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue),
            ["uses", "used_by", "both"]
        )

        let rejected: [[String: Value]] = [
            ["scope": .string("selected")],
            ["limits": .object(["max_files": .int(10)])],
            ["max_results": .int(10)],
            ["expand": .object(["direction": .string("both")])],
            ["paths": .array([.string(fileURL.path)]), "unknown": .bool(true)]
        ]
        for arguments in rejected {
            do {
                _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                    try await tool(arguments)
                }
                XCTFail("Expected deprecated or unknown arguments to be rejected: \(arguments)")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains("unknown or deprecated") ||
                        String(describing: error).contains("expand must"),
                    "Unexpected error for \(arguments): \(error)"
                )
            }
        }
    }

    func testOnlyMaxTokensClampsAndFlatArgumentsDecodeStrictly() async throws {
        let root = try makeTemporaryRoot(name: #function)
        let fileURL = root.appendingPathComponent("Sources/App.swift")
        try write("struct App {}\n", to: fileURL)
        let window = try await makeWindow(root: root)
        let (tool, connectionID) = try await boundCodeStructureTool(window: window)

        func invoke(maxTokens: Int) async throws -> MCPServerViewModel.CodeStructureRequest {
            window.mcpServer.resetLastCodeStructureRequestForTesting()
            _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                try await tool([
                    "paths": .array([.string(fileURL.path)]),
                    "expand": .string("both"),
                    "depth": .int(4),
                    "signatures": .bool(false),
                    "max_tokens": .int(maxTokens)
                ])
            }
            return try XCTUnwrap(window.mcpServer.capturedCodeStructureRequestForTesting())
        }

        let minimum = try await invoke(maxTokens: 1)
        XCTAssertEqual(minimum.direction, .both)
        XCTAssertEqual(minimum.maximumDepth, 4)
        XCTAssertFalse(minimum.includesSignatures)
        XCTAssertEqual(minimum.budget.maximumTokenCount, 1000)
        XCTAssertEqual(minimum.budget.renderTokenCount, 0)

        let maximum = try await invoke(maxTokens: 100_000)
        XCTAssertEqual(maximum.budget.maximumTokenCount, 25000)

        let invalid: [[String: Value]] = [
            ["paths": .array([.string(fileURL.path)]), "expand": .string("referenced_definitions")],
            ["paths": .array([.string(fileURL.path)]), "depth": .int(0)],
            ["paths": .array([.string(fileURL.path)]), "signatures": .int(1)]
        ]
        for arguments in invalid {
            do {
                _ = try await ServerNetworkManager.withConnectionID(connectionID) {
                    try await tool(arguments)
                }
                XCTFail("Expected strict flat argument validation: \(arguments)")
            } catch {
                XCTAssertFalse(String(describing: error).isEmpty)
            }
        }
    }

    func testSignaturesFalsePerformsZeroArtifactDemandOrPresentationCoordination() async throws {
        let root = try makeTemporaryRoot(name: #function)
        let fileURL = root.appendingPathComponent("Sources/App.swift")
        try write("struct App {}\n", to: fileURL)
        let window = try await makeWindow(root: root)
        let store = window.workspaceFileContextStore
        let file = try await fileRecord(at: fileURL, store: store)
        let request = codeStructureRequest(includesSignatures: false)

        window.mcpServer.resetCodeStructureAdmissionWorkCountsForTesting()
        let before = await store.codemapPresentationOperationCountsForTesting()
        let reply = try await window.mcpServer.buildCodeStructureDTO(
            fromRecords: [file],
            request: request,
            includePathNotFoundIssue: true,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        )
        let after = await store.codemapPresentationOperationCountsForTesting()
        let work = window.mcpServer.codeStructureAdmissionWorkCountsForTesting()

        XCTAssertEqual(work.coordinatorInvocations, 0)
        XCTAssertEqual(after.artifactDemandRequests, before.artifactDemandRequests)
        XCTAssertEqual(after.presentationFreezeRequests, before.presentationFreezeRequests)
        XCTAssertEqual(after.demandTasksCreated, before.demandTasksCreated)
        let validStatuses: [ToolResultDTOs.CodeStructureReplyDTO.Status] = [.pending, .unavailable, .partial, .ok]
        XCTAssertTrue(validStatuses.contains(reply.status))
    }

    func testAssemblerPublishesFourStatusesMixedRootsAndLogicalPaths() {
        let expectations: [(WorkspaceCodemapStructureStatus, Bool, ToolResultDTOs.CodeStructureReplyDTO.Status)] = [
            (.ok, true, .ok),
            (.partial, true, .partial),
            (.pending, false, .pending),
            (.unavailable, false, .unavailable)
        ]
        for (status, useful, expected) in expectations {
            let root = structureRoot(name: "Project", status: status, useful: useful)
            let reply = assemble(roots: [root], aggregateStatus: status, includesSignatures: false)
            XCTAssertEqual(reply.status, expected, "status: \(status)")
        }

        let ready = structureRoot(name: "A", status: .ok, useful: true)
        let pending = structureRoot(name: "B", status: .pending, useful: false)
        let mixed = assemble(roots: [pending, ready], aggregateStatus: .partial, includesSignatures: false)
        XCTAssertEqual(mixed.status, .partial)
        XCTAssertEqual(mixed.roots.map(\.root), ["A", "B"])
        XCTAssertEqual(mixed.roots[0].nodes.map(\.path), ["A/Sources/App.swift"])
        XCTAssertEqual(mixed.roots[1].status, .pending)
        XCTAssertEqual(mixed.roots[1].seeds.first?.state, .pending)
    }

    func testReconciliationAndRenderFailurePreserveGraphEvidence() throws {
        let reconciliationIssue = WorkspaceCodemapStructureIssueRecord(
            code: "watcher_gap_reconciling",
            phase: "graph_revalidation",
            path: nil,
            retryable: true,
            retryAfterMilliseconds: 100,
            attempted: nil,
            limit: nil,
            message: "Watcher-gap reconciliation is in progress."
        )
        var root = structureRoot(name: "Project", status: .partial, useful: true)
        root = WorkspaceCodemapStructureRootResult(
            rootEpoch: root.rootEpoch,
            rootDisplayName: root.rootDisplayName,
            status: .partial,
            coverage: root.coverage,
            updatesPending: true,
            seeds: root.seeds,
            nodes: root.nodes,
            edges: root.edges,
            unresolved: root.unresolved,
            truncation: root.truncation,
            issues: [reconciliationIssue],
            receipt: nil
        )
        let presentation = WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .partial([.renderUnavailable(rootEpoch: root.rootEpoch, reason: .bundleNotRetained)]),
            issues: [.renderUnavailable(rootEpoch: root.rootEpoch, reason: .bundleNotRetained)],
            publicationReceipt: nil
        )
        let aggregate = WorkspaceCodemapStructureAggregateResult(status: .partial, roots: [root], issues: [])
        let reply = MCPServerViewModel.codeStructureReplyDTO(
            aggregate: aggregate,
            presentation: presentation,
            revalidation: [root.rootEpoch: .valid(updatesPending: true)],
            includesSignatures: true,
            budget: WorkspaceCodemapGraphPolicy.initial.queryBudget(maximumTokenCount: 6000, includesSignatures: true),
            worktreeScope: nil
        )

        XCTAssertEqual(reply.status, .partial)
        XCTAssertEqual(reply.summary.nodes, 1)
        XCTAssertEqual(reply.roots.first?.nodes.first?.path, "Project/Sources/App.swift")
        XCTAssertEqual(reply.roots.first?.updatesPending, true)
        XCTAssertTrue(reply.roots.first?.issues.contains { $0.code == "watcher_gap_reconciling" } == true)
        XCTAssertTrue(reply.issues.contains { $0.code == "signature_render_failed" })

        let renderedNode = try XCTUnwrap(root.nodes.first)
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let renderedPresentation = try WorkspaceCodemapOperationPresentation(
            orderedEntries: [WorkspaceCodemapOperationRenderedEntry(
                bundleID: WorkspaceCodemapFrozenPresentationBundleID(),
                fileID: renderedNode.fileID,
                rootEpoch: root.rootEpoch,
                artifactKey: CodeMapArtifactKey(
                    rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: 1, count: 32)),
                    rawByteCount: 20,
                    pipelineIdentity: pipeline
                ),
                logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                    rootDisplayName: "Project",
                    standardizedRelativePath: "Sources/App.swift"
                )),
                text: "struct App {}",
                tokenCount: 4
            )],
            coverage: .complete,
            issues: [],
            publicationReceipt: nil
        )
        let invalidated = MCPServerViewModel.codeStructureReplyDTO(
            aggregate: aggregate,
            presentation: renderedPresentation,
            revalidation: [root.rootEpoch: .invalid(
                code: "graph_revalidation_failed",
                message: "The root crossed a destructive fence."
            )],
            includesSignatures: true,
            budget: WorkspaceCodemapGraphPolicy.initial.queryBudget(
                maximumTokenCount: 6000,
                includesSignatures: true
            ),
            worktreeScope: nil
        )
        XCTAssertEqual(invalidated.status, .unavailable)
        XCTAssertTrue(invalidated.files.isEmpty)
        XCTAssertTrue(invalidated.roots.first?.nodes.isEmpty == true)
        XCTAssertTrue(invalidated.roots.first?.edges.isEmpty == true)
    }

    func testDeterministicTruncationAndNodeOrderingAreStable() throws {
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let root = WorkspaceCodemapStructureRootResult(
            rootEpoch: rootEpoch,
            rootDisplayName: "Project",
            status: .partial,
            coverage: nil,
            updatesPending: false,
            seeds: [.init(fileID: firstID, path: "Project/A.swift", state: .covered)],
            nodes: [
                .init(fileID: firstID, path: "Project/A.swift", depth: 0, isSeed: true, reachedBy: []),
                .init(fileID: secondID, path: "Project/B.swift", depth: 1, isSeed: false, reachedBy: [.referencedDefinitions])
            ],
            edges: [.init(fromPath: "Project/A.swift", toPath: "Project/B.swift", symbols: ["B"], ambiguous: false)],
            unresolved: [],
            truncation: .init(droppedNodeCount: 3),
            issues: [.init(code: "max_tokens", phase: "graph_traversal", path: nil, retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "Truncated")],
            receipt: nil
        )
        let first = assemble(roots: [root], aggregateStatus: .partial, includesSignatures: false)
        let second = assemble(roots: [root], aggregateStatus: .partial, includesSignatures: false)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.roots.first?.nodes.map(\.path), ["Project/A.swift", "Project/B.swift"])
        XCTAssertEqual(first.roots.first?.truncated?.reason, "max_tokens")
        XCTAssertEqual(first.roots.first?.truncated?.droppedNodes, 3)
    }

    private func assemble(
        roots: [WorkspaceCodemapStructureRootResult],
        aggregateStatus: WorkspaceCodemapStructureStatus,
        includesSignatures: Bool
    ) -> ToolResultDTOs.CodeStructureReplyDTO {
        MCPServerViewModel.codeStructureReplyDTO(
            aggregate: .init(status: aggregateStatus, roots: roots, issues: []),
            presentation: nil,
            revalidation: [:],
            includesSignatures: includesSignatures,
            budget: WorkspaceCodemapGraphPolicy.initial.queryBudget(
                maximumTokenCount: 6000,
                includesSignatures: includesSignatures
            ),
            worktreeScope: nil
        )
    }

    private func structureRoot(
        name: String,
        status: WorkspaceCodemapStructureStatus,
        useful: Bool
    ) -> WorkspaceCodemapStructureRootResult {
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let fileID = UUID()
        let path = "\(name)/Sources/App.swift"
        let issue: WorkspaceCodemapStructureIssueRecord? = switch status {
        case .ok: nil
        case .partial: .init(code: "updates_pending", phase: "graph_revalidation", path: nil, retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "Updates are pending.")
        case .pending: .init(code: "graph_indexing", phase: "graph_snapshot", path: nil, retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "Graph is indexing.")
        case .unavailable: .init(code: "graph_unavailable", phase: "graph_snapshot", path: nil, retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "Graph is unavailable.")
        }
        return WorkspaceCodemapStructureRootResult(
            rootEpoch: rootEpoch,
            rootDisplayName: name,
            status: status,
            coverage: nil,
            updatesPending: status == .partial,
            seeds: [.init(fileID: fileID, path: path, state: useful ? .covered : status == .pending ? .pending : .notIndexed)],
            nodes: useful ? [.init(fileID: fileID, path: path, depth: 0, isSeed: true, reachedBy: [])] : [],
            edges: [],
            unresolved: [],
            truncation: nil,
            issues: issue.map { [$0] } ?? [],
            receipt: nil
        )
    }

    private func codeStructureRequest(includesSignatures: Bool) -> MCPServerViewModel.CodeStructureRequest {
        .init(
            direction: nil,
            maximumDepth: 0,
            includesSignatures: includesSignatures,
            budget: WorkspaceCodemapGraphPolicy.initial.queryBudget(
                maximumTokenCount: 6000,
                includesSignatures: includesSignatures
            )
        )
    }

    private func boundCodeStructureTool(
        window: WindowState
    ) async throws -> (RepoPromptApp.Tool, UUID) {
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let connectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: connectionID,
            clientName: "phase3-code-structure-tests",
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: window.windowID
        )
        let tools = await window.mcpServer.windowMCPTools
        let tool = try XCTUnwrap(tools.first {
            $0.name == MCPWindowToolName.getCodeStructure
        })
        return (tool, connectionID)
    }

    private func makeWindow(root: URL) async throws -> WindowState {
        let codemapFixture = try MCPCodeStructureCodemapRuntimeFixture(name: #function)
        addTeardownBlock { await codemapFixture.shutdown() }
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
            name: "Code Structure Phase 3 \(UUID().uuidString.prefix(8))",
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "mcpCodeStructurePhase3Tests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        _ = try await WorkspaceRootLoadTestSupport.loadRootMatchingCurrentFileSystemSettings(
            in: window,
            path: root.path
        )
        return window
    }

    private func fileRecord(
        at url: URL,
        store: WorkspaceFileContextStore
    ) async throws -> WorkspaceFileRecord {
        let result = await store.lookupPath(url.path, profile: .mcpRead, rootScope: .allLoaded)
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
                                namespaceSalt: Data(repeating: 0x4D, count: GitBlobRepositoryNamespace.saltByteCount)
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

    deinit { try? FileManager.default.removeItem(at: sandbox) }

    func makeStore() -> WorkspaceFileContextStore {
        let provider = provider
        return WorkspaceFileContextStore(
            enableCatalogShardShadowValidation: false,
            codemapRuntimeProvider: { try provider.runtime() },
            codemapGraphIndexBuildLaunchPolicyForTesting: .disabled
        )
    }

    func shutdown() async {
        if let runtime = try? provider.runtime(), let engine = try? runtime.bindingEngine() {
            await engine.shutdown()
        }
        try? FileManager.default.removeItem(at: sandbox)
    }

    private static func makeSecureDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-codemap-runtime-\(UUID().uuidString)", isDirectory: true)
        return try createSecureDirectory(directory, withIntermediateDirectories: true)
    }

    private static func makeSecureDirectory(in parent: URL, named name: String) throws -> URL {
        try createSecureDirectory(parent.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
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
