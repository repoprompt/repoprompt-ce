@testable import RepoPromptApp
import RepoPromptFileSystem
import RepoPromptFoundation
import RepoPromptInstrumentation
@testable import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore
import XCTest

final class AgentFileTagWorktreeResolutionTests: XCTestCase {
    @MainActor
    func testRuntimeProviderInputUsesCapturedWorktreeContentWithoutPresentation() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let source = AgentSessionProviderInputRuntime.WorkspaceSource(
            store: fixture.store,
            lookupSource: .init(activeAgentSessionID: fixture.sessionID, worktreeBindings: [fixture.binding])
        )
        let scope = AgentSessionRuntimeStore().makeScope()
        let catalog = AgentSkillCatalog(homeDirectoryURL: fixture.logicalRoot.appendingPathComponent("home"))
        let input = scope.providerInput(skillCatalog: catalog, perfRecorder: NoopAgentModePerfRecorder())
        XCTAssertTrue(input === scope.providerInput(skillCatalog: catalog, perfRecorder: NoopAgentModePerfRecorder()))
        let text = await input.augmentUserMessage(
            "Inspect @Sources/App.swift", attachments: [], taggedFileAttachments: [], agent: .claudeCode,
            workspacePaths: [fixture.logicalRoot.path], workspace: { source }, session: nil,
            handoff: scope.handoff, ignoresPendingHandoff: true, skipsSlashExpansion: false, isCurrent: { true }
        )
        XCTAssertTrue(text.contains("let origin = \"worktree\""), text)
        XCTAssertFalse(text.contains("let origin = \"base\""), text)
        XCTAssertFalse(text.contains(fixture.worktreeRoot.path), text)
        XCTAssertEqual(text.components(separatedBy: "<file_contents>").count - 1, 1)
        let repeated = await input.augmentUserMessage(
            text, attachments: [], taggedFileAttachments: [], agent: .claudeCode,
            workspacePaths: [fixture.logicalRoot.path], workspace: { source }, session: nil,
            handoff: scope.handoff, ignoresPendingHandoff: true, skipsSlashExpansion: true, isCurrent: { true }
        )
        XCTAssertEqual(repeated, text)
        let context = await input.initialThreadContext(.init(
            workspace: source,
            selection: .init(selectedPaths: [fixture.logicalRoot.appendingPathComponent("Sources/App.swift").path]),
            promptText: "Captured prompt"
        ))
        XCTAssertTrue(context.fileTree.contains("App.swift"), context.fileTree)
        XCTAssertFalse(context.fileTree.contains(fixture.worktreeRoot.path), context.fileTree)
        let initial = AgentSessionProviderInputRuntime.composeInitialThreadMessage(
            initialMessage: "Inspect", fileTree: context.fileTree, promptText: context.promptText
        )
        XCTAssertTrue(initial.contains("<file_map>"), initial)
        XCTAssertTrue(initial.contains("<current_prompt_content>\nCaptured prompt\n</current_prompt_content>"), initial)
        XCTAssertTrue(initial.hasPrefix("Inspect\n\n"), initial)
        let session = AgentTabSession(tabID: UUID())
        let prepared = await input.buildInitialThreadMessageIfNeeded(
            session: session, initialMessage: "Inspect", input: {
                .init(workspace: source, selection: .init(selectedPaths: [fixture.logicalRoot.appendingPathComponent("Sources/App.swift").path]), promptText: "Captured prompt")
            }, isCurrent: { true }
        )
        XCTAssertEqual(prepared, initial, "The runtime owns the same initial-thread construction")
        let refused = await input.buildInitialThreadMessageIfNeeded(
            session: session, initialMessage: "Inspect", input: {
                XCTFail("A refused start must not capture prompt or selection")
                return nil
            }, isCurrent: { false }
        )
        XCTAssertEqual(refused, "Inspect")
        session.providerSessionID = "resumed-provider-session"
        let resumed = await input.buildInitialThreadMessageIfNeeded(
            session: session, initialMessage: "Inspect", input: {
                XCTFail("A resumed provider must not recapture initial-thread resources")
                return nil
            }, isCurrent: { true }
        )
        XCTAssertEqual(resumed, "Inspect")
    }

    @MainActor
    func testRuntimeInputResolvesPresentationSourceAfterSkillsAndHonorsRefusal() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: true)
        _ = await makeLookupContext(fixture: fixture)
        let commands = fixture.logicalRoot.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try "Inspect $ARGUMENTS".write(to: commands.appendingPathComponent("inspect.md"), atomically: true, encoding: .utf8)
        let scope = AgentSessionRuntimeStore().makeScope()
        let catalog = AgentSkillCatalog(homeDirectoryURL: fixture.logicalRoot.appendingPathComponent("home"))
        let input = scope.providerInput(skillCatalog: catalog, perfRecorder: NoopAgentModePerfRecorder())
        var sourceReads = 0
        let result = await input.augmentUserMessage(
            "/skill:inspect @Sources/App.swift", attachments: [], taggedFileAttachments: [], agent: .claudeCode,
            workspacePaths: [fixture.logicalRoot.path], workspace: {
                sourceReads += 1
                XCTAssertNotNil(catalog.resolve(name: "inspect"), "Binding inputs must be captured after skill discovery")
                // The same branch used while a binding transition is in progress. Hidden
                // worktree roots remain loaded, but must not become the visible fallback.
                return .init(store: fixture.store, lookupSource: nil)
            }, session: nil, handoff: scope.handoff, ignoresPendingHandoff: true,
            skipsSlashExpansion: false, isCurrent: { true }
        )
        XCTAssertEqual(sourceReads, 1)
        XCTAssertTrue(result.contains("<selected_skill_context name=\"inspect\""), result)
        XCTAssertTrue(result.contains("let origin = \"base\""), result)
        XCTAssertFalse(result.contains("let origin = \"worktree\""), result)
        let refused = await input.augmentUserMessage(
            "@Sources/App.swift", attachments: [], taggedFileAttachments: [], agent: .claudeCode,
            workspacePaths: [fixture.logicalRoot.path], workspace: {
                XCTFail("Refused input must not read workspace source")
                return .init(store: fixture.store, lookupSource: nil)
            }, session: nil, handoff: scope.handoff, ignoresPendingHandoff: true,
            skipsSlashExpansion: true, isCurrent: { false }
        )
        XCTAssertEqual(refused, "@Sources/App.swift")
    }

    @MainActor
    func testRuntimeSkillExpansionUsesExplicitRootsAndPreservesNativeCompactNamespace() async throws {
        let root = try makeTemporaryRoot(name: "RuntimeProviderSkills")
        let commands = root.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try "---\ndescription: Runtime skill\n---\nInspect $ARGUMENTS".write(to: commands.appendingPathComponent("compact.md"), atomically: true, encoding: .utf8)
        let catalog = AgentSkillCatalog(homeDirectoryURL: root.appendingPathComponent("home"))
        let input = AgentSessionProviderInputRuntime(skillCatalog: catalog)
        let native = await input.expandSlashSkillInvocationIfNeeded("/compact retain this", agentKind: .claudeCode, workspacePaths: [root.path])
        XCTAssertEqual(native, "/compact retain this")
        let expanded = await input.expandSlashSkillInvocationIfNeeded("/skill:compact retain this", agentKind: .claudeCode, workspacePaths: [root.path])
        XCTAssertTrue(expanded.contains("<selected_skill_context name=\"compact\""), expanded)
        XCTAssertTrue(expanded.contains("<user_instructions>\nretain this\n</user_instructions>"), expanded)
        XCTAssertFalse(expanded.contains("$ARGUMENTS"), expanded)
        let freshCatalog = AgentSkillCatalog(homeDirectoryURL: root.appendingPathComponent("home"))
        let unpublished = AgentSessionProviderInputRuntime(skillCatalog: freshCatalog)
        let refused = await unpublished.expandSlashSkillInvocationIfNeeded("/skill:compact do not publish", agentKind: .claudeCode, workspacePaths: [root.path], shouldPublishCatalog: { false })
        XCTAssertEqual(refused, "/skill:compact do not publish")
        XCTAssertNil(freshCatalog.resolve(name: "compact"), "A refused discovery must not publish a skill catalog")
    }

    @MainActor
    func testRuntimeSkillExpansionReadsJustInstalledSkillWithoutWatcherSignal() async throws {
        let root = try makeTemporaryRoot(name: "ProviderInputNewSkill")
        let catalog = AgentSkillCatalog(homeDirectoryURL: root.appendingPathComponent("home"))
        await catalog.refresh(workspacePaths: [root.path], agentKind: .openCode)
        XCTAssertNil(catalog.resolve(name: "large"))
        let content = String(repeating: "expanded context ", count: 1000) + "END_FIXTURE"
        try write("---\nname: large\ndescription: Fixture\n---\n\(content)", to: root.appendingPathComponent(".agents/skills/large/SKILL.md"))
        let input = AgentSessionProviderInputRuntime(skillCatalog: catalog)
        // No markDirty, debounce or watcher delivery: the unresolved-token fallback must
        // await direct filesystem discovery even though the initial cache is clean.
        let expanded = await input.expandSlashSkillInvocationIfNeeded("/large short", agentKind: .openCode, workspacePaths: [root.path])
        XCTAssertTrue(expanded.contains(content), "skill=true: the send must discover a just-installed skill")
        XCTAssertTrue(expanded.contains("<selected_skill_context name=\"large\""))
    }

    @MainActor
    func testRuntimeTaggedFileExpansionRetainsConcurrentCatalogPublication() async throws {
        let points: [WorkspaceFileContextStore.ExactFileSuspensionPoint] = [
            .candidateEligibility, .candidateObservation, .explicitMaterializationEligibility, .explicitManagedRegistration
        ]
        for point in points {
            for relativePath in [false, true] {
                try await assertRuntimeTaggedFileExpansion(point: point, relativePath: relativePath)
            }
        }
    }

    @MainActor
    func testRuntimeTaggedFileExpansionRetainsPublisherFileAddition() async throws {
        try await assertRuntimeTaggedFileExpansion(point: .candidateEligibility, relativePath: false, viaPublisher: true)
    }

    @MainActor
    private func assertRuntimeTaggedFileExpansion(
        point: WorkspaceFileContextStore.ExactFileSuspensionPoint,
        relativePath: Bool,
        viaPublisher: Bool = false
    ) async throws {
        let rootURL = try makeTemporaryRoot(name: "ProviderInputCatalogPublication")
        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        if viaPublisher {
            let attached = try await store.attachPublisherIngressWithoutStartingWatcherForTesting(rootID: root.id)
            XCTAssertTrue(attached, "Publisher ingress must be installed before emitting the controlled file-add")
        }
        let watcherGate = AgentFileTagTestAsyncGate()
        let lookupGate = AgentFileTagTestAsyncGate()
        // Hold natural watcher delivery so the absent -> published transition is controlled,
        // rather than depending on how soon FSEvents happens to deliver the new file.
        await store.setWatcherSinkWillApplyHandler { _ in await watcherGate.wait() }
        await store.setExactFileSuspensionGateForTesting(point: point, rootID: root.id) {
            await lookupGate.wait()
        }
        addTeardownBlock {
            await lookupGate.open()
            await watcherGate.open()
            await store.clearExactFileCandidateProbeGateForTesting()
            await store.setWatcherSinkWillApplyHandler(nil)
            await store.unloadRoot(id: root.id)
        }
        let content = String(repeating: "expanded context ", count: 1000) + "END_FIXTURE"
        let fileURL = rootURL.appendingPathComponent("large.txt")
        try write(content, to: fileURL)
        let before = await store.file(rootID: root.id, relativePath: "large.txt")
        XCTAssertNil(before)
        let input = AgentSessionProviderInputRuntime(skillCatalog: AgentSkillCatalog(homeDirectoryURL: rootURL.appendingPathComponent("home")))
        let scope = AgentSessionRuntimeStore().makeScope()
        let expansion = Task {
            await input.augmentUserMessage(
                "short", attachments: [], taggedFileAttachments: [.init(relativePath: relativePath ? "large.txt" : fileURL.path, displayName: "large.txt")],
                agent: .openCode, workspacePaths: [rootURL.path], workspace: { .init(store: store, lookupSource: nil) },
                session: nil, handoff: scope.handoff, ignoresPendingHandoff: true,
                skipsSlashExpansion: true, isCurrent: { true }
            )
        }
        addTeardownBlock {
            expansion.cancel()
            await lookupGate.open()
            await watcherGate.open()
            _ = await expansion.value
        }
        do {
            try await AsyncTestWait.waitUntil("tagged file lookup reached \(point)") { await lookupGate.didEnter() }
        } catch {
            await lookupGate.open()
            _ = await expansion.value
            throw error
        }
        // The paused lookup retains its captured gate, but later publication work must not
        // inherit that pause point. Exercise both explicit-write and publisher file-add ingress.
        await store.clearExactFileCandidateProbeGateForTesting()
        let published: WorkspaceFileRecord
        if viaPublisher {
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: root.id, deltas: [.fileAdded("large.txt")])
            await watcherGate.open()
            try await AsyncTestWait.waitUntil("publisher file-add is applied while lookup is suspended") {
                await store.file(rootID: root.id, relativePath: "large.txt") != nil
            }
            let record = await store.file(rootID: root.id, relativePath: "large.txt")
            published = try XCTUnwrap(record)
        } else {
            let publication = try await store.materializeCatalogFileAfterDiskWrite(rootID: root.id, relativePath: "large.txt")
            guard case let .materialized(record) = publication else { return XCTFail("Expected controlled catalog publication, got \(publication)") }
            published = record
        }
        await lookupGate.open()
        let expanded = await expansion.value
        XCTAssertTrue(expanded.contains(content), "skill=false, point=\(point), relativePath=\(relativePath): a catalog publication must not silently drop the attachment; got \(expanded)")
        XCTAssertEqual(expanded.components(separatedBy: "<file_contents>").count - 1, 1)
        let after = await store.file(rootID: root.id, relativePath: "large.txt")
        XCTAssertEqual(after?.id, published.id, "Lookup must retain the published identity, not manufacture a replacement")
        await watcherGate.open()
    }

    @MainActor
    func testPublishedExactFileAdoptionPreservesCancellationAndTurnoverFences() async throws {
        for change in ["cancel", "root", "record"] {
            let rootURL = try makeTemporaryRoot(name: "PublishedFileAdoption-\(change)")
            let store = WorkspaceFileContextStore()
            let root = try await store.loadRoot(path: rootURL.path)
            let watcherGate = AgentFileTagTestAsyncGate()
            let eligibilityGate = AgentFileTagTestAsyncGate()
            let adoptionGate = AgentFileTagTestAsyncGate()
            await store.setWatcherSinkWillApplyHandler { _ in await watcherGate.wait() }
            addTeardownBlock {
                await eligibilityGate.open()
                await adoptionGate.open()
                await watcherGate.open()
                await store.clearExactFileCandidateProbeGateForTesting()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.unloadRoot(id: root.id)
            }
            let fileURL = rootURL.appendingPathComponent("large.txt")
            try write("original contents", to: fileURL)
            let roots = await store.rootRefs(scope: .visibleWorkspace)
            await store.setExactFileSuspensionGateForTesting(point: .candidateEligibility, rootID: root.id) {
                await eligibilityGate.wait()
            }
            let resolution = Task {
                try await store.resolveExactExistingWorkspaceFile(.parse(fileURL.path), namespace: .identity(roots: roots))
            }
            addTeardownBlock {
                resolution.cancel()
                await eligibilityGate.open()
                await adoptionGate.open()
                await watcherGate.open()
                _ = try? await resolution.value
            }
            try await AsyncTestWait.waitUntil("uncatalogued file reaches eligibility for \(change)") { await eligibilityGate.didEnter() }
            await store.clearExactFileCandidateProbeGateForTesting()
            let publication = try await store.materializeCatalogFileAfterDiskWrite(rootID: root.id, relativePath: "large.txt")
            guard case let .materialized(original) = publication else { return XCTFail("Expected initial catalog publication") }
            await store.setExactFileSuspensionGateForTesting(point: .catalogValidation, rootID: root.id) {
                await adoptionGate.wait()
            }
            await eligibilityGate.open()
            try await AsyncTestWait.waitUntil("published record reaches validation for \(change)") { await adoptionGate.didEnter() }
            await store.clearExactFileCandidateProbeGateForTesting()
            if change == "cancel" {
                resolution.cancel()
            } else if change == "root" {
                await watcherGate.open()
                await store.setWatcherSinkWillApplyHandler(nil)
                await store.unloadRoot(id: root.id)
                let replacement = try await store.loadRoot(path: rootURL.path)
                XCTAssertNotEqual(replacement.id, root.id)
                addTeardownBlock { await store.unloadRoot(id: replacement.id) }
            } else {
                try FileManager.default.removeItem(at: fileURL)
                _ = await store.reconcileLoadedRootCatalogWithDisk(rootID: root.id)
                try write("replacement contents", to: fileURL)
                let replacement = try await store.materializeCatalogFileAfterDiskWrite(rootID: root.id, relativePath: "large.txt")
                guard case let .materialized(record) = replacement else { return XCTFail("Expected replacement catalog record") }
                XCTAssertNotEqual(record.id, original.id)
            }
            await adoptionGate.open()
            if change == "cancel" {
                do {
                    _ = try await resolution.value
                    XCTFail("Cancellation during adoption must throw, not become an unresolved path")
                } catch is CancellationError {}
            } else {
                let result = try await resolution.value
                guard case .issue(.unresolved) = result else { return XCTFail("Adoption must not cross \(change) turnover: \(result)") }
            }
            await watcherGate.open()
        }
    }

    @MainActor
    func testExpandedBoundWorktreeSuggestionUsesLogicalPathAndSubtitle() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: true)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let configuration = FileMentionPickerConfiguration.expanded
        let service = AgentFileTagSuggestionService(
            store: fixture.store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { lookupContext },
            maxResults: configuration.maxResults,
            showsFileSubtitles: configuration.showsFileSubtitles
        )

        let suggestions = await service.suggestions(for: "BranchOnly")
        let suggestion = try XCTUnwrap(suggestions.first { $0.relativePath == "Sources/BranchOnly.swift" })

        XCTAssertEqual(suggestion.subtitle, "Sources")
        XCTAssertEqual(suggestion.commitDisplayText, suggestion.relativePath)
        XCTAssertFalse(suggestions.contains { $0.relativePath.contains(".worktrees") }, String(describing: suggestions))
        XCTAssertFalse(suggestions.contains { $0.relativePath.contains(fixture.worktreeRoot.path) }, String(describing: suggestions))
    }

    @MainActor
    func testUnboundSuggestionDoesNotReadHiddenSessionWorktreeRoots() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: true)
        _ = await makeLookupContext(fixture: fixture) // Materializes the hidden session worktree root in the store.
        let service = AgentFileTagSuggestionService(
            store: fixture.store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: 5
        )

        let suggestions = await service.suggestions(for: "BranchOnly")

        XCTAssertTrue(suggestions.isEmpty, String(describing: suggestions))
    }

    func testProviderTaggedFileContentReadsWorktreeButDisplaysLogicalPathAndDedupes() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let physicalWorktreePath = fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").path

        let resolvedXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            ["Sources/App.swift", physicalWorktreePath],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: lookupContext
        )
        let xml = try XCTUnwrap(resolvedXML)

        XCTAssertTrue(xml.contains("File: Sources/App.swift"), xml)
        XCTAssertTrue(xml.contains("let origin = \"worktree\""), xml)
        XCTAssertFalse(xml.contains("let origin = \"base\""), xml)
        XCTAssertFalse(xml.contains(fixture.worktreeRoot.path), xml)
        XCTAssertEqual(xml.components(separatedBy: "let origin = \"worktree\"").count - 1, 1, xml)
    }

    func testPromotionLogicalizesStalePhysicalSelectionAndDedupesByEffectivePhysicalPath() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let physicalPath = fixture.worktreeRoot.appendingPathComponent("Sources/App.swift").path
        let logicalPath = fixture.logicalRoot.appendingPathComponent("Sources/App.swift").path
        let staleSelection = StoredSelection(
            selectedPaths: [physicalPath],

            slices: [physicalPath: [LineRange(start: 1, end: 1)]],
            codemapAutoEnabled: false
        )

        let updated = AgentModeViewModel.selectionByPromotingPathsToFullSelection(
            staleSelection,
            paths: [logicalPath],
            lookupContext: lookupContext
        )

        XCTAssertEqual(updated.selectedPaths, [logicalPath])
        XCTAssertTrue(updated.slices.isEmpty)
        XCTAssertFalse(updated.selectedPaths.contains { $0.contains(fixture.worktreeRoot.path) })
    }

    @MainActor
    func testNonNilSearchServiceFallsBackToStoreDuringHeldRootLoadEvent() async throws {
        let rootA = try makeTemporaryRoot(name: "AgentFileTagFreshnessA")
        let rootB = try makeTemporaryRoot(name: "AgentFileTagFreshnessB")
        try write("let existing = true\n", to: rootA.appendingPathComponent("Sources/Existing.swift"))
        try write("let fresh = true\n", to: rootB.appendingPathComponent("Sources/FreshlyAddedUnique.swift"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: rootA.path)
        let snapshotA = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let searchService = WorkspaceSearchService()
        let eventGate = AgentFileTagTestAsyncGate()
        let commitSignal = AgentFileTagTestAsyncSignal()
        addTeardownBlock {
            await searchService.setCatalogChangeWillHandleHandler(nil)
            await searchService.setAutomaticRebuildDidCommitHandler(nil)
            await eventGate.open()
            await searchService.stopKeepingFresh()
        }

        await searchService.startKeepingFresh(with: store, rootScope: .visibleWorkspace)
        await searchService.rebuildIndex(from: snapshotA)
        let service = AgentFileTagSuggestionService(
            store: store,
            searchService: searchService,
            selectionCoordinator: nil,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: 5
        )
        let warmSuggestions = await service.suggestions(for: "Existing")
        XCTAssertEqual(warmSuggestions.map(\.relativePath), ["Sources/Existing.swift"])

        await searchService.setCatalogChangeWillHandleHandler { event in
            guard event.kind == .rootLoaded, event.rootPath == rootB.path else { return }
            await eventGate.wait()
        }

        _ = try await store.loadRoot(path: rootB.path)
        await eventGate.waitUntilEntered()
        let currentGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)

        let suggestions = await service.suggestions(for: "FreshlyAddedUnique")
        let suggestion = try XCTUnwrap(suggestions.first)
        let expectedRelativePath = "\(rootB.lastPathComponent)/Sources/FreshlyAddedUnique.swift"

        XCTAssertEqual(suggestions.count, 1, String(describing: suggestions))
        XCTAssertEqual(suggestion.relativePath, expectedRelativePath)
        XCTAssertEqual(suggestion.commitDisplayText, suggestion.relativePath)
        XCTAssertFalse(suggestion.relativePath.hasPrefix("/"))
        XCTAssertFalse(suggestion.relativePath.contains(rootB.path))
        XCTAssertFalse(suggestion.commitDisplayText?.contains(rootB.path) == true)

        await searchService.setAutomaticRebuildDidCommitHandler { generation in
            guard generation == currentGeneration else { return }
            await commitSignal.signal()
        }
        await eventGate.open()
        await commitSignal.wait()

        let convergedSuggestions = await service.suggestions(for: "FreshlyAddedUnique")
        XCTAssertEqual(convergedSuggestions.map(\.relativePath), [expectedRelativePath])
    }

    @MainActor
    func testExpandedAgentFileTagsReturnMoreThanCompactCapWithParentSubtitles() async throws {
        let root = try makeTemporaryRoot(name: "AgentFileTagExpanded")
        let matchingFileCount = 80
        for index in 0 ..< matchingFileCount {
            let name = String(format: "Match%02d.swift", index)
            try write("let match\(index) = true\n", to: root.appendingPathComponent("Sources/\(name)"))
        }
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let config = FileMentionPickerConfiguration.expanded
        let service = AgentFileTagSuggestionService(
            store: store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: config.maxResults,
            showsFileSubtitles: config.showsFileSubtitles
        )

        let suggestions = await service.suggestions(for: "Match")

        XCTAssertEqual(suggestions.count, matchingFileCount, String(describing: suggestions))
        XCTAssertTrue(suggestions.count > FileMentionPickerConfiguration.compact.maxResults)
        XCTAssertTrue(suggestions.count > 64)
        XCTAssertTrue(suggestions.allSatisfy { $0.kind == .file })
        XCTAssertEqual(Set(suggestions.compactMap(\.subtitle)), ["Sources"])
        XCTAssertTrue(suggestions.allSatisfy { $0.commitDisplayText == $0.relativePath })
        XCTAssertTrue(suggestions.allSatisfy { $0.commitDisplayText?.hasPrefix("Sources/Match") == true })
    }

    @MainActor
    func testCompactAgentFileTagsPreserveDuplicateDisambiguationSubtitles() async throws {
        let firstRoot = try makeTemporaryRoot(name: "AgentFileTagDuplicateA")
        let secondRoot = try makeTemporaryRoot(name: "AgentFileTagDuplicateB")
        try write("let duplicate = \"a\"\n", to: firstRoot.appendingPathComponent("Sources/Shared.swift"))
        try write("let duplicate = \"b\"\n", to: secondRoot.appendingPathComponent("Sources/Shared.swift"))
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: firstRoot.path)
        _ = try await store.loadRoot(path: secondRoot.path)
        let service = AgentFileTagSuggestionService(
            store: store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: FileMentionPickerConfiguration.compact.maxResults,
            showsFileSubtitles: FileMentionPickerConfiguration.compact.showsFileSubtitles
        )

        let suggestions = await service.suggestions(for: "Shared")

        XCTAssertEqual(suggestions.count, 2, String(describing: suggestions))
        XCTAssertEqual(
            Set(suggestions.compactMap(\.subtitle)),
            [firstRoot.lastPathComponent, secondRoot.lastPathComponent]
        )
        XCTAssertTrue(suggestions.allSatisfy { $0.commitDisplayText == $0.relativePath })
        XCTAssertTrue(suggestions.allSatisfy { $0.commitDisplayText?.hasSuffix("Sources/Shared.swift") == true })
        XCTAssertFalse(suggestions.contains { $0.commitDisplayText?.hasPrefix("/") == true })
        XCTAssertFalse(suggestions.contains { $0.commitDisplayText?.contains(firstRoot.path) == true })
        XCTAssertFalse(suggestions.contains { $0.commitDisplayText?.contains(secondRoot.path) == true })
    }

    @MainActor
    func testSameNamedVisibleRootsUseNonAbsoluteResolvableFileTagPaths() async throws {
        let fixture = try makeSameNamedRootFixture()
        let selectedFile = fixture.secondRoot.appendingPathComponent("Sources/Target.swift")
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: fixture.firstRoot.path)
        _ = try await store.loadRoot(path: fixture.secondRoot.path)
        let host = FileTagSelectionHost(selection: StoredSelection(selectedPaths: [selectedFile.path]))
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: host, store: store)
        let service = AgentFileTagSuggestionService(
            store: store,
            searchService: nil,
            selectionCoordinator: coordinator,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: 5
        )

        let searchSuggestions = await service.suggestions(for: "Target")
        let searchTokenPaths = Set(searchSuggestions.map(\.relativePath))
        let fallbackSuggestions = await service.suggestions(for: "")
        let fallbackSuggestion = try XCTUnwrap(fallbackSuggestions.first)
        let expectedSecondToken = "B/SharedRoot/Sources/Target.swift"

        XCTAssertEqual(
            searchTokenPaths,
            ["A/SharedRoot/Sources/Target.swift", expectedSecondToken],
            String(describing: searchSuggestions)
        )
        XCTAssertEqual(fallbackSuggestion.relativePath, expectedSecondToken)
        XCTAssertEqual(fallbackSuggestion.commitDisplayText, expectedSecondToken)
        XCTAssertEqual(
            FileTagMentionHelper.committedReplacementText(for: fallbackSuggestion),
            "@B/SharedRoot/Sources/Target.swift "
        )
        XCTAssertEqual(AgentFileMentionText.attachmentDisplayName(for: fallbackSuggestion), expectedSecondToken)

        let allTokenText = searchSuggestions.flatMap { [$0.relativePath, $0.commitDisplayText ?? ""] } + [fallbackSuggestion.relativePath, fallbackSuggestion.commitDisplayText ?? ""]
        XCTAssertFalse(allTokenText.contains { $0.hasPrefix("/") }, allTokenText.joined(separator: "\n"))
        XCTAssertFalse(allTokenText.contains { $0.contains(fixture.base.path) }, allTokenText.joined(separator: "\n"))

        let resolvedXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            [expectedSecondToken],
            tokenBudget: 10000,
            maxFiles: 10,
            store: store
        )
        let xml = try XCTUnwrap(resolvedXML)

        XCTAssertTrue(xml.contains("File: \(expectedSecondToken)"), xml)
        XCTAssertTrue(xml.contains("let target = \"b\""), xml)
        XCTAssertFalse(xml.contains(fixture.base.path), xml)
    }

    func testSameNamedRootGeneratedAliasTakesPrecedenceOverShadowingRootAlias() async throws {
        let fixture = try makeSameNamedRootFixture()
        let shadowRoot = fixture.base.appendingPathComponent("Shadow/B", isDirectory: true)
        try write("let target = \"shadow\"\n", to: shadowRoot.appendingPathComponent("SharedRoot/Sources/Target.swift"))
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: fixture.firstRoot.path)
        _ = try await store.loadRoot(path: fixture.secondRoot.path)
        _ = try await store.loadRoot(path: shadowRoot.path)
        let generatedToken = "B/SharedRoot/Sources/Target.swift"

        let resolvedXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            [generatedToken],
            tokenBudget: 10000,
            maxFiles: 10,
            store: store
        )
        let xml = try XCTUnwrap(resolvedXML)

        XCTAssertTrue(xml.contains("File: \(generatedToken)"), xml)
        XCTAssertTrue(xml.contains("let target = \"b\""), xml)
        XCTAssertFalse(xml.contains("let target = \"shadow\""), xml)
        XCTAssertFalse(xml.contains(fixture.base.path), xml)
    }

    @MainActor
    func testSelectedFileFallbackCommitsPathfulSameBasenameFile() async throws {
        let root = try makeTemporaryRoot(name: "AgentFileTagSelectedFallback")
        try write("# first\n", to: root.appendingPathComponent("skills/writing/SKILL.md"))
        let selectedFile = root.appendingPathComponent("skills/engineering/tidy-first/SKILL.md")
        try write("# selected\n", to: selectedFile)
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let host = FileTagSelectionHost(selection: StoredSelection(selectedPaths: [selectedFile.path]))
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: host, store: store)
        let service = AgentFileTagSuggestionService(
            store: store,
            searchService: nil,
            selectionCoordinator: coordinator,
            lookupContextProvider: { .visibleWorkspace },
            maxResults: 5
        )

        let suggestions = await service.suggestions(for: "")
        let suggestion = try XCTUnwrap(suggestions.first)

        XCTAssertEqual(suggestions.count, 1, String(describing: suggestions))
        XCTAssertEqual(suggestion.displayName, "SKILL.md")
        XCTAssertEqual(suggestion.relativePath, "skills/engineering/tidy-first/SKILL.md")
        XCTAssertEqual(suggestion.commitDisplayText, suggestion.relativePath)
    }

    func testAgentFileMentionDisplayNamePrefersRelativePathOverBasenameDisplay() {
        let suggestion = MentionSuggestion(
            displayName: "SKILL.md",
            relativePath: "aAtila/skills/engineering/tidy-first/SKILL.md",
            kind: .file,
            commitDisplayText: "SKILL.md"
        )

        XCTAssertEqual(
            AgentFileMentionText.attachmentDisplayName(for: suggestion),
            "aAtila/skills/engineering/tidy-first/SKILL.md"
        )
    }

    func testAgentFileMentionRemovalRemovesPathfulInlineMention() {
        let path = "aAtila/skills/engineering/tidy-first/SKILL.md"
        let text = "Review @\(path) before continuing"

        let reduced = AgentFileMentionText.removingTaggedMention(
            displayName: path,
            relativePath: path,
            from: text
        )

        XCTAssertEqual(reduced, "Review before continuing")
    }

    @MainActor
    func testPartiallyBoundWorkspaceKeepsUnboundRootSuggestionDisplayRelative() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let unboundRoot = try makeTemporaryRoot(name: "AgentFileTagUnbound")
        try write("let unbound = true\n", to: unboundRoot.appendingPathComponent("Sources/Other.swift"))
        _ = try await fixture.store.loadRoot(path: unboundRoot.path)
        let lookupContext = await makeLookupContext(fixture: fixture)
        let service = AgentFileTagSuggestionService(
            store: fixture.store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: { lookupContext },
            maxResults: 5
        )

        let suggestions = await service.suggestions(for: "Other")
        let suggestion = try XCTUnwrap(suggestions.first { $0.relativePath.contains("Other.swift") })
        let logicalRootQualifiedSuggestions = await service.suggestions(for: "\(fixture.logicalRoot.lastPathComponent)/Sources/App")

        XCTAssertEqual(suggestion.commitDisplayText, suggestion.relativePath)
        XCTAssertFalse(suggestion.relativePath.hasPrefix("/"), String(describing: suggestions))
        XCTAssertFalse(suggestion.relativePath.contains(unboundRoot.path), String(describing: suggestions))
        XCTAssertFalse(suggestion.commitDisplayText?.contains(unboundRoot.path) == true, String(describing: suggestions))
        XCTAssertTrue(
            logicalRootQualifiedSuggestions.contains { $0.relativePath.contains("Sources/App.swift") },
            String(describing: logicalRootQualifiedSuggestions)
        )
        XCTAssertFalse(
            logicalRootQualifiedSuggestions.contains { $0.relativePath.contains(fixture.worktreeRoot.path) },
            String(describing: logicalRootQualifiedSuggestions)
        )
    }

    func testPartiallyBoundWorkspaceKeepsUnboundRootProviderDisplayRelative() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: false)
        let unboundRoot = try makeTemporaryRoot(name: "AgentFileTagProviderUnbound")
        let unboundFile = unboundRoot.appendingPathComponent("Sources/Other.swift")
        try write("let unbound = true\n", to: unboundFile)
        _ = try await fixture.store.loadRoot(path: unboundRoot.path)
        let lookupContext = await makeLookupContext(fixture: fixture)

        let resolvedXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            [unboundFile.path],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: lookupContext
        )
        let xml = try XCTUnwrap(resolvedXML)

        XCTAssertTrue(xml.contains("let unbound = true"), xml)
        XCTAssertFalse(xml.contains(unboundRoot.path), xml)
    }

    func testNonWorktreeProviderTaggedFileContentPreservesVisibleWorkspaceBehavior() async throws {
        let fixture = try await makeBoundFixture(includeBranchOnly: true)
        _ = await makeLookupContext(fixture: fixture) // Keep hidden worktree loaded; visible lookups must still ignore it.

        let resolvedVisibleXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            ["Sources/App.swift"],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: .visibleWorkspace
        )
        let visibleXML = try XCTUnwrap(resolvedVisibleXML)
        let hiddenXML = await AgentModeViewModel.taggedFileContentsXMLForTaggedPaths(
            ["Sources/BranchOnly.swift"],
            tokenBudget: 10000,
            maxFiles: 10,
            store: fixture.store,
            lookupContext: .visibleWorkspace
        )

        XCTAssertTrue(visibleXML.contains("let origin = \"base\""), visibleXML)
        XCTAssertFalse(visibleXML.contains("let origin = \"worktree\""), visibleXML)
        XCTAssertNil(hiddenXML)
    }

    private func makeBoundFixture(includeBranchOnly: Bool) async throws -> (
        logicalRoot: URL,
        worktreeRoot: URL,
        store: WorkspaceFileContextStore,
        sessionID: UUID,
        binding: AgentSessionWorktreeBinding
    ) {
        let logicalRoot = try makeTemporaryRoot(name: "AgentFileTagLogical")
        let worktreeRoot = try makeTemporaryRoot(name: "AgentFileTagWorktree")
        try write("let origin = \"base\"\n", to: logicalRoot.appendingPathComponent("Sources/App.swift"))
        try write("let origin = \"worktree\"\n", to: worktreeRoot.appendingPathComponent("Sources/App.swift"))
        if includeBranchOnly {
            try write("let branchOnly = true\n", to: worktreeRoot.appendingPathComponent("Sources/BranchOnly.swift"))
        }

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let sessionID = UUID()
        let binding = makeBinding(logicalRoot: logicalRoot, worktreeRoot: worktreeRoot)
        return (logicalRoot, worktreeRoot, store, sessionID, binding)
    }

    private func makeLookupContext(
        fixture: (
            logicalRoot: URL,
            worktreeRoot: URL,
            store: WorkspaceFileContextStore,
            sessionID: UUID,
            binding: AgentSessionWorktreeBinding
        )
    ) async -> WorkspaceLookupContext {
        await AgentWorkspaceLookupContextResolver.lookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: fixture.sessionID,
                worktreeBindings: [fixture.binding]
            ),
            store: fixture.store
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
        try makeTestDirectory(name: name)
    }

    private func makeSameNamedRootFixture() throws -> (base: URL, firstRoot: URL, secondRoot: URL) {
        let base = try makeTemporaryRoot(name: "AgentFileTagSameNamedRoots")
        let firstRoot = base.appendingPathComponent("A/SharedRoot", isDirectory: true)
        let secondRoot = base.appendingPathComponent("B/SharedRoot", isDirectory: true)
        try write("let target = \"a\"\n", to: firstRoot.appendingPathComponent("Sources/Target.swift"))
        try write("let target = \"b\"\n", to: secondRoot.appendingPathComponent("Sources/Target.swift"))
        return (base, firstRoot, secondRoot)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor AgentFileTagTestAsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignaled = false

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            if isSignaled {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }
}

private actor AgentFileTagTestAsyncGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var openContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasEntered = false
    private var isOpen = false

    func wait() async {
        if !hasEntered {
            hasEntered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                openContinuations.append(continuation)
            }
        }
    }

    func didEnter() -> Bool {
        hasEntered
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            if hasEntered {
                continuation.resume()
            } else {
                enteredContinuation = continuation
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = openContinuations
        openContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class FileTagSelectionHost: WorkspaceSelectionHost {
    var activeWorkspace: WorkspaceModel?
    var activeSelectionWorkspace: WorkspaceSelectionWorkspace? {
        activeWorkspace.map { workspace in
            WorkspaceSelectionWorkspace(
                id: workspace.id,
                activeComposeTabID: workspace.activeComposeTabID,
                firstComposeTabID: workspace.composeTabs.first?.id
            )
        }
    }

    var selectionMirrorContextRevision: UInt64 = 0

    init(selection: StoredSelection) {
        let tabID = UUID()
        let tab = ComposeTabState(id: tabID, name: "Agent", selection: selection)
        activeWorkspace = WorkspaceModel(
            id: UUID(),
            name: "Agent File Tags",
            repoPaths: [],
            composeTabs: [tab],
            activeComposeTabID: tabID
        )
    }

    func composeTab(with id: UUID) -> ComposeTabState? {
        activeWorkspace?.composeTabs.first { $0.id == id }
    }

    func composeTab(for identity: WorkspaceSelectionIdentity) -> ComposeTabState? {
        guard activeWorkspace?.id == identity.workspaceID else { return nil }
        return activeWorkspace?.composeTabs.first { $0.id == identity.tabID }
    }

    func selectionTab(for identity: WorkspaceSelectionIdentity) -> WorkspaceSelectionTab? {
        composeTab(for: identity).map { WorkspaceSelectionTab(id: $0.id, selection: $0.selection) }
    }

    func storeSelection(
        _ selection: StoredSelection,
        modifiedAt: Date,
        for identity: WorkspaceSelectionIdentity
    ) -> Bool {
        guard var tab = composeTab(for: identity) else { return false }
        tab.selection = selection
        tab.lastModified = modifiedAt
        return updateComposeTabStoredOnly(tab, inWorkspaceID: identity.workspaceID)
    }

    func publishActiveComposeTabSnapshot(commitToMemory _: Bool, touchModified _: Bool) {}

    @discardableResult
    func updateComposeTabStoredOnly(_ tab: ComposeTabState, inWorkspaceID workspaceID: UUID) -> Bool {
        guard var workspace = activeWorkspace, workspace.id == workspaceID,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        workspace.composeTabs[index] = tab
        activeWorkspace = workspace
        return true
    }

    func applySelectionMirrorAttempt(_: StoredSelection, forTabID _: UUID, workspaceID _: UUID) async {}
}
