@testable import RepoPrompt
import XCTest

final class PromptContextPreAssemblyServiceTests: XCTestCase {
    private actor CapturedPaths {
        private var value: [String] = []
        func set(_ paths: [String]) {
            value = paths
        }

        func get() -> [String] {
            value
        }
    }

    private actor ProviderCapture {
        private var requests: [AutomaticReviewGitDiffRequest] = []

        func record(_ request: AutomaticReviewGitDiffRequest) {
            requests.append(request)
        }

        func count() -> Int {
            requests.count
        }

        func lastRequest() -> AutomaticReviewGitDiffRequest? {
            requests.last
        }
    }

    private struct ArtifactFixture {
        let repositoryFixture: ReviewGitRepositoryFixture
        let repoRoot: URL
        let workspace: URL
        let mapURL: URL
        let patchURL: URL
        let sourceURL: URL
        let store: WorkspaceFileContextStore
        let reviewContext: FrozenPromptGitReviewContext
    }

    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testResolveUsesWorktreeContentAndLogicalizesFileTree() async throws {
        let fixture = try await makeBoundFixture()
        let request = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .complete),
            selection: StoredSelection(selectedPaths: ["Sources/App.swift"], codemapAutoEnabled: false),
            store: fixture.store,
            lookupContext: fixture.lookupContext,
            filePathDisplay: .full,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .filesOnly,
            reviewGitContext: .automaticOnly(),
            selectedGitDiffProvider: { _ in Self.automaticResult("unexpected selected diff") },
            completeGitDiffProvider: { "base checkout complete diff must not appear" }
        )

        let result = await PromptContextPreAssemblyService.resolve(request)

        XCTAssertEqual(result.physicalSelection.selectedPaths, [fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path])
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertTrue(result.entries.first?.loadedContent?.contains("worktree") ?? false)
        XCTAssertFalse(result.entries.first?.loadedContent?.contains("base") ?? true)
        XCTAssertTrue(result.fileTreeContent?.contains(fixture.logicalRoot.standardizedFileURL.path) ?? false, result.fileTreeContent ?? "")
        XCTAssertFalse(result.fileTreeContent?.contains(fixture.worktreeRoot.standardizedFileURL.path) ?? true, result.fileTreeContent ?? "")
        XCTAssertEqual(result.gitDiff, PromptContextGitDiffPolicy.deferredCompleteWorktreeGitDiffMessage)
    }

    func testResolveSelectedDiffUsesPhysicalizedSelectionAndPolicy() async throws {
        let fixture = try await makeBoundFixture()
        let captured = CapturedPaths()
        let request = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .selected),
            selection: StoredSelection(selectedPaths: ["Sources"], codemapAutoEnabled: false),
            store: fixture.store,
            lookupContext: fixture.lookupContext,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .expandFolders,
            selectedGitDiffLookupProfile: .uiAssisted,
            reviewGitContext: .automaticOnly(),
            selectedGitDiffProvider: { automaticRequest in
                await captured.set(automaticRequest.pathResolution.paths)
                return Self.automaticResult("selected diff")
            },
            completeGitDiffProvider: { "unexpected complete diff" }
        )

        let result = await PromptContextPreAssemblyService.resolve(request)
        let paths = await captured.get()

        XCTAssertEqual(result.gitDiff, "selected diff")
        XCTAssertEqual(Set(paths), Set([
            fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path,
            fixture.worktreeRoot.appendingPathComponent("Sources/Keep.swift").standardizedFileURL.path
        ]))
        XCTAssertFalse(paths.contains(fixture.logicalRoot.appendingPathComponent("Sources/App.swift").standardizedFileURL.path))
    }

    func testCanonicalAutoCodemapsDrivePreassemblyAndClipboardWithoutHiddenRediscovery() async throws {
        let root = try makeTemporaryRoot(name: "PromptPreAssemblyCanonicalCodemap")
        let selectedURL = root.appendingPathComponent("Selected.swift")
        let targetURL = root.appendingPathComponent("Target.swift")
        let selectedContent = "let selectedFullContentSentinel = TargetType()\n"
        let targetContent = "struct TargetType { func targetFullContentSentinel() {} }\n"
        try FileSystemTestSupport.write(selectedContent, to: selectedURL)
        try FileSystemTestSupport.write(targetContent, to: targetURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        await store.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: selectedURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: selectedURL.path,
                    symbolName: "selectedCodemapSymbol",
                    referencedTypes: ["TargetType"]
                )
            ),
            WorkspaceObservedCodemapResult(
                fullPath: targetURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(
                    path: targetURL.path,
                    symbolName: "targetCodemapSymbol",
                    className: "TargetType"
                )
            )
        ])
        let lookupContext = WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)

        let hiddenRediscoveryRequest = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .none, codeMapUsage: .auto),
            selection: StoredSelection(
                selectedPaths: [selectedURL.path],
                autoCodemapPaths: [],
                codemapAutoEnabled: false
            ),
            store: store,
            lookupContext: lookupContext,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .expandFolders,
            includeLocalDefinitionsInFileTree: true,
            reviewGitContext: .automaticOnly(),
            selectedGitDiffProvider: { _ in Self.automaticResult(nil) },
            completeGitDiffProvider: { nil }
        )
        let hiddenRediscoveryResult = await PromptContextPreAssemblyService.resolve(hiddenRediscoveryRequest)

        XCTAssertEqual(hiddenRediscoveryResult.entries.count, 1)
        XCTAssertFalse(hiddenRediscoveryResult.fileTreeContent?.contains("targetCodemapSymbol") ?? false)
        XCTAssertFalse(hiddenRediscoveryResult.fileTreeContent?.contains("<Referenced APIs>") ?? false)

        let canonicalRequest = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .none, codeMapUsage: .auto),
            selection: StoredSelection(
                selectedPaths: [selectedURL.path],
                autoCodemapPaths: [targetURL.path],
                codemapAutoEnabled: false
            ),
            store: store,
            lookupContext: lookupContext,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .expandFolders,
            includeLocalDefinitionsInFileTree: true,
            reviewGitContext: .automaticOnly(),
            selectedGitDiffProvider: { _ in Self.automaticResult(nil) },
            completeGitDiffProvider: { nil }
        )
        let canonicalResult = await PromptContextPreAssemblyService.resolve(canonicalRequest)
        let clipboard = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "",
            files: canonicalResult.entries,
            fileTreeContent: canonicalResult.fileTreeContent,
            gitDiff: canonicalResult.gitDiff,
            includeSavedPrompts: false,
            includeFiles: true,
            includeUserPrompt: false,
            filePathDisplay: .relative,
            codemapSnapshotBundle: canonicalResult.codemapSnapshotBundle,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )

        XCTAssertEqual(canonicalResult.entries.count, 2)
        XCTAssertEqual(occurrences(of: "targetCodemapSymbol", in: clipboard), 1, clipboard)
        XCTAssertEqual(occurrences(of: "selectedFullContentSentinel", in: clipboard), 1, clipboard)
        XCTAssertFalse(clipboard.contains("targetFullContentSentinel"), clipboard)
        XCTAssertFalse(clipboard.contains("<Referenced APIs>"), clipboard)
    }

    func testResolveFreezesCodemapResolutionTreeAndRenderingAcrossAwait() async throws {
        #if DEBUG
            let root = try makeTemporaryRoot(name: "PromptPreAssemblyFrozenCodemap")
            let selectedURL = root.appendingPathComponent("Selected.swift")
            let targetURL = root.appendingPathComponent("Target.swift")
            try FileSystemTestSupport.write("let selected = true\n", to: selectedURL)
            try FileSystemTestSupport.write("struct Target {}\n", to: targetURL)

            let store = WorkspaceFileContextStore()
            let rootRecord = try await store.loadRoot(path: root.path)
            let loadedFileSystemService = await store.fileSystemServiceForTesting(rootID: rootRecord.id)
            let fileSystemService = try XCTUnwrap(loadedFileSystemService)
            await store.applyObservedCodemapResults([
                WorkspaceObservedCodemapResult(
                    fullPath: targetURL.path,
                    modificationDate: Date(),
                    fileAPI: makeFileAPI(
                        path: targetURL.path,
                        symbolName: "frozenCodemapSentinel"
                    )
                )
            ])
            let gate = PreAssemblyContentReadGate()
            await fileSystemService.setContentReadChunkHandlerForTesting { _ in
                await gate.markStartedAndWaitForRelease()
            }
            defer {
                Task {
                    await fileSystemService.setContentReadChunkHandlerForTesting(nil)
                    await gate.release()
                }
            }

            let request = PromptContextPreAssemblyRequest(
                cfg: makeConfig(gitInclusion: .none, codeMapUsage: .auto),
                selection: StoredSelection(
                    selectedPaths: [selectedURL.path],
                    autoCodemapPaths: [targetURL.path],
                    codemapAutoEnabled: true
                ),
                store: store,
                lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: true,
                showCodeMapMarkers: true,
                selectedGitDiffFolderPolicy: .filesOnly,
                reviewGitContext: .automaticOnly(),
                selectedGitDiffProvider: { _ in Self.automaticResult(nil) },
                completeGitDiffProvider: { nil }
            )
            let resolveTask = Task {
                await PromptContextPreAssemblyService.resolve(request)
            }
            await gate.waitUntilStarted()
            await store.applyObservedCodemapResults([
                WorkspaceObservedCodemapResult(
                    fullPath: targetURL.path,
                    modificationDate: Date(),
                    fileAPI: nil
                )
            ])
            await gate.release()
            let result = await resolveTask.value
            await fileSystemService.setContentReadChunkHandlerForTesting(nil)

            let clipboard = await PromptPackagingService.generateClipboardContent(
                metaInstructions: [],
                userInstructions: "",
                files: result.entries,
                fileTreeContent: result.fileTreeContent,
                includeSavedPrompts: false,
                includeFiles: true,
                includeUserPrompt: false,
                filePathDisplay: .relative,
                codemapSnapshotBundle: result.codemapSnapshotBundle,
                promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
                disabledPromptSections: [],
                duplicateUserInstructionsAtTop: false
            )

            XCTAssertEqual(result.entries.filter(\.isCodemap).map(\.file.standardizedFullPath), [targetURL.standardizedFileURL.path])
            XCTAssertTrue(result.fileTreeContent?.contains("Target.swift +") == true, result.fileTreeContent ?? "")
            XCTAssertTrue(clipboard.contains("frozenCodemapSentinel"), clipboard)
            XCTAssertTrue(result.codemapSnapshotBundle.orderedSnapshots.contains {
                $0.fileAPI?.apiDescription.contains("frozenCodemapSentinel") == true
            })
            let currentBundle = await store.codemapSnapshotBundle()
            XCTAssertFalse(currentBundle.orderedSnapshots.contains {
                $0.fileAPI?.apiDescription.contains("frozenCodemapSentinel") == true
            })
        #endif
    }

    func testSelectedArtifactWinsLazilyAndMapRemainsOrdinaryContext() async throws {
        let diffText = "diff --git a/Sources/App.swift b/Sources/App.swift\n"
        let fixture = try await makeArtifactFixture(patchContent: diffText)
        let selection = StoredSelection(
            selectedPaths: [fixture.mapURL.path, fixture.patchURL.path, fixture.sourceURL.path],
            codemapAutoEnabled: false
        )
        let capture = ProviderCapture()
        let finalAuthorization = try await makeFinalAuthorization(
            fixture: fixture,
            selection: selection
        )
        let baseRequest = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .selected),
            selection: selection,
            store: fixture.store,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .expandFolders,
            reviewGitContext: fixture.reviewContext,
            sourceTabID: finalAuthorization.tabID,
            finalReviewAuthorization: finalAuthorization,
            selectedGitDiffProvider: { request in
                await capture.record(request)
                return Self.automaticResult("automatic diff must not appear")
            },
            completeGitDiffProvider: { "unexpected complete provider" }
        )
        let includeResult = try await PromptContextPreAssemblyService.resolveStrict(baseRequest)
        let providerInvocationCount = await capture.count()

        XCTAssertEqual(includeResult.gitDiff, diffText)
        XCTAssertEqual(providerInvocationCount, 0)
        XCTAssertEqual(includeResult.entries.count(where: { $0.file.name == "MAP.txt" }), 1)
        XCTAssertEqual(includeResult.entries.count(where: { $0.file.name == "all.patch" }), 1)
        let (_, codeEntries) = PromptPackagingService.partitionPromptEntriesForGitDiff(includeResult.entries)
        XCTAssertTrue(codeEntries.contains { $0.file.name == "MAP.txt" })
        XCTAssertFalse(codeEntries.contains { $0.file.name == "all.patch" })

        let clipboard = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "",
            files: includeResult.entries,
            fileTreeContent: includeResult.fileTreeContent,
            gitDiff: includeResult.gitDiff,
            includeSavedPrompts: false,
            includeFiles: true,
            includeUserPrompt: false,
            filePathDisplay: .relative,
            codemapSnapshotBundle: includeResult.codemapSnapshotBundle,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )
        XCTAssertEqual(occurrences(of: "ordinary map context", in: clipboard), 1, clipboard)
        XCTAssertEqual(occurrences(of: diffText, in: clipboard), 1, clipboard)
    }

    func testDelegatedArtifactRequiresExactFrozenConsumerAtPreassemblyBoundary() async throws {
        let diffText = "diff --git a/Sources/App.swift b/Sources/App.swift\n+delegated launch patch\n"
        let fixture = try await makeArtifactFixture(patchContent: diffText)
        let capability = try XCTUnwrap(fixture.reviewContext.artifactCapability)
        let targetWorkspaceID = capability.workspaceID
        let targetTabID = UUID()
        let targetSessionID = UUID()
        let targetRunID = UUID()
        let delegation = SelectedGitArtifactDelegation(
            delegationID: UUID(),
            sourceWorkspaceID: capability.workspaceID,
            sourceTabID: capability.creatorTabID,
            sourceAgentSessionID: capability.sessionID,
            sourceAgentRunID: UUID(),
            targetWorkspaceID: targetWorkspaceID,
            targetTabID: targetTabID,
            targetAgentSessionID: targetSessionID,
            targetAgentRunID: targetRunID,
            exactSelectedArtifactPaths: [fixture.patchURL.path],
            targetBoundCheckouts: capability.boundCheckouts
        )
        let consumer = SelectedGitArtifactDelegationConsumer(
            workspaceID: targetWorkspaceID,
            tabID: targetTabID,
            agentSessionID: targetSessionID,
            agentRunID: targetRunID,
            boundCheckouts: capability.boundCheckouts
        )
        let delegatedReviewContext = FrozenPromptGitReviewContext(
            artifactCapability: capability.delegated(delegation),
            artifactDelegationConsumer: consumer,
            compareIntent: fixture.reviewContext.compareIntent,
            displayContext: fixture.reviewContext.displayContext
        )
        let selection = StoredSelection(
            selectedPaths: [fixture.patchURL.path, fixture.sourceURL.path],
            codemapAutoEnabled: false
        )
        let capture = ProviderCapture()

        func request(_ reviewContext: FrozenPromptGitReviewContext) -> PromptContextPreAssemblyRequest {
            PromptContextPreAssemblyRequest(
                cfg: makeConfig(gitInclusion: .selected),
                selection: selection,
                store: fixture.store,
                lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: true,
                showCodeMapMarkers: true,
                selectedGitDiffFolderPolicy: .filesOnly,
                reviewGitContext: reviewContext,
                selectedGitDiffProvider: { automaticRequest in
                    await capture.record(automaticRequest)
                    return Self.automaticResult("automatic fallback")
                },
                completeGitDiffProvider: { nil }
            )
        }

        let authorized = await PromptContextPreAssemblyService.resolve(
            request(delegatedReviewContext)
        )
        XCTAssertEqual(authorized.gitDiff, diffText)
        let authorizedProviderCount = await capture.count()
        XCTAssertEqual(authorizedProviderCount, 0)

        let missingConsumer = FrozenPromptGitReviewContext(
            artifactCapability: capability.delegated(delegation),
            compareIntent: fixture.reviewContext.compareIntent,
            displayContext: fixture.reviewContext.displayContext
        )
        let rejected = await PromptContextPreAssemblyService.resolve(request(missingConsumer))
        XCTAssertEqual(rejected.gitDiff, "automatic fallback")
        let rejectedProviderCount = await capture.count()
        XCTAssertEqual(rejectedProviderCount, 1)
        XCTAssertEqual(
            rejected.selectedGitArtifactDispositions,
            [.rejected(path: fixture.patchURL.path, reason: .delegationConsumerMismatch)]
        )
    }

    func testSelectedArtifactPolicyCanRespectGitInclusionNone() async throws {
        let diffText = "diff --git a/Sources/App.swift b/Sources/App.swift\n"
        let fixture = try await makeArtifactFixture(patchContent: diffText)
        let selection = StoredSelection(
            selectedPaths: [fixture.mapURL.path, fixture.patchURL.path],
            codemapAutoEnabled: false
        )

        let respectRequest = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .none),
            selection: selection,
            store: fixture.store,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .expandFolders,
            selectedGitDiffArtifactPolicy: .respectGitInclusion,
            reviewGitContext: fixture.reviewContext,
            selectedGitDiffProvider: { _ in Self.automaticResult("unexpected selected provider") },
            completeGitDiffProvider: { "unexpected complete provider" }
        )
        let respectResult = await PromptContextPreAssemblyService.resolve(respectRequest)

        let respectClipboard = await PromptPackagingService.generateClipboardContent(
            metaInstructions: [],
            userInstructions: "",
            files: respectResult.entries,
            fileTreeContent: respectResult.fileTreeContent,
            gitDiff: respectResult.gitDiff,
            includeSavedPrompts: false,
            includeFiles: true,
            includeUserPrompt: false,
            filePathDisplay: .relative,
            codemapSnapshotBundle: respectResult.codemapSnapshotBundle,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            duplicateUserInstructionsAtTop: false
        )

        XCTAssertNil(respectResult.gitDiff)
        XCTAssertEqual(respectResult.entries.map(\.file.name), ["MAP.txt"])
        XCTAssertTrue(respectClipboard.contains("ordinary map context"), respectClipboard)
        XCTAssertFalse(respectClipboard.contains("<git_diff>"), respectClipboard)
        XCTAssertFalse(respectClipboard.contains(diffText), respectClipboard)
    }

    func testEmptyAuthorizedPatchFallsBackExactlyOnce() async throws {
        let fixture = try await makeArtifactFixture(patchContent: " \n")
        let capture = ProviderCapture()
        let selection = StoredSelection(
            selectedPaths: [fixture.patchURL.path, fixture.sourceURL.path],
            codemapAutoEnabled: false
        )
        let finalAuthorization = try await makeFinalAuthorization(
            fixture: fixture,
            selection: selection
        )
        let request = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .selected),
            selection: selection,
            store: fixture.store,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .filesOnly,
            reviewGitContext: fixture.reviewContext,
            sourceTabID: finalAuthorization.tabID,
            finalReviewAuthorization: finalAuthorization,
            selectedGitDiffProvider: { automaticRequest in
                await capture.record(automaticRequest)
                return Self.automaticResult("automatic fallback")
            },
            completeGitDiffProvider: { nil }
        )

        let result = try await PromptContextPreAssemblyService.resolveStrict(request)
        let providerInvocationCount = await capture.count()

        XCTAssertEqual(result.gitDiff, "automatic fallback")
        XCTAssertEqual(providerInvocationCount, 1)
        guard case .automatic = result.gitDiffResolution else {
            return XCTFail("Expected structured automatic resolution")
        }
        guard case .finalized = await capture.lastRequest()?.source else {
            return XCTFail("Expected the empty authorized patch to use finalized checkout authority")
        }
    }

    func testSliceOnlyAndAutoCodemapOnlyAuthorizedPatchSelectionsRemainArtifacts() async throws {
        let diffText = "diff --git a/Sources/App.swift b/Sources/App.swift\n"
        let fixture = try await makeArtifactFixture(patchContent: diffText)
        let noncanonicalPatchPath = fixture.patchURL.deletingLastPathComponent().path
            + "/../diff/all.patch"
        XCTAssertEqual(
            SelectedGitArtifactSelectionClassifier.artifactCandidatePaths(
                from: StoredSelection(
                    selectedPaths: [noncanonicalPatchPath],
                    codemapAutoEnabled: false
                ),
                capability: fixture.reviewContext.artifactCapability
            ),
            [fixture.patchURL.path]
        )
        let selections = [
            StoredSelection(
                slices: [fixture.patchURL.path: [LineRange(start: 1, end: 1)]],
                codemapAutoEnabled: false
            ),
            StoredSelection(
                autoCodemapPaths: [fixture.patchURL.path],
                codemapAutoEnabled: true
            )
        ]

        for selection in selections {
            let capture = ProviderCapture()
            let finalAuthorization = try await makeFinalAuthorization(
                fixture: fixture,
                selection: selection
            )
            let request = PromptContextPreAssemblyRequest(
                cfg: makeConfig(gitInclusion: .selected),
                selection: selection,
                store: fixture.store,
                lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: true,
                showCodeMapMarkers: true,
                selectedGitDiffFolderPolicy: .filesOnly,
                reviewGitContext: fixture.reviewContext,
                sourceTabID: finalAuthorization.tabID,
                finalReviewAuthorization: finalAuthorization,
                selectedGitDiffProvider: { automaticRequest in
                    await capture.record(automaticRequest)
                    return Self.automaticResult("automatic diff must not appear")
                },
                completeGitDiffProvider: { nil }
            )

            let result = try await PromptContextPreAssemblyService.resolveStrict(request)
            let providerInvocationCount = await capture.count()

            XCTAssertEqual(result.gitDiff, diffText)
            XCTAssertEqual(providerInvocationCount, 0)
            XCTAssertEqual(result.entries.map(\.role), [.authorizedGitDiffArtifact])
            XCTAssertEqual(result.entries.first?.lineRanges, nil)
        }
    }

    func testStrictReviewRejectsChangedArtifactProvenanceBeforeAutomaticFallback() async throws {
        let fixture = try await makeArtifactFixture(patchContent: "diff --git a/A b/A\n")
        let selection = StoredSelection(
            selectedPaths: [fixture.patchURL.path, fixture.sourceURL.path],
            codemapAutoEnabled: false
        )
        let authorized = try await makeFinalAuthorization(fixture: fixture, selection: selection)
        let originalArtifact = try XCTUnwrap(authorized.selectedArtifactAuthorizations.first)
        let changedArtifact = ContextBuilderFinalSelectedArtifactAuthorization(
            absolutePath: originalArtifact.absolutePath,
            kind: originalArtifact.kind,
            readability: originalArtifact.readability,
            provenance: SelectedGitArtifactCheckoutProvenance(
                checkoutRootPath: originalArtifact.provenance.checkoutRootPath,
                repoKey: originalArtifact.provenance.repoKey,
                repositoryID: originalArtifact.provenance.repositoryID,
                worktreeID: "changed-worktree",
                kind: originalArtifact.provenance.kind
            )
        )
        let changedAuthorization = ContextBuilderFinalReviewAuthorization(
            electionOrigin: authorized.electionOrigin,
            workspaceID: authorized.workspaceID,
            tabID: authorized.tabID,
            committedSelectionRevision: authorized.committedSelectionRevision,
            committedSelection: authorized.committedSelection,
            lookupContext: authorized.lookupContext,
            reviewGitContext: authorized.reviewGitContext,
            target: authorized.target,
            checkoutAuthorizations: authorized.checkoutAuthorizations,
            selectedArtifactAuthorizations: [changedArtifact]
        )
        let capture = ProviderCapture()
        let request = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .selected),
            selection: selection,
            store: fixture.store,
            lookupContext: changedAuthorization.lookupContext,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .filesOnly,
            reviewGitContext: fixture.reviewContext,
            sourceTabID: changedAuthorization.tabID,
            finalReviewAuthorization: changedAuthorization,
            selectedGitDiffProvider: { automaticRequest in
                await capture.record(automaticRequest)
                return Self.automaticResult("forbidden fallback")
            },
            completeGitDiffProvider: { nil }
        )

        do {
            _ = try await PromptContextPreAssemblyService.resolveStrict(request)
            XCTFail("Expected changed artifact provenance to fail closed")
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            guard case .unauthorizedSelectedArtifact = reason else {
                return XCTFail("Unexpected rejection: \(reason)")
            }
        }
        let providerCount = await capture.count()
        XCTAssertEqual(providerCount, 0)
    }

    func testStrictReviewRejectedArtifactNeverInvokesAutomaticFallback() async throws {
        let fixture = try await makeArtifactFixture(patchContent: "diff --git a/A b/A\n")
        let selection = StoredSelection(
            selectedPaths: [fixture.patchURL.path, fixture.sourceURL.path],
            codemapAutoEnabled: false
        )
        let authorization = try await makeFinalAuthorization(
            fixture: fixture,
            selection: selection
        )
        try FileManager.default.removeItem(at: fixture.patchURL)
        let capture = ProviderCapture()
        let request = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .selected),
            selection: selection,
            store: fixture.store,
            lookupContext: authorization.lookupContext,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .filesOnly,
            reviewGitContext: fixture.reviewContext,
            sourceTabID: authorization.tabID,
            finalReviewAuthorization: authorization,
            selectedGitDiffProvider: { automaticRequest in
                await capture.record(automaticRequest)
                return Self.automaticResult("forbidden fallback")
            },
            completeGitDiffProvider: { nil }
        )

        do {
            _ = try await PromptContextPreAssemblyService.resolveStrict(request)
            XCTFail("Expected the removed artifact to fail closed")
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            guard case .unauthorizedSelectedArtifact = reason else {
                return XCTFail("Unexpected rejection: \(reason)")
            }
        }
        let providerCount = await capture.count()
        XCTAssertEqual(providerCount, 0)
    }

    func testStrictReviewRejectsMismatchedFrozenGitContextBeforeFallback() async throws {
        let fixture = try await makeArtifactFixture(patchContent: "diff --git a/A b/A\n")
        let selection = StoredSelection(
            selectedPaths: [fixture.patchURL.path, fixture.sourceURL.path],
            codemapAutoEnabled: false
        )
        let authorization = try await makeFinalAuthorization(
            fixture: fixture,
            selection: selection
        )
        let mismatchedContext = FrozenPromptGitReviewContext(
            artifactCapability: fixture.reviewContext.artifactCapability,
            artifactDelegationConsumer: fixture.reviewContext.artifactDelegationConsumer,
            compareIntent: .uncommittedMergeBase(symbolicBase: "unexpected/base"),
            displayContext: fixture.reviewContext.displayContext
        )
        let capture = ProviderCapture()
        let request = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .selected),
            selection: selection,
            store: fixture.store,
            lookupContext: authorization.lookupContext,
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .filesOnly,
            reviewGitContext: mismatchedContext,
            sourceTabID: authorization.tabID,
            finalReviewAuthorization: authorization,
            selectedGitDiffProvider: { automaticRequest in
                await capture.record(automaticRequest)
                return Self.automaticResult("forbidden fallback")
            },
            completeGitDiffProvider: { nil }
        )

        do {
            _ = try await PromptContextPreAssemblyService.resolveStrict(request)
            XCTFail("Expected mismatched frozen Git context to fail closed")
        } catch let reason as ContextBuilderReviewTargetUnavailableReason {
            XCTAssertEqual(reason, .workspaceOrTabMismatch)
        }
        let providerCount = await capture.count()
        XCTAssertEqual(providerCount, 0)
    }

    func testGitDataSelectionWithoutCapabilityFailsClosedWithoutArtifactClassification() async throws {
        let fixture = try await makeArtifactFixture(patchContent: "secret patch")
        let request = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .none),
            selection: StoredSelection(selectedPaths: [fixture.patchURL.path], codemapAutoEnabled: false),
            store: fixture.store,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .filesOnly,
            reviewGitContext: .automaticOnly(),
            selectedGitDiffProvider: { _ in Self.automaticResult(nil) },
            completeGitDiffProvider: { nil }
        )

        let result = await PromptContextPreAssemblyService.resolve(request)

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNil(result.gitDiff)
        XCTAssertTrue(result.selectedGitArtifactDispositions.isEmpty)
    }

    func testOrdinaryWorkspaceFolderNamedGitDataRemainsSourceContext() async throws {
        let root = try makeTemporaryRoot(name: "PromptPreAssemblyOrdinaryGitData")
        let sourceURL = root.appendingPathComponent("_git_data/diff/fake.patch")
        try FileSystemTestSupport.write("ordinary patch-shaped source\n", to: sourceURL)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path, kind: .primaryWorkspace)
        let request = PromptContextPreAssemblyRequest(
            cfg: makeConfig(gitInclusion: .selected),
            selection: StoredSelection(selectedPaths: [sourceURL.path], codemapAutoEnabled: false),
            store: store,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            filePathDisplay: .relative,
            onlyIncludeRootsWithSelectedFiles: true,
            showCodeMapMarkers: true,
            selectedGitDiffFolderPolicy: .filesOnly,
            reviewGitContext: .automaticOnly(),
            selectedGitDiffProvider: { _ in Self.automaticResult("automatic fallback") },
            completeGitDiffProvider: { nil }
        )

        let result = await PromptContextPreAssemblyService.resolve(request)

        XCTAssertEqual(result.entries.map(\.file.standardizedFullPath), [sourceURL.path])
        XCTAssertEqual(result.entries.map(\.role), [.ordinary])
        XCTAssertTrue(result.entries.first?.loadedContent?.contains("ordinary patch-shaped source") == true)
        XCTAssertTrue(result.selectedGitArtifactDispositions.isEmpty)
        XCTAssertEqual(result.gitDiff, "automatic fallback")
        let (diffEntries, codeEntries) = PromptPackagingService.partitionPromptEntriesForGitDiff(result.entries)
        XCTAssertTrue(diffEntries.isEmpty)
        XCTAssertEqual(codeEntries.map(\.file.standardizedFullPath), [sourceURL.path])
    }

    private func makeArtifactFixture(patchContent: String) async throws -> ArtifactFixture {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: "PromptPreAssemblyArtifacts")
        let repoRoot = try repositoryFixture.makeRepository(
            named: "repo",
            files: ["Sources/App.swift": "let selectedSource = true\n"]
        )
        let sourceURL = repoRoot.appendingPathComponent("Sources/App.swift")
        let workspace = try makeTemporaryRoot(name: "PromptPreAssemblyArtifactWorkspace")
        let snapshotID = "2026-06-19/1851"
        let repoKey = "repo-storage"
        let snapshotRoot = workspace
            .appendingPathComponent("_git_data/repos/\(repoKey)/\(snapshotID)", isDirectory: true)
        let mapURL = snapshotRoot.appendingPathComponent("MAP.txt")
        let patchURL = snapshotRoot.appendingPathComponent("diff/all.patch")
        let manifestURL = snapshotRoot.appendingPathComponent("manifest.json")
        try FileSystemTestSupport.write("ordinary map context", to: mapURL)
        try FileSystemTestSupport.write(patchContent, to: patchURL)

        let workspaceID = UUID()
        let creatorTabID = UUID()
        let manifest = GitDiffSnapshotManifest(
            snapshotID: snapshotID,
            generatedAt: Date(timeIntervalSince1970: 1),
            mode: .standard,
            compare: "HEAD",
            compareInput: nil,
            scope: .selected,
            requestedPaths: ["Sources/App.swift"],
            fingerprint: GitDiffFingerprint(
                headSHA: "abc",
                baseRef: "HEAD",
                statusHash: "status",
                generatedAt: Date(timeIntervalSince1970: 1)
            ),
            contextLines: 3,
            detectRenames: false,
            summary: GitDiffSnapshotManifest.Summary(files: 1, insertions: 1, deletions: 0),
            files: [],
            repoKey: repoKey,
            repoRoot: repoRoot.path,
            isWorktree: false,
            worktreeName: nil,
            worktreeRoot: nil,
            mainWorktreeRoot: nil,
            commonGitDir: nil,
            tabID: creatorTabID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileSystemTestSupport.write(
            XCTUnwrap(try String(data: encoder.encode(manifest), encoding: .utf8)),
            to: manifestURL
        )

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: repoRoot.path)
        _ = try await store.loadRoot(
            path: workspace.appendingPathComponent("_git_data").path,
            kind: .workspaceGitData
        )
        let reviewContext = await FrozenPromptGitReviewContext.make(
            workspaceID: workspaceID,
            workspaceDirectoryPath: workspace.path,
            workspaceRootPaths: [repoRoot.path],
            tabID: creatorTabID,
            sessionID: nil,
            bindings: [],
            base: "HEAD",
            store: store
        )
        return ArtifactFixture(
            repositoryFixture: repositoryFixture,
            repoRoot: repoRoot,
            workspace: workspace,
            mapURL: mapURL,
            patchURL: patchURL,
            sourceURL: sourceURL,
            store: store,
            reviewContext: reviewContext
        )
    }

    private func makeFinalAuthorization(
        fixture: ArtifactFixture,
        selection: StoredSelection
    ) async throws -> ContextBuilderFinalReviewAuthorization {
        let capability = try XCTUnwrap(fixture.reviewContext.artifactCapability)
        let lookupContext = WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil)
        let input = ContextBuilderReviewTargetInput(
            workspaceID: capability.workspaceID,
            tabID: capability.creatorTabID,
            selectionRevision: 1,
            selection: selection,
            lookupContext: lookupContext,
            reviewGitContext: fixture.reviewContext
        )
        let resolver = ContextBuilderReviewTargetResolver()
        let initial = try await resolver.resolve(input: input, store: fixture.store)
        return try await resolver.finalizeSelection(
            input: input,
            initialResolution: initial,
            store: fixture.store
        )
    }

    private func makeBoundFixture() async throws -> (
        logicalRoot: URL,
        worktreeRoot: URL,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) {
        let logicalRoot = try makeTemporaryRoot(name: "PromptPreAssemblyLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "PromptPreAssemblyWorktree")
        try FileSystemTestSupport.write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))
        try FileSystemTestSupport.write("let origin = \"keep-base\"\n", to: logicalRoot.appendingPathComponent("Sources/Keep.swift"))
        try FileSystemTestSupport.write("let origin = \"worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/App.swift"))
        try FileSystemTestSupport.write("let origin = \"keep-worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/Keep.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let sessionID = UUID()
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)
        let materializedProjection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(sessionID: sessionID, bindings: [binding])
        let projection = try XCTUnwrap(materializedProjection)
        let lookupContext = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        return (logicalRoot, worktreeRoot, store, lookupContext)
    }

    private func makeConfig(
        gitInclusion: GitInclusion,
        codeMapUsage: CodeMapUsage = .none
    ) -> PromptContextResolved {
        PromptContextResolved(
            includeFiles: true,
            includeUserPrompt: true,
            includeMetaPrompts: false,
            includeFileTree: true,
            fileTreeMode: .auto,
            codeMapUsage: codeMapUsage,
            gitInclusion: gitInclusion,
            storedPromptIds: []
        )
    }

    private func makeFileAPI(
        path: String,
        symbolName: String,
        className: String? = nil,
        referencedTypes: [String] = []
    ) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: className.map { [ClassInfo(name: $0, methods: [], properties: [])] } ?? [],
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: referencedTypes
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func automaticResult(_ text: String?) -> AutomaticReviewGitDiffResult {
        AutomaticReviewGitDiffResult(
            text: text,
            completeness: .complete,
            outcomes: [],
            pathIssues: []
        )
    }

    private func makeBinding(logicalRoot: URL, worktreeRoot: URL) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "bind_test",
            repositoryID: "repo_test",
            repoKey: "repo",
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: "worktree_test",
            worktreeRootPath: worktreeRoot.path,
            worktreeName: worktreeRoot.lastPathComponent,
            branch: "feature/test",
            head: "abcdef",
            visualLabel: "test",
            visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123),
            source: "test"
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try temporaryRoots.makeRoot(suiteName: name)
    }
}

#if DEBUG
    private actor PreAssemblyContentReadGate {
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
