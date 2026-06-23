import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

private actor RuntimeRootScopeAvailabilityController {
    private var availability: WorkspaceLookupRootScopeAvailability = .available

    func current() -> WorkspaceLookupRootScopeAvailability {
        availability
    }

    func makeUnavailable(missingPhysicalRootPaths: [String]) {
        availability = .sessionWorktreeUnavailable(
            missingPhysicalRootPaths: missingPhysicalRootPaths
        )
    }
}

private actor RuntimeFileToolDependencySpy {
    private(set) var legacyCallCount = 0
    private(set) var downstreamQueryCallCount = 0
    private(set) var runtimeContentSnapshotCallCount = 0
    private(set) var catalogAccessCallCount = 0

    func recordLegacyCall() {
        legacyCallCount += 1
    }

    func recordDownstreamQueryCall() {
        downstreamQueryCallCount += 1
    }

    func recordRuntimeContentSnapshotCall() {
        runtimeContentSnapshotCallCount += 1
    }

    func recordCatalogAccessCall() {
        catalogAccessCallCount += 1
    }
}

final class MCPRuntimeFileToolServicesTests: XCTestCase {
    func testRuntimeSafePathsRootsAndFilesUseOnlyFrozenQueryContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPRuntimeFileTools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("first\nstruct RuntimeOnly {}\nlast\n".utf8).write(to: source)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path, kind: .primaryWorkspace)
        let dependencySpy = RuntimeFileToolDependencySpy()
        let runtimeID = WorkspaceRuntimeID()
        let sessionID = WorkspaceSessionID()
        let ticket = MCPRuntimeAdapterTicket(
            windowID: 7,
            runtimeID: runtimeID,
            sessionID: sessionID,
            adapterID: UUID(),
            mappingGeneration: 1,
            authoritativeSnapshotSequence: 1
        )
        func context(query: WorkspaceSessionQueryCapability) -> MCPRuntimeFileToolContext {
            MCPRuntimeFileToolContext(
                adapterTicket: ticket,
                runtimeID: runtimeID,
                sessionID: sessionID,
                query: query,
                lookupContext: WorkspaceLookupContext(rootScope: .visibleWorkspace, bindingProjection: nil),
                filePathDisplay: .relative,
                codeMapsEnabled: true
            )
        }

        let runtimeContext = context(query: WorkspaceSessionQueryCapability(
            roots: { await store.roots() },
            rootScopeAvailability: { scope in await store.rootScopeAvailability(scope) },
            catalogGeneration: { scope in await store.catalogGeneration(rootScope: scope) },
            catalogDiagnostics: { scope in await store.catalogDiagnostics(rootScope: scope) },
            searchCatalogAccess: { scope, requirement in
                await store.searchCatalogAccess(rootScope: scope, requirement: requirement)
            },
            lookupPath: { request in await store.lookupPath(request) },
            readExactCatalogFile: { file, root in
                await store.readExactCatalogFile(file, expectedRoot: root)
            },
            searchContentSnapshot: { file, freshnessPolicy in
                await dependencySpy.recordRuntimeContentSnapshotCall()
                return try await store.searchContentSnapshot(
                    for: file,
                    freshnessPolicy: freshnessPolicy
                )
            },
            rootRefs: { scope in await store.rootRefs(scope: scope) },
            awaitAppliedIngress: { scope in
                _ = await store.awaitAppliedIngress(rootScope: scope)
            },
            exactPathResolutionIssue: { path, kind, scope in
                await store.exactPathResolutionIssue(for: path, kind: kind, rootScope: scope)
            },
            codemapSnapshotBundle: { scope in
                await store.codemapSnapshotBundle(rootScope: scope)
            },
            fileTreeSnapshot: { selection, request, profile in
                await store.makeFileTreeSelectionSnapshot(
                    selection: selection,
                    request: request,
                    profile: profile
                )
            }
        ))

        func transitionQuery(
            controller: RuntimeRootScopeAvailabilityController,
            missingPhysicalRootPaths: [String],
            useStoreLookup: Bool
        ) -> WorkspaceSessionQueryCapability {
            WorkspaceSessionQueryCapability(
                roots: { await store.roots() },
                rootScopeAvailability: { _ in await controller.current() },
                catalogGeneration: { scope in
                    await store.catalogGeneration(rootScope: scope)
                },
                catalogDiagnostics: { scope in
                    await store.catalogDiagnostics(rootScope: scope)
                },
                searchCatalogAccess: { scope, requirement in
                    await store.searchCatalogAccess(
                        rootScope: scope,
                        requirement: requirement
                    )
                },
                lookupPath: { request in
                    let lookup: WorkspacePathLookupResult? = if useStoreLookup {
                        await store.lookupPath(request)
                    } else {
                        nil
                    }
                    await controller.makeUnavailable(
                        missingPhysicalRootPaths: missingPhysicalRootPaths
                    )
                    return lookup
                },
                searchContentSnapshot: { file, freshnessPolicy in
                    try await store.searchContentSnapshot(
                        for: file,
                        freshnessPolicy: freshnessPolicy
                    )
                },
                awaitAppliedIngress: { scope in
                    _ = await store.awaitAppliedIngress(rootScope: scope)
                },
                exactPathResolutionIssue: { path, kind, scope in
                    await store.exactPathResolutionIssue(
                        for: path,
                        kind: kind,
                        rootScope: scope
                    )
                }
            )
        }
        let files = try await MCPRuntimeFileToolServices.resolveCodeStructureFiles(
            paths: [source.path],
            context: runtimeContext
        )
        XCTAssertEqual(files.map(\.standardizedFullPath), [source.standardizedFileURL.path])

        let roots = try await MCPRuntimeFileToolServices.fileTree(
            type: "roots",
            mode: "full",
            maxDepth: nil,
            startPath: nil,
            context: runtimeContext
        )
        XCTAssertEqual(roots.rootsCount, 1)
        XCTAssertTrue(roots.tree.contains(root.lastPathComponent))

        let tree = try await MCPRuntimeFileToolServices.fileTree(
            type: "files",
            mode: "full",
            maxDepth: nil,
            startPath: nil,
            context: runtimeContext
        )
        XCTAssertTrue(tree.tree.contains("App.swift"))

        let readContent = try await MCPRuntimeFileToolServices.executeRuntimeOrLegacy(
            runtimeContext: runtimeContext,
            runtimeWasAdmitted: true,
            toolName: MCPWindowToolName.readFile,
            runtimeOperation: { context in
                let result = try await MCPRuntimeFileToolServices.readFile(
                    path: source.path,
                    startLine1Based: 2,
                    lineCount: 1,
                    context: context
                )
                XCTAssertEqual(result.reply.firstLine, 2)
                XCTAssertEqual(result.reply.lastLine, 2)
                XCTAssertEqual(result.reply.displayPath, "Sources/App.swift")
                return result.reply.content
            },
            legacyOperation: {
                await dependencySpy.recordLegacyCall()
                return "legacy read"
            }
        )
        XCTAssertEqual(
            readContent.trimmingCharacters(in: .whitespacesAndNewlines),
            "struct RuntimeOnly {}"
        )

        let searchResults = try await MCPRuntimeFileToolServices.executeRuntimeOrLegacy(
            runtimeContext: runtimeContext,
            runtimeWasAdmitted: true,
            toolName: MCPWindowToolName.search,
            runtimeOperation: { context in
                try await MCPRuntimeFileToolServices.fileSearch(
                    request: MCPRuntimeFileSearchRequest(
                        pattern: "RuntimeOnly",
                        mode: .content,
                        isRegex: false,
                        maxResults: 10,
                        pathLimiters: [source.deletingLastPathComponent().path],
                        includeExtensions: [".swift"],
                        excludePatterns: [],
                        contextLines: 1,
                        wholeWord: false,
                        countOnly: false,
                        fuzzySpaceMatching: false
                    ),
                    context: context
                ).results
            },
            legacyOperation: {
                await dependencySpy.recordLegacyCall()
                return SearchResults()
            }
        )
        XCTAssertEqual(searchResults.matches?.count, 1)
        XCTAssertEqual(searchResults.matches?.first?.lineNumber, 1)
        XCTAssertEqual(searchResults.matches?.first?.lineText, "struct RuntimeOnly {}")

        let bracketSearch = try await MCPRuntimeFileToolServices.fileSearch(
            request: MCPRuntimeFileSearchRequest(
                pattern: "RuntimeOnly",
                mode: .content,
                isRegex: false,
                maxResults: 10,
                pathLimiters: ["Sources/[A-Z]pp.swift"],
                includeExtensions: [".swift"],
                excludePatterns: [],
                contextLines: 0,
                wholeWord: false,
                countOnly: false,
                fuzzySpaceMatching: false
            ),
            context: runtimeContext
        ).results
        XCTAssertEqual(bracketSearch.scopedFileCount, 1)
        XCTAssertEqual(bracketSearch.matches?.count, 1)

        let unmatchedPrefixSearch = try await MCPRuntimeFileToolServices.executeRuntimeOrLegacy(
            runtimeContext: runtimeContext,
            runtimeWasAdmitted: true,
            toolName: MCPWindowToolName.search,
            runtimeOperation: { context in
                try await MCPRuntimeFileToolServices.fileSearch(
                    request: MCPRuntimeFileSearchRequest(
                        pattern: "RuntimeOnly",
                        mode: .content,
                        isRegex: false,
                        maxResults: 10,
                        pathLimiters: ["MissingScope"],
                        includeExtensions: [".swift"],
                        excludePatterns: [],
                        contextLines: 0,
                        wholeWord: false,
                        countOnly: false,
                        fuzzySpaceMatching: false
                    ),
                    context: context
                ).results
            },
            legacyOperation: {
                await dependencySpy.recordLegacyCall()
                return SearchResults()
            }
        )
        XCTAssertEqual(unmatchedPrefixSearch.scopedFileCount, 0)
        XCTAssertTrue(unmatchedPrefixSearch.matches?.isEmpty ?? true)

        let missingSource = root.appendingPathComponent("Sources/Missing.swift").path
        do {
            let _: String = try await MCPRuntimeFileToolServices.executeRuntimeOrLegacy(
                runtimeContext: runtimeContext,
                runtimeWasAdmitted: true,
                toolName: MCPWindowToolName.readFile,
                runtimeOperation: { context in
                    _ = try await MCPRuntimeFileToolServices.readFile(
                        path: missingSource,
                        startLine1Based: nil,
                        lineCount: nil,
                        context: context
                    )
                    return "runtime read"
                },
                legacyOperation: {
                    await dependencySpy.recordLegacyCall()
                    return "legacy read"
                }
            )
            XCTFail("A permanent runtime miss must fail without legacy fallback")
        } catch let error as MCPRuntimeFileToolServiceError {
            XCTAssertEqual(error, .pathNotFound(missingSource))
        }

        do {
            let _: String = try await MCPRuntimeFileToolServices.executeRuntimeOrLegacy(
                runtimeContext: nil,
                runtimeWasAdmitted: true,
                toolName: MCPWindowToolName.readFile,
                runtimeOperation: { _ in "runtime read" },
                legacyOperation: {
                    await dependencySpy.recordLegacyCall()
                    return "legacy read"
                }
            )
            XCTFail("An admitted request without file context must fail without legacy fallback")
        } catch {
            XCTAssertTrue(String(describing: error).contains("admitted runtime file context"))
        }

        let readMissController = RuntimeRootScopeAvailabilityController()
        let readMissContext = context(query: transitionQuery(
            controller: readMissController,
            missingPhysicalRootPaths: [],
            useStoreLookup: false
        ))
        do {
            let _: String = try await MCPRuntimeFileToolServices.executeRuntimeOrLegacy(
                runtimeContext: readMissContext,
                runtimeWasAdmitted: true,
                toolName: MCPWindowToolName.readFile,
                runtimeOperation: { context in
                    _ = try await MCPRuntimeFileToolServices.readFile(
                        path: missingSource,
                        startLine1Based: nil,
                        lineCount: nil,
                        context: context
                    )
                    return "runtime read"
                },
                legacyOperation: {
                    await dependencySpy.recordLegacyCall()
                    return "legacy read"
                }
            )
            XCTFail("A transient readiness loss must supersede pathNotFound")
        } catch let error as MCPRuntimeFileToolServiceError {
            XCTAssertEqual(error, .workspaceReadinessUnavailable)
        }

        let folderReadController = RuntimeRootScopeAvailabilityController()
        let folderReadContext = context(query: transitionQuery(
            controller: folderReadController,
            missingPhysicalRootPaths: ["/missing-worktree"],
            useStoreLookup: true
        ))
        do {
            let _: String = try await MCPRuntimeFileToolServices.executeRuntimeOrLegacy(
                runtimeContext: folderReadContext,
                runtimeWasAdmitted: true,
                toolName: MCPWindowToolName.readFile,
                runtimeOperation: { context in
                    _ = try await MCPRuntimeFileToolServices.readFile(
                        path: source.deletingLastPathComponent().path,
                        startLine1Based: nil,
                        lineCount: nil,
                        context: context
                    )
                    return "runtime read"
                },
                legacyOperation: {
                    await dependencySpy.recordLegacyCall()
                    return "legacy read"
                }
            )
            XCTFail("A transient worktree loss must supersede pathIsNotFile")
        } catch let error as MCPRuntimeFileToolServiceError {
            XCTAssertEqual(
                error,
                .worktreeScopeUnavailable(missingPhysicalRootPaths: ["/missing-worktree"])
            )
        }

        let codeStructureMissController = RuntimeRootScopeAvailabilityController()
        let codeStructureMissContext = context(query: transitionQuery(
            controller: codeStructureMissController,
            missingPhysicalRootPaths: ["/missing-worktree"],
            useStoreLookup: false
        ))
        do {
            let _: String = try await MCPRuntimeFileToolServices.executeRuntimeOrLegacy(
                runtimeContext: codeStructureMissContext,
                runtimeWasAdmitted: true,
                toolName: MCPWindowToolName.getCodeStructure,
                runtimeOperation: { context in
                    _ = try await MCPRuntimeFileToolServices.resolveCodeStructureFiles(
                        paths: [missingSource],
                        context: context
                    )
                    return "runtime code structure"
                },
                legacyOperation: {
                    await dependencySpy.recordLegacyCall()
                    return "legacy code structure"
                }
            )
            XCTFail("A transient worktree loss must supersede code-structure pathNotFound")
        } catch let error as MCPRuntimeFileToolServiceError {
            XCTAssertEqual(
                error,
                .worktreeScopeUnavailable(missingPhysicalRootPaths: ["/missing-worktree"])
            )
        }

        let searchMissController = RuntimeRootScopeAvailabilityController()
        let searchMissContext = context(query: transitionQuery(
            controller: searchMissController,
            missingPhysicalRootPaths: ["/missing-worktree"],
            useStoreLookup: false
        ))
        do {
            _ = try await MCPRuntimeFileToolServices.executeRuntimeOrLegacy(
                runtimeContext: searchMissContext,
                runtimeWasAdmitted: true,
                toolName: MCPWindowToolName.search,
                runtimeOperation: { context in
                    try await MCPRuntimeFileToolServices.fileSearch(
                        request: MCPRuntimeFileSearchRequest(
                            pattern: "RuntimeOnly",
                            mode: .content,
                            isRegex: false,
                            maxResults: 10,
                            pathLimiters: ["MissingScope"],
                            includeExtensions: [".swift"],
                            excludePatterns: [],
                            contextLines: 0,
                            wholeWord: false,
                            countOnly: false,
                            fuzzySpaceMatching: false
                        ),
                        context: context
                    ).results
                },
                legacyOperation: {
                    await dependencySpy.recordLegacyCall()
                    return SearchResults()
                }
            )
            XCTFail("A transient worktree loss must supersede an empty prefix scope")
        } catch let error as MCPRuntimeFileToolServiceError {
            XCTAssertEqual(
                error,
                .worktreeScopeUnavailable(missingPhysicalRootPaths: ["/missing-worktree"])
            )
        }

        let legacyCallCount = await dependencySpy.legacyCallCount
        let runtimeContentSnapshotCallCount = await dependencySpy.runtimeContentSnapshotCallCount
        XCTAssertEqual(legacyCallCount, 0)
        XCTAssertGreaterThan(runtimeContentSnapshotCallCount, 0)

        let unavailableQuery = WorkspaceSessionQueryCapability(
            roots: { [] },
            rootScopeAvailability: { _ in
                .sessionWorktreeUnavailable(missingPhysicalRootPaths: [])
            },
            catalogGeneration: { _ in 0 },
            catalogDiagnostics: { scope in
                WorkspaceCatalogDiagnostics(
                    generation: 0,
                    rootScope: scope,
                    rootCount: 0,
                    folderCount: 0,
                    fileCount: 0
                )
            },
            searchCatalogAccess: { _, _ in
                await dependencySpy.recordCatalogAccessCall()
                return .unavailable(.sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
            },
            lookupPath: { _ in
                await dependencySpy.recordDownstreamQueryCall()
                return nil
            },
            fileTreeSnapshot: { _, request, _ in
                await dependencySpy.recordDownstreamQueryCall()
                return FileTreeSelectionSnapshot.empty(request: request)
            }
        )
        let unavailableContext = context(query: unavailableQuery)

        do {
            _ = try await MCPRuntimeFileToolServices.fileTree(
                type: "roots",
                mode: "full",
                maxDepth: nil,
                startPath: nil,
                context: unavailableContext
            )
            XCTFail("Unavailable runtime tree readiness must fail closed")
        } catch let error as MCPRuntimeFileToolServiceError {
            XCTAssertEqual(error, .workspaceReadinessUnavailable)
        }

        do {
            _ = try await MCPRuntimeFileToolServices.resolveCodeStructureFiles(
                paths: [source.path],
                context: unavailableContext
            )
            XCTFail("Unavailable runtime code-structure readiness must fail closed")
        } catch let error as MCPRuntimeFileToolServiceError {
            XCTAssertEqual(error, .workspaceReadinessUnavailable)
        }
        var downstreamQueryCallCount = await dependencySpy.downstreamQueryCallCount
        var catalogAccessCallCount = await dependencySpy.catalogAccessCallCount
        XCTAssertEqual(downstreamQueryCallCount, 0)
        XCTAssertEqual(catalogAccessCallCount, 0)

        let unavailableCatalogQuery = WorkspaceSessionQueryCapability(
            roots: { [] },
            rootScopeAvailability: { _ in .available },
            catalogGeneration: { _ in 0 },
            catalogDiagnostics: { scope in
                WorkspaceCatalogDiagnostics(
                    generation: 0,
                    rootScope: scope,
                    rootCount: 0,
                    folderCount: 0,
                    fileCount: 0
                )
            },
            searchCatalogAccess: { _, _ in
                await dependencySpy.recordCatalogAccessCall()
                return .unavailable(.sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
            },
            lookupPath: { _ in
                await dependencySpy.recordDownstreamQueryCall()
                return nil
            },
            fileTreeSnapshot: { _, request, _ in
                await dependencySpy.recordDownstreamQueryCall()
                return FileTreeSelectionSnapshot.empty(request: request)
            }
        )
        let unavailableCatalogContext = context(query: unavailableCatalogQuery)
        for operation in ["tree", "code_structure"] {
            do {
                if operation == "tree" {
                    _ = try await MCPRuntimeFileToolServices.fileTree(
                        type: "roots",
                        mode: "full",
                        maxDepth: nil,
                        startPath: nil,
                        context: unavailableCatalogContext
                    )
                } else {
                    _ = try await MCPRuntimeFileToolServices.resolveCodeStructureFiles(
                        paths: [source.path],
                        context: unavailableCatalogContext
                    )
                }
                XCTFail("Unavailable runtime catalog must fail closed for \(operation)")
            } catch let error as MCPRuntimeFileToolServiceError {
                XCTAssertEqual(error, .workspaceReadinessUnavailable)
            }
        }
        downstreamQueryCallCount = await dependencySpy.downstreamQueryCallCount
        catalogAccessCallCount = await dependencySpy.catalogAccessCallCount
        XCTAssertEqual(downstreamQueryCallCount, 0)
        XCTAssertEqual(catalogAccessCallCount, 2)
    }
}
