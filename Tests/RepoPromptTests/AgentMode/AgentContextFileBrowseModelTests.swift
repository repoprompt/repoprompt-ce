@testable import RepoPromptApp
import XCTest

final class AgentContextFileBrowseModelTests: XCTestCase {
    @MainActor
    func testBeginAndEndConstructAndResetSessionState() async throws {
        let harness = try await makeHarness(files: ["One.swift"])

        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )

        XCTAssertEqual(harness.model.phase, .ready)
        XCTAssertEqual(harness.model.capturedIdentity, harness.target.identity)
        XCTAssertEqual(harness.model.roots.map(\.id), [harness.root.id])
        XCTAssertEqual(harness.model.focusTarget, .search)
        XCTAssertEqual(harness.model.addMode, .full)
        XCTAssertEqual(harness.model.rootScope, .allRoots)

        harness.model.setQuery("One")
        harness.model.setAddMode(.codemapOnly)
        harness.model.end()

        XCTAssertEqual(harness.model.phase, .inactive)
        XCTAssertTrue(harness.model.rows.isEmpty)
        XCTAssertTrue(harness.model.query.isEmpty)
        XCTAssertNil(harness.model.focusTarget)
        XCTAssertEqual(harness.model.addMode, .full)
    }

    @MainActor
    func testCanceledDeferredBeginDoesNotReactivateEndedSession() async throws {
        let harness = try await makeHarness(files: ["One.swift"])
        let deferredEntry = Task { @MainActor in
            await harness.model.begin(
                target: harness.target,
                lookupContext: .visibleWorkspace,
                exportRows: [],
                codeMapsGloballyDisabled: false
            )
        }

        harness.model.end()
        deferredEntry.cancel()
        await deferredEntry.value

        XCTAssertEqual(harness.model.phase, .inactive)
        XCTAssertNil(harness.model.capturedIdentity)
    }

    @MainActor
    func testSelectionProjectionUsesSliceFullManualPrecedenceAndExactAutoMapPredicate() async throws {
        let harness = try await makeHarness(files: ["Full.swift", "Slice.swift", "Manual.swift", "Auto.swift"])
        let paths = harness.paths
        let selection = try StoredSelection(
            selectedPaths: [XCTUnwrap(paths["Full.swift"]), XCTUnwrap(paths["Slice.swift"])],
            manualCodemapPaths: [XCTUnwrap(paths["Full.swift"]), XCTUnwrap(paths["Manual.swift"])],
            slices: [XCTUnwrap(paths["Slice.swift"]): [LineRange(start: 2, end: 4)]],
            codemapAutoEnabled: true
        )
        harness.recorder.selection = selection
        let target = AgentContextSelectionMutationTarget(identity: harness.target.identity, expectedSelection: selection)
        let rows = try [
            makeCodemapRow(fileID: UUID(), rootID: harness.root.id, path: XCTUnwrap(paths["Manual.swift"])),
            makeCodemapRow(fileID: UUID(), rootID: harness.root.id, path: XCTUnwrap(paths["Auto.swift"]))
        ]

        await harness.model.begin(
            target: target,
            lookupContext: .visibleWorkspace,
            exportRows: rows,
            codeMapsGloballyDisabled: false
        )
        let files = try await loadRootFiles(harness)

        XCTAssertTrue(files.values.allSatisfy {
            StoredSelectionPathNormalization.standardizedPath($0.standardizedFullPath) == $0.standardizedFullPath
        })
        XCTAssertEqual(try harness.model.heldMode(for: XCTUnwrap(files["Full.swift"])), .full)
        XCTAssertEqual(try harness.model.heldMode(for: XCTUnwrap(files["Slice.swift"])), .slice)
        XCTAssertEqual(try harness.model.heldMode(for: XCTUnwrap(files["Manual.swift"])), .codemap)
        XCTAssertFalse(try harness.model.isAutomaticallyMapped(XCTUnwrap(files["Manual.swift"])))
        XCTAssertTrue(try harness.model.isAutomaticallyMapped(XCTUnwrap(files["Auto.swift"])))
    }

    @MainActor
    func testVisibleContainerLazilyResolvesDescendantsAndComputesCodemapMembership() async throws {
        let harness = try await makeHarness(files: ["Selected.swift", "Unsupported.txt", "Available.swift"])
        let selectedPath = try XCTUnwrap(harness.paths["Selected.swift"])
        let selection = StoredSelection(selectedPaths: [selectedPath])
        harness.recorder.selection = selection
        let target = AgentContextSelectionMutationTarget(identity: harness.target.identity, expectedSelection: selection)
        await harness.model.begin(
            target: target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let rootNode = AgentContextFileBrowseNodeID.root(harness.root.id)

        XCTAssertNil(harness.model.membership(for: rootNode))
        harness.model.toggleExpansion(rootNode)
        await eventually { harness.model.membership(for: rootNode) != nil }
        XCTAssertEqual(harness.model.membership(for: rootNode), .mixed)

        harness.model.setAddMode(.codemapOnly)
        XCTAssertEqual(harness.model.membership(for: rootNode), .mixed)
        XCTAssertTrue(harness.model.toggleContainer(rootNode))
        await eventually { harness.recorder.calls.count == 1 }
        XCTAssertEqual(Set(harness.recorder.calls[0].paths), try [
            XCTUnwrap(harness.paths["Available.swift"])
        ])
        XCTAssertEqual(harness.recorder.calls[0].targetState, .codemapOnly)
    }

    @MainActor
    func testCollapsedContainerIsDisabledUntilKnownAndPreservesFullySelectedTruth() async throws {
        let harness = try await makeHarness(files: ["One.swift", "Two.swift"])
        let selectedPaths = try [
            XCTUnwrap(harness.paths["One.swift"]),
            XCTUnwrap(harness.paths["Two.swift"])
        ]
        let selection = StoredSelection(selectedPaths: selectedPaths)
        harness.recorder.selection = selection
        let target = AgentContextSelectionMutationTarget(
            identity: harness.target.identity,
            expectedSelection: selection
        )
        await harness.model.begin(
            target: target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let rootNode = AgentContextFileBrowseNodeID.root(harness.root.id)

        XCTAssertNil(harness.model.containerStatus(for: rootNode))
        XCTAssertFalse(harness.model.toggleContainer(rootNode))
        harness.model.toggleExpansion(rootNode)
        await eventually { harness.model.membership(for: rootNode) == .all }
        harness.model.toggleExpansion(rootNode)

        XCTAssertEqual(harness.model.membership(for: rootNode), .all)
        XCTAssertEqual(harness.model.containerStatus(for: rootNode)?.membership, .all)
        XCTAssertTrue(harness.model.toggleContainer(rootNode))
        await eventually { harness.recorder.calls.count == 1 }
        XCTAssertEqual(harness.recorder.calls[0].targetState, .unselected)
    }

    @MainActor
    func testImmediateMutationsRemainCanonicalAndExecuteInClickOrder() async throws {
        let harness = try await makeHarness(files: ["One.swift", "Two.swift"])
        harness.recorder.suspendMutations = true
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let files = try await loadRootFiles(harness)
        let one = try XCTUnwrap(files["One.swift"])
        let two = try XCTUnwrap(files["Two.swift"])

        XCTAssertTrue(harness.model.toggleFile(one))
        XCTAssertTrue(harness.model.toggleFile(two))
        XCTAssertNil(harness.model.heldMode(for: one))
        XCTAssertNil(harness.model.heldMode(for: two))
        XCTAssertEqual(harness.model.inFlightPaths.count, 2)

        await eventually { harness.recorder.pendingMutationCount == 1 }
        harness.recorder.resumeNextMutation()
        await eventually { harness.recorder.pendingMutationCount == 1 && harness.recorder.calls.count == 2 }
        harness.recorder.resumeNextMutation()
        await eventually { harness.model.inFlightPaths.isEmpty }

        XCTAssertEqual(harness.recorder.calls.map(\.paths.first), try [
            XCTUnwrap(harness.paths["One.swift"]),
            XCTUnwrap(harness.paths["Two.swift"])
        ])
        XCTAssertEqual(Set(harness.recorder.calls.map(\.identity)), [harness.target.identity])
        XCTAssertTrue(harness.recorder.calls.allSatisfy { $0.lookupContext == .visibleWorkspace })
        XCTAssertEqual(harness.model.heldMode(for: one), .full)
        XCTAssertEqual(harness.model.heldMode(for: two), .full)
    }

    @MainActor
    func testQueryScopeGenerationFencingAndFocusOrder() async throws {
        let harness = try await makeHarness(files: ["Alpha.swift", "Beta.swift"])
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let hierarchyFiles = try await loadRootFiles(harness)
        let staleAlpha = try XCTUnwrap(hierarchyFiles["Alpha.swift"])
        harness.model.setQuery("Alpha")
        XCTAssertTrue(harness.model.rows.isEmpty)
        XCTAssertFalse(harness.model.toggleFile(staleAlpha))
        await eventually {
            harness.model.searchGroups.flatMap(\.rootMatches).contains { $0.file.name == "Alpha.swift" }
        }
        let staleSearchAlpha = try XCTUnwrap(harness.model.searchGroups.flatMap(\.rootMatches).first?.file)
        harness.model.setRootScope(.root(harness.root.id))
        XCTAssertTrue(harness.model.rows.isEmpty)
        XCTAssertFalse(harness.model.toggleFile(staleSearchAlpha))
        harness.model.setQuery("Beta")
        await eventually {
            harness.model.searchGroups.flatMap(\.rootMatches).contains { $0.file.name == "Beta.swift" }
        }

        let visibleNames = harness.model.rows.compactMap { row -> String? in
            guard case let .file(file, _) = row else { return nil }
            return file.name
        }
        XCTAssertEqual(visibleNames, ["Beta.swift"])
        XCTAssertEqual(harness.model.rootScope, .root(harness.root.id))

        harness.model.focusNextRow()
        XCTAssertEqual(harness.model.focusTarget, harness.model.visibleInteractiveRowOrder.first.map {
            .row($0)
        })
        harness.model.focusNextRow()
        XCTAssertEqual(harness.model.focusTarget, harness.model.visibleInteractiveRowOrder.last.map {
            .row($0)
        })
        harness.model.focusPreviousRow()
        XCTAssertEqual(harness.model.focusTarget, harness.model.visibleInteractiveRowOrder.first.map {
            .row($0)
        })
    }

    @MainActor
    func testCollapsedRootDefersTreeAndMetadataUntilExpansionAndVisibleFileDemand() async throws {
        let harness = try await makeHarness(files: ["Tokens.swift"])
        await harness.store.resetAppliedIndexRecordLookupDiagnosticsForTesting()
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let rootNode = AgentContextFileBrowseNodeID.root(harness.root.id)
        harness.model.rowBecameVisible(rootNode)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let collapsedDiagnostics = await harness.store.appliedIndexRecordLookupDiagnosticsForTesting()
        let collapsedReadCount = await harness.metadataReads.count
        XCTAssertNil(harness.model.membership(for: rootNode))
        XCTAssertEqual(collapsedDiagnostics.rootSnapshots, 0)
        XCTAssertEqual(collapsedReadCount, 0)

        harness.model.toggleExpansion(rootNode)
        await eventually {
            harness.model.rows.contains { row in
                if case .file = row { return true }
                return false
            }
        }
        let fileNode = try XCTUnwrap(harness.model.rows.compactMap(\.interactiveNodeID).first {
            if case .file = $0 { return true }
            return false
        })
        let expandedReadCountBeforeVisibility = await harness.metadataReads.count
        XCTAssertEqual(expandedReadCountBeforeVisibility, 0)
        harness.model.rowBecameVisible(fileNode)
        await eventually {
            if case .known = harness.model.tokenEstimate(for: rootNode) { return true }
            return false
        }
        guard case let .known(rootTokens) = harness.model.tokenEstimate(for: rootNode) else {
            return XCTFail("Expected known root estimate")
        }
        XCTAssertGreaterThan(rootTokens, 0)
        let visibleFileReadCount = await harness.metadataReads.count
        XCTAssertEqual(visibleFileReadCount, 1)
    }

    @MainActor
    func testContainerTotalWaitsUntilEveryDescendantHasVisibleRowEstimate() async throws {
        let harness = try await makeHarness(files: ["Top.swift", "Folder/Nested.swift"])
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let rootNode = AgentContextFileBrowseNodeID.root(harness.root.id)
        harness.model.toggleExpansion(rootNode)
        await eventually { harness.model.membership(for: rootNode) != nil }
        let topNode = try XCTUnwrap(harness.model.rows.compactMap(\.interactiveNodeID).first {
            if case .file = $0 { return true }
            return false
        })
        guard case let .file(topFileID) = topNode else { return XCTFail("Expected top file row") }
        harness.model.rowBecameVisible(topNode)
        await eventually {
            if case .known = harness.model.tokenEstimate(for: topNode) { return true }
            return false
        }
        XCTAssertEqual(harness.model.tokenEstimate(for: rootNode), .notRequested)

        let folderNode = try XCTUnwrap(harness.model.rows.compactMap(\.interactiveNodeID).first {
            if case .folder = $0 { return true }
            return false
        })
        harness.model.toggleExpansion(folderNode)
        await eventually {
            harness.model.rows.contains { row in
                if case let .file(file, _) = row { return file.name == "Nested.swift" }
                return false
            }
        }
        let nestedNode = try XCTUnwrap(harness.model.rows.compactMap(\.interactiveNodeID).first {
            guard case let .file(fileID) = $0 else { return false }
            return fileID != topFileID
        })
        harness.model.rowBecameVisible(nestedNode)
        await eventually {
            if case .known = harness.model.tokenEstimate(for: rootNode) { return true }
            return false
        }
        let readCount = await harness.metadataReads.count
        XCTAssertEqual(readCount, 2)
    }

    @MainActor
    func testCatalogGenerationChangeFailsClosedUntilBrowseReentry() async throws {
        let harness = try await makeHarness(files: ["Old.swift"])
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )

        _ = try await harness.store.createFile(
            rootID: harness.root.id,
            relativePath: "New.swift",
            content: "new"
        )
        harness.model.setQuery("New")
        await eventually { harness.model.phase == .unavailable(.catalogChanged) }

        XCTAssertTrue(harness.model.searchGroups.isEmpty)
        XCTAssertTrue(harness.recorder.calls.isEmpty)
    }

    @MainActor
    func testGlobalCodemapDisablementForcesFullAndPreservesMapRemoval() async throws {
        let harness = try await makeHarness(files: ["Mapped.swift", "Unsupported.txt"])
        let mappedPath = try XCTUnwrap(harness.paths["Mapped.swift"])
        let selection = StoredSelection(manualCodemapPaths: [mappedPath], codemapAutoEnabled: false)
        harness.recorder.selection = selection
        let target = AgentContextSelectionMutationTarget(identity: harness.target.identity, expectedSelection: selection)
        await harness.model.begin(
            target: target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let files = try await loadRootFiles(harness)
        let unsupported = try XCTUnwrap(files["Unsupported.txt"])
        harness.model.setAddMode(.codemapOnly)
        XCTAssertEqual(
            harness.model.fileStatus(for: unsupported).toggleEligibility,
            .disabled(.unsupportedCodemap)
        )
        harness.model.setCodeMapsGloballyDisabled(true)

        XCTAssertEqual(harness.model.addMode, .full)
        XCTAssertTrue(harness.model.codeMapsGloballyDisabled)
        XCTAssertTrue(try harness.model.toggleFile(XCTUnwrap(files["Mapped.swift"])))
        await eventually { harness.recorder.calls.count == 1 }
        XCTAssertEqual(harness.recorder.calls[0].targetState, .unselected)
    }

    @MainActor
    func testSameTabRefreshKeepsBrowseActiveAndSessionMatchingIsPure() async throws {
        let harness = try await makeHarness(files: ["One.swift"])
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let files = try await loadRootFiles(harness)
        let path = try XCTUnwrap(harness.paths["One.swift"])

        harness.model.applySelectionChange(
            WorkspaceSelectionCoordinator.Change(
                tabID: UUID(),
                selection: StoredSelection(selectedPaths: [path]),
                source: .runtimeMutation
            ),
            exportRows: []
        )
        XCTAssertNil(try harness.model.heldMode(for: XCTUnwrap(files["One.swift"])))

        harness.model.applySelectionChange(
            WorkspaceSelectionCoordinator.Change(
                tabID: harness.target.identity.tabID,
                selection: StoredSelection(selectedPaths: [path]),
                source: .runtimeMutation
            ),
            exportRows: []
        )
        XCTAssertEqual(try harness.model.heldMode(for: XCTUnwrap(files["One.swift"])), .full)
        XCTAssertTrue(harness.model.isActive)
        XCTAssertTrue(harness.model.sessionMatches(
            identity: harness.target.identity,
            lookupContext: .visibleWorkspace
        ))

        XCTAssertFalse(harness.model.sessionMatches(
            identity: WorkspaceSelectionIdentity(workspaceID: UUID(), tabID: UUID()),
            lookupContext: .visibleWorkspace
        ))
        XCTAssertEqual(harness.model.phase, .ready)
    }

    @MainActor
    func testRetainedModelUsesLatestFilesTabRouteProof() async throws {
        let harness = try await makeHarness(files: ["One.swift"])
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let files = try await loadRootFiles(harness)
        let file = try XCTUnwrap(files["One.swift"])
        harness.model.updateMutationRouteProof(AgentContextFileBrowseRouteProof(
            identity: harness.target.identity,
            lookupContext: WorkspaceLookupContext(
                rootScope: .visibleWorkspacePlusGitData,
                bindingProjection: nil
            )
        ))
        XCTAssertEqual(harness.model.fileStatus(for: file).toggleEligibility, .disabled(.routeUnavailable))
        XCTAssertFalse(harness.model.toggleFile(file))

        harness.model.updateMutationRouteProof(AgentContextFileBrowseRouteProof(
            identity: WorkspaceSelectionIdentity(workspaceID: UUID(), tabID: UUID()),
            lookupContext: .visibleWorkspace
        ))
        XCTAssertEqual(harness.model.phase, .ready)
        XCTAssertEqual(harness.model.fileStatus(for: file).toggleEligibility, .disabled(.routeUnavailable))
        XCTAssertFalse(harness.model.toggleFile(file))
        XCTAssertTrue(harness.recorder.calls.isEmpty)
    }

    @MainActor
    func testSearchAndRevalidationSessionScopeLossTransitionToUnavailable() async throws {
        let searchHarness = try await makeHarness(files: ["Search.swift"], sessionScoped: true)
        await searchHarness.model.begin(
            target: searchHarness.target,
            lookupContext: searchHarness.lookupContext,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        await searchHarness.store.unloadRoot(id: searchHarness.root.id)
        searchHarness.model.setQuery("Search")
        await eventually {
            searchHarness.model.phase == .unavailable(.sessionRootsUnavailable)
        }

        let mutationHarness = try await makeHarness(files: ["Mutation.swift"], sessionScoped: true)
        await mutationHarness.model.begin(
            target: mutationHarness.target,
            lookupContext: mutationHarness.lookupContext,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let files = try await loadRootFiles(mutationHarness)
        await mutationHarness.store.unloadRoot(id: mutationHarness.root.id)
        XCTAssertTrue(try mutationHarness.model.toggleFile(XCTUnwrap(files["Mutation.swift"])))
        await eventually {
            mutationHarness.model.phase == .unavailable(.sessionRootsUnavailable)
        }
        XCTAssertTrue(mutationHarness.recorder.calls.isEmpty)
    }

    @MainActor
    func testAcceptedMutationsRemainOrderedAcrossSessionExit() async throws {
        let harness = try await makeHarness(files: ["Old.swift", "NewOne.swift", "NewTwo.swift"])
        harness.recorder.suspendMutations = true
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let oldFiles = try await loadRootFiles(harness)
        XCTAssertTrue(try harness.model.toggleFile(XCTUnwrap(oldFiles["Old.swift"])))
        await eventually { harness.recorder.pendingMutationCount == 1 }
        XCTAssertEqual(harness.model.pendingMutationIdentities, [harness.target.identity])
        XCTAssertTrue(agentContextFilesReviewMutationIsFenced(
            pendingIdentities: harness.model.pendingMutationIdentities,
            targetIdentity: harness.target.identity
        ))

        harness.model.end()
        XCTAssertEqual(harness.model.pendingMutationIdentities, [harness.target.identity])
        let newTarget = AgentContextSelectionMutationTarget(
            identity: WorkspaceSelectionIdentity(workspaceID: UUID(), tabID: UUID()),
            expectedSelection: StoredSelection()
        )
        XCTAssertFalse(agentContextFilesReviewMutationIsFenced(
            pendingIdentities: harness.model.pendingMutationIdentities,
            targetIdentity: newTarget.identity
        ))
        harness.model.updateMutationRouteProof(AgentContextFileBrowseRouteProof(
            identity: newTarget.identity,
            lookupContext: .visibleWorkspace
        ))
        await harness.model.begin(
            target: newTarget,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let newFiles = try await loadRootFiles(harness)
        XCTAssertTrue(try harness.model.toggleFile(XCTUnwrap(newFiles["NewOne.swift"])))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(harness.recorder.calls.count, 1)
        XCTAssertEqual(harness.recorder.pendingMutationCount, 1)

        harness.recorder.resumeNextMutation()
        await eventually { harness.recorder.calls.count == 2 && harness.recorder.pendingMutationCount == 1 }
        XCTAssertTrue(try harness.model.toggleFile(XCTUnwrap(newFiles["NewTwo.swift"])))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(harness.recorder.calls.count, 2)

        harness.recorder.resumeNextMutation()
        await eventually { harness.recorder.calls.count == 3 && harness.recorder.pendingMutationCount == 1 }
        harness.recorder.resumeNextMutation()
        await eventually { harness.model.inFlightPaths.isEmpty }
        XCTAssertEqual(harness.recorder.calls.map(\.identity), [
            harness.target.identity,
            newTarget.identity,
            newTarget.identity
        ])
        XCTAssertTrue(harness.recorder.calls.allSatisfy { $0.lookupContext == .visibleWorkspace })
        await eventually { harness.model.pendingMutationIdentities.isEmpty }
    }

    @MainActor
    func testCompletedMutationDoesNotOverwriteNewerAuthoritativeSelection() async throws {
        let harness = try await makeHarness(files: ["Mutation.swift", "Authoritative.swift"])
        harness.recorder.suspendMutations = true
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let files = try await loadRootFiles(harness)
        let mutationFile = try XCTUnwrap(files["Mutation.swift"])
        let authoritativeFile = try XCTUnwrap(files["Authoritative.swift"])
        XCTAssertTrue(harness.model.toggleFile(mutationFile))
        await eventually { harness.recorder.pendingMutationCount == 1 }

        harness.model.updateAuthoritativeSelection(
            StoredSelection(selectedPaths: [authoritativeFile.standardizedFullPath]),
            exportRows: []
        )
        harness.recorder.resumeNextMutation()
        await eventually { harness.model.pendingMutationIdentities.isEmpty }

        XCTAssertNil(harness.model.heldMode(for: mutationFile))
        XCTAssertEqual(harness.model.heldMode(for: authoritativeFile), .full)
    }

    @MainActor
    func testPendingMutationFenceSurvivesFilesTabRemount() async throws {
        let harness = try await makeHarness(files: ["Pending.swift"])
        harness.recorder.suspendMutations = true
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let files = try await loadRootFiles(harness)
        XCTAssertTrue(try harness.model.toggleFile(XCTUnwrap(files["Pending.swift"])))
        await eventually { harness.recorder.pendingMutationCount == 1 }

        harness.model.end()
        let remountedFilesTabModel = harness.model
        XCTAssertTrue(agentContextFilesReviewMutationIsFenced(
            pendingIdentities: remountedFilesTabModel.pendingMutationIdentities,
            targetIdentity: harness.target.identity
        ))

        harness.recorder.resumeNextMutation()
        await eventually { remountedFilesTabModel.pendingMutationIdentities.isEmpty }
    }

    @MainActor
    func testMutationFailsClosedWhenCatalogChangesBeforeRevalidation() async throws {
        let harness = try await makeHarness(files: ["Stale.swift"])
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let files = try await loadRootFiles(harness)
        try await harness.store.deleteFile(rootID: harness.root.id, relativePath: "Stale.swift")

        XCTAssertTrue(try harness.model.toggleFile(XCTUnwrap(files["Stale.swift"])))
        await eventually { harness.model.phase == .unavailable(.catalogChanged) }
        XCTAssertTrue(harness.recorder.calls.isEmpty)
        XCTAssertTrue(harness.model.pendingMutationIdentities.isEmpty)
    }

    @MainActor
    func testMissingHierarchyWithChangedCatalogRequiresBrowseReentry() async throws {
        let harness = try await makeHarness(files: ["Missing.swift"])
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        await harness.store.unloadRoot(id: harness.root.id)

        harness.model.toggleExpansion(.root(harness.root.id))
        await eventually { harness.model.phase == .unavailable(.catalogChanged) }
        XCTAssertTrue(harness.recorder.calls.isEmpty)
    }

    @MainActor
    func testUnavailableMutationTargetPublishesNoticeAndUnavailablePhase() async throws {
        let harness = try await makeHarness(files: ["One.swift"], returnsUnavailableTarget: true)
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let files = try await loadRootFiles(harness)
        XCTAssertTrue(try harness.model.toggleFile(XCTUnwrap(files["One.swift"])))
        await eventually { harness.model.phase == .unavailable(.selectionTargetUnavailable) }

        XCTAssertEqual(harness.model.notice?.message, "Selection is no longer available")
        XCTAssertEqual(harness.model.accessibilityAnnouncement?.message, "Selection is no longer available")
    }

    @MainActor
    func testCollapsedAncestorShowsSelectedDescendantProvenance() async throws {
        let harness = try await makeHarness(files: [
            "Nested/Deep/Inner.swift",
            "Other/Untouched.swift"
        ])
        let selection = try StoredSelection(
            selectedPaths: [XCTUnwrap(harness.paths["Nested/Deep/Inner.swift"])]
        )
        harness.recorder.selection = selection
        let target = AgentContextSelectionMutationTarget(
            identity: harness.target.identity,
            expectedSelection: selection
        )
        await harness.model.begin(
            target: target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let rootNode = AgentContextFileBrowseNodeID.root(harness.root.id)

        XCTAssertNil(harness.model.membership(for: rootNode))
        XCTAssertEqual(harness.model.containerDisplayMembership(for: rootNode), .mixed)

        harness.model.toggleExpansion(rootNode)
        await eventually { self.folderNode(in: harness, named: "Nested") != nil }

        let nested = try XCTUnwrap(folderNode(in: harness, named: "Nested"))
        let other = try XCTUnwrap(folderNode(in: harness, named: "Other"))
        XCTAssertNil(harness.model.membership(for: nested))
        XCTAssertEqual(harness.model.containerDisplayMembership(for: nested), .mixed)
        XCTAssertEqual(
            harness.model.containerDisplayMembership(for: other),
            AgentContextFileBrowseContainerMembership.none
        )

        harness.model.updateAuthoritativeSelection(StoredSelection(), exportRows: [])
        XCTAssertEqual(
            harness.model.membership(for: rootNode),
            AgentContextFileBrowseContainerMembership.none
        )
        XCTAssertEqual(
            harness.model.containerDisplayMembership(for: nested),
            AgentContextFileBrowseContainerMembership.none
        )
        harness.model.updateAuthoritativeSelection(selection, exportRows: [])
        XCTAssertEqual(harness.model.membership(for: rootNode), .mixed)
        XCTAssertEqual(harness.model.containerDisplayMembership(for: nested), .mixed)
    }

    @MainActor
    func testExpansionIsRestoredOnSameRouteReentryAndClearedAcrossRoutes() async throws {
        let harness = try await makeHarness(files: ["Nested/Deep/Inner.swift"])
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let rootNode = AgentContextFileBrowseNodeID.root(harness.root.id)
        harness.model.toggleExpansion(rootNode)
        await eventually { self.folderNode(in: harness, named: "Nested") != nil }
        try harness.model.toggleExpansion(XCTUnwrap(folderNode(in: harness, named: "Nested")))
        await eventually { self.folderNode(in: harness, named: "Deep") != nil }
        harness.model.end()

        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        await eventually { self.folderNode(in: harness, named: "Deep") != nil }
        XCTAssertTrue(harness.model.expandedNodeIDs.contains(rootNode))

        harness.model.end()
        let otherRoute = AgentContextSelectionMutationTarget(
            identity: WorkspaceSelectionIdentity(workspaceID: UUID(), tabID: UUID()),
            expectedSelection: StoredSelection()
        )
        await harness.model.begin(
            target: otherRoute,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        XCTAssertTrue(harness.model.expandedNodeIDs.isEmpty)
        XCTAssertNil(folderNode(in: harness, named: "Nested"))
    }

    @MainActor
    func testTenThousandNestedFilesKeepExpansionLazyAndSelectionMembershipCorrect() async throws {
        let files = (0 ..< 10000).map { "Nested/File\($0).swift" }
        let harness = try await makeHarness(files: files)
        await harness.model.begin(
            target: harness.target,
            lookupContext: .visibleWorkspace,
            exportRows: [],
            codeMapsGloballyDisabled: false
        )
        let rootNode = AgentContextFileBrowseNodeID.root(harness.root.id)

        harness.model.toggleExpansion(rootNode)
        await eventually(attempts: 100_000) { harness.model.membership(for: rootNode) != nil }

        XCTAssertEqual(harness.model.rows.count, 2)

        let nestedNode = try XCTUnwrap(folderNode(in: harness, named: "Nested"))
        harness.model.toggleExpansion(nestedNode)
        await eventually(attempts: 100_000) { harness.model.membership(for: nestedNode) != nil }
        harness.model.toggleExpansion(nestedNode)
        XCTAssertEqual(harness.model.rows.count, 2)
        let selectedPath = try XCTUnwrap(harness.paths["Nested/File9999.swift"])
        harness.model.updateAuthoritativeSelection(StoredSelection(selectedPaths: [selectedPath]), exportRows: [])
        XCTAssertEqual(harness.model.membership(for: rootNode), .mixed)
        XCTAssertEqual(harness.model.membership(for: nestedNode), .mixed)
    }

    @MainActor
    private func folderNode(
        in harness: Harness,
        named name: String
    ) -> AgentContextFileBrowseNodeID? {
        harness.model.rows.compactMap { row -> AgentContextFileBrowseNodeID? in
            guard case let .folder(folder, _) = row, folder.name == name else { return nil }
            return .folder(folder.id)
        }.first
    }

    @MainActor
    private func makeHarness(
        files: [String],
        returnsUnavailableTarget: Bool = false,
        metadataReader: AgentContextFileSizeEstimator.MetadataReader? = nil,
        sessionScoped: Bool = false
    ) async throws -> Harness {
        let rootURL = try makeTestDirectory(name: "ContextBrowseModel")
        var paths: [String: String] = [:]
        for file in files {
            let url = rootURL.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "content for \(file)".write(to: url, atomically: true, encoding: .utf8)
            paths[file] = url.path
        }
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(
            path: rootURL.path,
            kind: sessionScoped ? .sessionWorktree : .primaryWorkspace
        )
        let lookupContext = if sessionScoped {
            WorkspaceLookupContext(
                rootScope: .sessionBoundWorkspace(
                    canonicalRootPaths: [],
                    physicalRootPaths: [root.standardizedFullPath]
                ),
                bindingProjection: nil
            )
        } else {
            WorkspaceLookupContext.visibleWorkspace
        }
        let service = AgentContextFileBrowseService(store: store)
        let metadataReads = MetadataReadCounter()
        let estimator = AgentContextFileSizeEstimator(metadataReader: metadataReader ?? { path in
            try await metadataReads.read(path: path)
        })
        let identity = WorkspaceSelectionIdentity(workspaceID: UUID(), tabID: UUID())
        let recorder = MutationRecorder(store: store)
        recorder.returnsUnavailableTarget = returnsUnavailableTarget
        let model = AgentContextFileBrowseModel(
            service: service,
            estimator: estimator,
            searchDebounceNanoseconds: 0,
            noticeDurationNanoseconds: 0
        ) { paths, targetState, identity, lookupContext in
            await recorder.execute(
                paths: paths,
                targetState: targetState,
                identity: identity,
                lookupContext: lookupContext
            )
        }
        model.updateMutationRouteProof(AgentContextFileBrowseRouteProof(
            identity: identity,
            lookupContext: lookupContext
        ))
        return Harness(
            model: model,
            recorder: recorder,
            store: store,
            root: root,
            target: AgentContextSelectionMutationTarget(identity: identity, expectedSelection: StoredSelection()),
            lookupContext: lookupContext,
            paths: paths,
            metadataReads: metadataReads
        )
    }

    @MainActor
    private func loadRootFiles(_ harness: Harness) async throws -> [String: AgentContextFileBrowseFile] {
        let rootNode = AgentContextFileBrowseNodeID.root(harness.root.id)
        harness.model.toggleExpansion(rootNode)
        await eventually {
            harness.model.rows.contains { row in
                if case .file = row { return true }
                return false
            }
        }
        return Dictionary(uniqueKeysWithValues: harness.model.rows.compactMap { row in
            guard case let .file(file, _) = row else { return nil }
            return (file.name, file)
        })
    }

    @MainActor
    private func eventually(
        attempts: Int = 2000,
        _ predicate: @MainActor () -> Bool
    ) async {
        for _ in 0 ..< attempts {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }

    private func makeCodemapRow(fileID: UUID, rootID: UUID, path: String) -> AgentContextExportRow {
        AgentContextExportRow(
            id: ResolvedPromptFileEntryID(fileID: fileID, mode: .codemap, lineRanges: nil),
            kind: .codemap,
            rootID: rootID,
            relativePath: URL(fileURLWithPath: path).lastPathComponent,
            displayPath: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            physicalPath: path,
            directoryDisplay: nil,
            lineRanges: nil,
            canRemove: true
        )
    }
}

@MainActor
private struct Harness {
    let model: AgentContextFileBrowseModel
    let recorder: MutationRecorder
    let store: WorkspaceFileContextStore
    let root: WorkspaceRootRecord
    let target: AgentContextSelectionMutationTarget
    let lookupContext: WorkspaceLookupContext
    let paths: [String: String]
    let metadataReads: MetadataReadCounter
}

private actor MetadataReadCounter {
    private(set) var count = 0

    func read(path: String) throws -> AgentContextFileMetadataSnapshot {
        count += 1
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey
        ])
        return AgentContextFileMetadataSnapshot(
            byteCount: values.fileSize.map(Int64.init),
            modificationDate: values.contentModificationDate,
            isRegularFile: values.isRegularFile == true
        )
    }
}

@MainActor
private final class MutationRecorder {
    struct Call: Equatable {
        let paths: [String]
        let targetState: WorkspacePreResolvedSelectionTargetState
        let identity: WorkspaceSelectionIdentity
        let lookupContext: WorkspaceLookupContext
    }

    var selection = StoredSelection()
    var calls: [Call] = []
    var suspendMutations = false
    var returnsUnavailableTarget = false
    private(set) var pendingMutationCount = 0

    private let mutationService: WorkspaceSelectionMutationService
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    init(store: WorkspaceFileContextStore) {
        mutationService = WorkspaceSelectionMutationService(store: store)
    }

    func execute(
        paths: [String],
        targetState: WorkspacePreResolvedSelectionTargetState,
        identity: WorkspaceSelectionIdentity,
        lookupContext: WorkspaceLookupContext
    ) async -> WorkspaceSelectionCoordinator.TransactionResult? {
        calls.append(Call(
            paths: paths,
            targetState: targetState,
            identity: identity,
            lookupContext: lookupContext
        ))
        if suspendMutations {
            pendingMutationCount += 1
            await withCheckedContinuation { continuation in
                pendingContinuations.append(continuation)
            }
            pendingMutationCount -= 1
        }
        guard !returnsUnavailableTarget else { return nil }
        let before = selection
        selection = mutationService.setPreResolvedFilePaths(
            base: selection,
            absolutePaths: paths,
            targetState: targetState
        )
        return WorkspaceSelectionCoordinator.TransactionResult(
            identity: identity,
            before: before,
            after: selection,
            revision: UInt64(calls.count)
        )
    }

    func resumeNextMutation() {
        pendingContinuations.removeFirst().resume()
    }
}
