import CoreServices
import Darwin
@testable import RepoPrompt
import XCTest

final class GitWorktreeCreationReceiptTests: XCTestCase {
    func testDeltaCompatibilityEvaluationCoversEveryFieldAndFailsClosed() throws {
        let base = WorkspaceRootSeedTestSupport.compatibilityKey()

        func target(mismatching field: WorkspaceRootSeedDeltaCompatibilityField) throws
            -> WorkspaceRootSeedCompatibilityKey
        {
            var namespace = base.repositoryNamespace
            var objectFormat = base.objectFormat
            var prefix = base.repositoryRelativeRootPrefix
            var inventorySchemaVersion = base.inventorySchemaVersion
            var mandatoryIgnore = base.policyIdentity.mandatoryIgnorePolicyIdentity
            var committedIgnore = base.policyIdentity.committedIgnoreControlDigest
            var configuredIgnore = base.policyIdentity.configuredIgnoreAuthorityDigest
            var attributes = base.policyIdentity.attributePolicyDigest
            var sparse = base.policyIdentity.sparsePolicyDigest
            var matcher = base.searchABI.matcherSchemaVersion
            var projectedKey = base.searchABI.projectedKeySchemaVersion
            var comparator = base.searchABI.comparatorSchemaVersion
            var normalization = base.searchABI.pathNormalizationSchemaVersion
            var excludes = base.policyIdentity.resolvedExcludesFileIdentity
            var externalAttributes = base.policyIdentity.resolvedAttributesFileIdentity

            switch field {
            case .repositoryNamespace:
                namespace = try GitBlobRepositoryNamespace(rawValue: String(repeating: "b", count: 64))
            case .objectFormat: objectFormat = .sha256
            case .repositoryRelativeRootPrefix: prefix = try GitRepositoryRelativeRootPrefix("Nested")
            case .inventorySchemaVersion: inventorySchemaVersion += 1
            case .mandatoryIgnorePolicyIdentity: mandatoryIgnore = "changed-mandatory-ignore"
            case .committedIgnoreControlDigest: committedIgnore = "changed-committed-ignore"
            case .configuredIgnoreAuthorityDigest: configuredIgnore = "changed-configured-ignore"
            case .attributePolicyDigest: attributes = "changed-attributes"
            case .sparsePolicyDigest: sparse = "changed-sparse"
            case .searchABIMatcherSchemaVersion: matcher += 1
            case .searchABIProjectedKeySchemaVersion: projectedKey += 1
            case .searchABIComparatorSchemaVersion: comparator += 1
            case .searchABIPathNormalizationSchemaVersion: normalization += 1
            case .resolvedExcludesFileIdentity:
                excludes = GitWorkspaceAuthorityContentIdentity(exists: true, sha256: "exclude-content", byteCount: 7)
            case .resolvedAttributesFileIdentity:
                externalAttributes = GitWorkspaceAuthorityContentIdentity(
                    exists: true,
                    sha256: "attribute-content",
                    byteCount: 9
                )
            }

            return WorkspaceRootSeedCompatibilityKey(
                repositoryNamespace: namespace,
                objectFormat: objectFormat,
                treeOID: base.treeOID,
                repositoryRelativeRootPrefix: prefix,
                inventorySchemaVersion: inventorySchemaVersion,
                policyIdentity: GitWorkspacePolicyIdentity(
                    mandatoryIgnorePolicyIdentity: mandatoryIgnore,
                    committedIgnoreControlDigest: committedIgnore,
                    configuredIgnoreAuthorityDigest: configuredIgnore,
                    attributePolicyDigest: attributes,
                    sparsePolicyDigest: sparse,
                    searchABI: GitWorkspaceSearchABIIdentity(
                        matcherSchemaVersion: matcher,
                        projectedKeySchemaVersion: projectedKey,
                        comparatorSchemaVersion: comparator,
                        pathNormalizationSchemaVersion: normalization
                    ),
                    resolvedExcludesFileIdentity: excludes,
                    resolvedAttributesFileIdentity: externalAttributes
                )
            )
        }

        XCTAssertEqual(
            WorkspaceRootSeedDeltaCompatibilityField.allCases.count,
            15
        )
        for field in WorkspaceRootSeedDeltaCompatibilityField.allCases {
            let target = try target(mismatching: field)
            let evaluation = target.deltaCompatibilityEvaluation(with: base, source: .hintEvaluator)
            XCTAssertEqual(evaluation.source, .hintEvaluator, field.rawValue)
            XCTAssertEqual(evaluation.decision, .incompatible, field.rawValue)
            XCTAssertEqual(evaluation.fieldEvaluations.map(\.field), WorkspaceRootSeedDeltaCompatibilityField.allCases)
            XCTAssertEqual(evaluation.mismatchedFields, [field], field.rawValue)
            XCTAssertEqual(evaluation.correctionRuleApplied, .none, field.rawValue)
            XCTAssertEqual(
                evaluation.fieldEvaluations.filter { $0.decision == .mismatch }.map(\.field),
                [field],
                field.rawValue
            )
            XCTAssertTrue(evaluation.fieldEvaluations.allSatisfy {
                $0.baseDigest.count == 64 && $0.targetDigest.count == 64
            })
            XCTAssertFalse(target.isDeltaCompatible(with: base), field.rawValue)
        }
    }

    func testDeltaCompatibilityEvaluationExcludesTreeAndFreezesMissingExternalRepresentationMismatch() {
        let base = WorkspaceRootSeedTestSupport.compatibilityKey(treeOID: WorkspaceRootSeedTestSupport.oid("1"))
        let differentTree = WorkspaceRootSeedCompatibilityKey(
            repositoryNamespace: base.repositoryNamespace,
            objectFormat: base.objectFormat,
            treeOID: WorkspaceRootSeedTestSupport.oid("2"),
            repositoryRelativeRootPrefix: base.repositoryRelativeRootPrefix,
            policyIdentity: base.policyIdentity
        )
        let treeEvaluation = differentTree.deltaCompatibilityEvaluation(with: base, source: .planner)
        XCTAssertEqual(treeEvaluation.source, .planner)
        XCTAssertEqual(treeEvaluation.decision, .compatible)
        XCTAssertEqual(treeEvaluation.mismatchedFields, [])
        XCTAssertEqual(treeEvaluation.treeRelation, .differentExcludedFromDeltaCompatibility)
        XCTAssertTrue(differentTree.isDeltaCompatible(with: base))

        let missingRepresentation = WorkspaceRootSeedCompatibilityKey(
            repositoryNamespace: base.repositoryNamespace,
            objectFormat: base.objectFormat,
            treeOID: base.treeOID,
            repositoryRelativeRootPrefix: base.repositoryRelativeRootPrefix,
            policyIdentity: GitWorkspacePolicyIdentity(
                mandatoryIgnorePolicyIdentity: base.policyIdentity.mandatoryIgnorePolicyIdentity,
                committedIgnoreControlDigest: base.policyIdentity.committedIgnoreControlDigest,
                configuredIgnoreAuthorityDigest: base.policyIdentity.configuredIgnoreAuthorityDigest,
                attributePolicyDigest: base.policyIdentity.attributePolicyDigest,
                sparsePolicyDigest: base.policyIdentity.sparsePolicyDigest,
                searchABI: base.searchABI,
                resolvedExcludesFileIdentity: GitWorkspaceAuthorityContentIdentity(
                    exists: false,
                    sha256: "",
                    byteCount: 0
                ),
                resolvedAttributesFileIdentity: nil
            )
        )
        let representationEvaluation = missingRepresentation.deltaCompatibilityEvaluation(
            with: base,
            source: .hintEvaluator
        )
        XCTAssertEqual(representationEvaluation.decision, .incompatible)
        XCTAssertEqual(representationEvaluation.mismatchedFields, [.resolvedExcludesFileIdentity])
        XCTAssertEqual(representationEvaluation.correctionRuleApplied, .none)
        XCTAssertFalse(String(describing: representationEvaluation).contains("exclude-content"))
    }

    func testObservedLivePolicyMismatchPairRemainsFailClosed() {
        let base = WorkspaceRootSeedTestSupport.compatibilityKey()
        let target = WorkspaceRootSeedCompatibilityKey(
            repositoryNamespace: base.repositoryNamespace,
            objectFormat: base.objectFormat,
            treeOID: base.treeOID,
            repositoryRelativeRootPrefix: base.repositoryRelativeRootPrefix,
            policyIdentity: GitWorkspacePolicyIdentity(
                mandatoryIgnorePolicyIdentity: base.policyIdentity.mandatoryIgnorePolicyIdentity,
                committedIgnoreControlDigest: "observed-live-committed-ignore-mismatch",
                configuredIgnoreAuthorityDigest: base.policyIdentity.configuredIgnoreAuthorityDigest,
                attributePolicyDigest: "observed-live-attribute-mismatch",
                sparsePolicyDigest: base.policyIdentity.sparsePolicyDigest,
                searchABI: base.searchABI,
                resolvedExcludesFileIdentity: base.policyIdentity.resolvedExcludesFileIdentity,
                resolvedAttributesFileIdentity: base.policyIdentity.resolvedAttributesFileIdentity
            )
        )
        let evaluation = target.deltaCompatibilityEvaluation(
            with: base,
            source: .hintEvaluator
        )

        XCTAssertEqual(evaluation.decision, .incompatible)
        XCTAssertEqual(
            evaluation.mismatchedFields,
            [.committedIgnoreControlDigest, .attributePolicyDigest]
        )
        XCTAssertEqual(evaluation.correctionRuleApplied, .none)
        XCTAssertEqual(
            evaluation.fieldEvaluations.filter { $0.decision == .match }.map(\.field),
            WorkspaceRootSeedDeltaCompatibilityField.allCases.filter {
                ![.committedIgnoreControlDigest, .attributePolicyDigest].contains($0)
            }
        )
    }

    func testWitnessCoverageRejectsZeroAndSinceNowJournalCuts() {
        func coverage(start: UInt64, end: UInt64) -> GitWorktreeCreationWitnessCoverage {
            GitWorktreeCreationWitnessCoverage(
                startedAtUptimeNanoseconds: 1,
                endedAtUptimeNanoseconds: 2,
                startEventID: start,
                endEventID: end,
                stableWatchRootAvailableBeforeMutation: true,
                destinationWasAbsentBeforeMutation: true,
                destinationWasStrictDescendant: true,
                stableWatchRootUnchangedAfterInitialization: true,
                streamCreationSucceeded: true,
                streamStartedBeforeMutation: true,
                activationFlushCompleted: true,
                activationCallbackBarrierCompleted: true,
                streamEndedAfterInitialization: true,
                endingFlushCompleted: true,
                endingCallbackBarrierCompleted: true,
                startAcceptedCallbackWatermark: 0,
                endAcceptedCallbackWatermark: 0,
                acceptedCallbackCount: 0,
                acceptedEventCount: 0,
                acceptedDestinationEventCount: 0,
                acceptedNonDestinationEventCount: 0,
                mustScanSubDirs: false,
                rootChanged: false,
                userDropped: false,
                kernelDropped: false,
                eventIDsWrapped: false,
                eventIDRegressed: false,
                lifetimeExceeded: false,
                hadGap: false,
                hadDrop: false,
                overflowed: false
            )
        }

        XCTAssertFalse(coverage(start: 0, end: 0).provesCreationInterval)
        XCTAssertFalse(coverage(start: UInt64.max, end: UInt64.max).provesCreationInterval)
        XCTAssertTrue(coverage(start: 10, end: 11).provesCreationInterval)
    }

    func testLoadedRootAdmissionAllowsPolicyIgnoredCommittedFilesButRejectsMissingDiscoverableCommittedFiles() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        try fixture.write(".repo_ignore", "Generated/\nIgnoredUntracked.tmp\n")
        try fixture.write("Visible.swift", "let committed = true\n")
        try fixture.write("Generated/Committed.swift", "let ignoredCommitted = true\n")
        try fixture.git(["add", ".repo_ignore", "Visible.swift"])
        try fixture.git(["add", "-f", "Generated/Committed.swift"])
        try fixture.git(["commit", "-m", "force-add policy ignored regular file"])
        let headBlobOID = try fixture.gitOutput(["rev-parse", "HEAD:Visible.swift"])

        try fixture.write("Visible.swift", "let dirtyWorktreeBytes = true\n")
        try fixture.write("VisibleUntracked.swift", "let overlayOnly = true\n")
        try fixture.write("IgnoredUntracked.tmp", "ignored untracked\n")
        let dirtyBlobOID = try fixture.gitOutput(["hash-object", "Visible.swift"])
        XCTAssertNotEqual(headBlobOID, dirtyBlobOID)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: fixture.root.path, kind: .sessionWorktree)
        addTeardownBlock { await store.unloadRoot(id: record.id) }
        guard case .materialized = try await store.materializeCatalogFileAfterDiskWrite(
            rootID: record.id,
            relativePath: "Generated/Committed.swift"
        ) else {
            return XCTFail("Expected ignored committed path to materialize as managed-only")
        }

        let admission = try await store.admitReusableSnapshotForLoadedRoot(
            rootID: record.id,
            expectedStandardizedPath: record.standardizedFullPath
        )
        guard case let .admitted(identity) = admission else {
            return XCTFail("Expected policy-ignored committed file admission, got \(admission)")
        }

        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("")
        let sharedAuthority = GitWorkspaceStateAuthority.shared
        let git = GitService(workspaceStateAuthority: sharedAuthority)
        let captured = try await git.workspaceAuthoritySnapshot(in: layout, prefix: prefix)
        let snapshot = await sharedAuthority.reusableSnapshot(
            identity: identity,
            expectedCompatibilityKey: WorkspaceRootSeedCompatibilityKey(authority: captured.snapshot)
        )
        let reusable = try XCTUnwrap(snapshot)
        let visibleCommitted: Set = [
            ".gitignore", ".repo_ignore", ".worktreeinclude", "Tracked.swift", "Visible.swift"
        ]
        XCTAssertEqual(Set(reusable.searchBase.relativePaths), visibleCommitted)
        XCTAssertEqual(
            Set(reusable.inventory.entries.filter(\.isSearchableFile).map(\.relativePath)),
            visibleCommitted
        )
        let ignoredEntry = try XCTUnwrap(reusable.inventory.entries.first {
            $0.relativePath == "Generated/Committed.swift"
        })
        XCTAssertEqual(ignoredEntry.catalogProjection, .policyIgnoredRegularFile)
        XCTAssertFalse(ignoredEntry.isSearchableFile)
        XCTAssertFalse(reusable.inventory.entries.contains { $0.relativePath == "VisibleUntracked.swift" })
        XCTAssertFalse(reusable.inventory.entries.contains { $0.relativePath == "IgnoredUntracked.tmp" })
        let dirtyEntry = try XCTUnwrap(reusable.inventory.entries.first { $0.relativePath == "Visible.swift" })
        XCTAssertEqual(dirtyEntry.objectID.lowercaseHex, headBlobOID)
        XCTAssertNotEqual(dirtyEntry.objectID.lowercaseHex, dirtyBlobOID)

        let discoverable = await Set(store.files(inRoot: record.id).map(\.standardizedRelativePath))
        XCTAssertTrue(discoverable.contains("VisibleUntracked.swift"))
        XCTAssertFalse(discoverable.contains("Generated/Committed.swift"))
        XCTAssertFalse(discoverable.contains("IgnoredUntracked.tmp"))
        let loadedService = await store.fileSystemServiceForTesting(rootID: record.id)
        let service = try XCTUnwrap(loadedService)
        let catalogPolicyIdentity = await service.currentWorkspaceRootCatalogPolicyIdentity()
        let rejectingAuthority = GitWorkspaceStateAuthority()
        let rejectingCoordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: rejectingAuthority),
            authority: rejectingAuthority
        )
        let rejection = await rejectingCoordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: discoverable.subtracting(["Visible.swift"]),
            catalogPolicyIdentity: catalogPolicyIdentity,
            catalogEvidenceProvider: { paths in
                await service.catalogProjectionEvidence(forCommittedRegularPaths: paths)
            }
        )
        XCTAssertEqual(rejection, .catalogMismatch)
    }

    func testCatalogAdmissionRejectsCanonicalEquivalentByteDistinctGitPaths() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let composed = "Caf\u{00E9}.swift"
        let decomposed = "Cafe\u{0301}.swift"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))

        try fixture.git(["config", "core.precomposeunicode", "false"])
        let blobOID = try fixture.gitOutput(["rev-parse", "HEAD:Tracked.swift"])
        try fixture.git(["update-index", "--add", "--cacheinfo", "100644,\(blobOID),\(composed)"])
        try fixture.git(["update-index", "--add", "--cacheinfo", "100644,\(blobOID),\(decomposed)"])
        try fixture.git(["commit", "-m", "byte-distinct unicode catalog collision"])

        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: authority),
            authority: authority
        )
        let result = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        )
        XCTAssertEqual(result, .catalogMismatch)
    }

    func testSubdirectoryReceiptPlansOnlyCorrespondingPhysicalRoot() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        try fixture.write("Subdir/Inside.swift", "let inside = true\n")
        try fixture.git(["add", "Subdir/Inside.swift"])
        try fixture.git(["commit", "-m", "subdirectory root"])

        let logicalRoot = fixture.root.appendingPathComponent("Subdir", isDirectory: true)
        let prefix = try GitRepositoryRelativeRootPrefix("Subdir")
        let authority = GitWorkspaceStateAuthority.shared
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
            rootURL: logicalRoot,
            authoritativeRelativeFilePaths: ["Inside.swift"]
        ) else { return XCTFail("Expected prefix-scoped reusable snapshot") }

        let initializationContext = GitWorktreeInitializationContext(
            agentSessionID: fixture.agentSessionID,
            correlationID: fixture.correlationID,
            logicalRootPath: logicalRoot.path,
            expectedOwnerBindingGeneration: fixture.expectedOwnerBindingGeneration,
            repositoryRelativeRootPrefix: prefix,
            observeReceipt: true
        )
        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: initializationContext
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        let physicalRoot = URL(fileURLWithPath: result.descriptor.path, isDirectory: true)
            .appendingPathComponent(prefix.value, isDirectory: true)
            .standardizedFileURL.path
        let binding = AgentSessionWorktreeBinding(
            id: "subdir-binding",
            repositoryID: result.descriptor.repository.repositoryID,
            repoKey: result.descriptor.repository.repoKey,
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: result.descriptor.worktreeID,
            worktreeRootPath: physicalRoot,
            source: "test"
        )
        let startupContext = fixture.startupContext()
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: physicalRoot,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        ).validated(
            matching: binding,
            sessionID: fixture.agentSessionID,
            startupContext: startupContext
        )
        XCTAssertNil(hint.validationFallbackReason)

        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: logicalRoot.path)
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
        WorktreeStartupInstrumentation.resetForTesting()
        let preparation = try await materializer.prepare(
            sessionID: fixture.agentSessionID,
            bindings: [binding],
            startupContext: startupContext,
            initializationHintsByBindingID: [binding.id: hint]
        )
        XCTAssertEqual(
            preparation.ownership.materializationHintObservationsByPhysicalRootPath[physicalRoot],
            .eligible(receipt.parentSnapshotIdentity)
        )
        XCTAssertEqual(WorktreeStartupInstrumentation.snapshot().shadow.inventoryMatches, 1)
        await materializer.abort(preparation)
        await store.unloadRoot(id: logicalRecord.id)
    }

    func testPolicyProjectedLinkedWorktreeSubdirectoryMatchesOrdinaryCatalogExactly() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        try fixture.write(
            "Subdir/.repo_ignore",
            "Ignored/\nVisibleOnly/*.tmp\nVisibleSymlinkParent/IgnoredDirLink\n"
        )
        try fixture.write("Subdir/MiXeD.swift", "let mixedCase = true\n")
        try fixture.write("Subdir/文件.swift", "let unicode = true\n")
        try fixture.write("Subdir/Ignored/Committed.swift", "let ignoredCommitted = true\n")
        try fixture.write("Subdir/VisibleOnly/OnlyIgnored.tmp", "ignored file only\n")
        try fixture.write("Sibling.swift", "let sibling = true\n")
        let links = fixture.root.appendingPathComponent("Subdir/Links", isDirectory: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: links.appendingPathComponent("Current").path,
            withDestinationPath: "../MiXeD.swift"
        )
        let visibleSymlinkParent = fixture.root
            .appendingPathComponent("Subdir/VisibleSymlinkParent", isDirectory: true)
        try FileManager.default.createDirectory(at: visibleSymlinkParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: visibleSymlinkParent.appendingPathComponent("IgnoredDirLink").path,
            withDestinationPath: "../Ignored"
        )
        try fixture.git([
            "add", "Subdir/.repo_ignore", "Subdir/MiXeD.swift", "Subdir/文件.swift",
            "Subdir/Links/Current", "Sibling.swift"
        ])
        try fixture.git([
            "add", "-f", "Subdir/Ignored/Committed.swift", "Subdir/VisibleOnly/OnlyIgnored.tmp",
            "Subdir/VisibleSymlinkParent/IgnoredDirLink"
        ])
        try fixture.git(["commit", "-m", "subdirectory catalog policy fixture"])

        let logicalRoot = fixture.root.appendingPathComponent("Subdir", isDirectory: true)
        let prefix = try GitRepositoryRelativeRootPrefix("Subdir")
        let sourceStore = WorkspaceFileContextStore()
        let sourceRecord = try await sourceStore.loadRoot(path: logicalRoot.path, kind: .sessionWorktree)
        addTeardownBlock { await sourceStore.unloadRoot(id: sourceRecord.id) }
        guard case .materialized = try await sourceStore.materializeCatalogFileAfterDiskWrite(
            rootID: sourceRecord.id,
            relativePath: "Ignored/Committed.swift"
        ) else {
            return XCTFail("Expected ignored source file to materialize as managed-only")
        }
        let admission = try await sourceStore.admitReusableSnapshotForLoadedRoot(
            rootID: sourceRecord.id,
            expectedStandardizedPath: sourceRecord.standardizedFullPath
        )
        guard case let .admitted(snapshotIdentity) = admission else {
            return XCTFail("Expected subdirectory snapshot admission, got \(admission)")
        }

        let authority = GitWorkspaceStateAuthority.shared
        let git = GitService(workspaceStateAuthority: authority)
        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: GitWorktreeInitializationContext(
                agentSessionID: fixture.agentSessionID,
                correlationID: fixture.correlationID,
                logicalRootPath: logicalRoot.path,
                expectedOwnerBindingGeneration: fixture.expectedOwnerBindingGeneration,
                repositoryRelativeRootPrefix: prefix,
                observeReceipt: true
            )
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        XCTAssertEqual(receipt.parentSnapshotIdentity, snapshotIdentity)
        XCTAssertEqual(receipt.repositoryRelativeRootPrefix, prefix)
        let physicalRoot = URL(fileURLWithPath: result.descriptor.path, isDirectory: true)
            .appendingPathComponent(prefix.value, isDirectory: true)
            .standardizedFileURL.path
        let binding = AgentSessionWorktreeBinding(
            id: "policy-prefix-binding",
            repositoryID: result.descriptor.repository.repositoryID,
            repoKey: result.descriptor.repository.repoKey,
            logicalRootPath: logicalRoot.path,
            logicalRootName: logicalRoot.lastPathComponent,
            worktreeID: result.descriptor.worktreeID,
            worktreeRootPath: physicalRoot,
            source: "test"
        )
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: physicalRoot,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        ).validated(
            matching: binding,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext()
        )
        XCTAssertNil(hint.validationFallbackReason)

        let targetStore = WorkspaceFileContextStore()
        let targetRecord = try await targetStore.loadRoot(path: physicalRoot, kind: .sessionWorktree)
        addTeardownBlock { await targetStore.unloadRoot(id: targetRecord.id) }
        let loadedTargetService = await targetStore.fileSystemServiceForTesting(rootID: targetRecord.id)
        let targetService = try XCTUnwrap(loadedTargetService)
        let planner = WorkspaceRootSeedPlanner(gitService: git, authority: authority)
        let planning = await planner.plan(hint: hint, service: targetService)
        guard case let .planned(plan) = planning else {
            return XCTFail("Expected linked-subdirectory policy plan, got \(planning)")
        }

        let ordinaryFiles = await Set(targetStore.files(inRoot: targetRecord.id).map(\.standardizedRelativePath))
        let ordinaryFolders = await Set(targetStore.folders(inRoot: targetRecord.id).map(\.standardizedRelativePath))
            .subtracting([""])
        let expectedFiles: Set = [".repo_ignore", "MiXeD.swift", "文件.swift"]
        XCTAssertEqual(ordinaryFiles, expectedFiles)
        XCTAssertEqual(ordinaryFolders, ["Links", "VisibleOnly", "VisibleSymlinkParent"])
        var plannedFiles = Set<String>()
        var plannedFolders = Set<String>()
        var policyIgnoredFiles = Set<String>()
        var overlayFiles = Set<String>()
        let planReader = try plan.makeReader()
        while let record = try planReader.next() {
            let path = try XCTUnwrap(String(data: record.relativePathBytes, encoding: .utf8))
            switch record.disposition {
            case .ordinaryFile:
                plannedFiles.insert(path)
                if record.baseAction == .overlay { overlayFiles.insert(path) }
            case .ordinaryDirectory:
                plannedFolders.insert(path)
            case .policyIgnoredTrackedFile:
                policyIgnoredFiles.insert(path)
            case .baseTombstone:
                break
            }
        }
        XCTAssertEqual(planReader.validationState, .verified)
        XCTAssertEqual(plannedFiles, ordinaryFiles)
        XCTAssertEqual(plannedFolders, ordinaryFolders)
        XCTAssertEqual(policyIgnoredFiles, [
            "Ignored/Committed.swift", "Links/Current",
            "VisibleOnly/OnlyIgnored.tmp", "VisibleSymlinkParent/IgnoredDirLink"
        ])
        XCTAssertTrue(overlayFiles.isEmpty)
        XCTAssertTrue(plannedFiles.isDisjoint(with: policyIgnoredFiles))

        let snapshot = await authority.reusableSnapshot(
            identity: receipt.parentSnapshotIdentity,
            expectedCompatibilityKey: receipt.parentCompatibilityKey
        )
        let reusable = try XCTUnwrap(snapshot)
        XCTAssertEqual(Set(reusable.searchBase.relativePaths), expectedFiles)
        XCTAssertTrue(reusable.inventory.entries.contains {
            $0.relativePath == "Ignored/Committed.swift"
                && $0.catalogProjection == .policyIgnoredRegularFile
        })
        XCTAssertTrue(reusable.inventory.entries.contains {
            $0.relativePath == "Links/Current"
                && $0.mode == "120000"
                && $0.catalogProjection == .nonRegularTopology
        })
        XCTAssertTrue(reusable.inventory.entries.contains {
            $0.relativePath == "VisibleOnly/OnlyIgnored.tmp"
                && $0.catalogProjection == .policyIgnoredRegularFile
        })
        XCTAssertTrue(reusable.inventory.entries.contains {
            $0.relativePath == "VisibleSymlinkParent/IgnoredDirLink"
                && $0.mode == "120000"
                && $0.catalogProjection == .nonRegularTopology
        })
        XCTAssertFalse(reusable.searchBase.relativePaths.contains("Links/Current"))
        XCTAssertFalse(reusable.inventory.entries.contains { $0.relativePath == "Sibling.swift" })
        XCTAssertFalse(reusable.inventory.entries.contains {
            $0.relativePath == ".git" || $0.relativePath.hasPrefix(".git/")
        })
    }

    func testReceiptKeepsReusableParentWhenRequestedTargetTreeDiffers() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        try fixture.write("Tracked.swift", "let value = 2\n")
        try fixture.git(["add", "Tracked.swift"])
        try fixture.git(["commit", "-m", "new parent snapshot"])

        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case let .admitted(snapshotIdentity) = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        ) else { return XCTFail("Expected reusable parent snapshot") }

        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(baseRef: "HEAD~1"),
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        XCTAssertEqual(receipt.parentSnapshotIdentity, snapshotIdentity)
        XCTAssertNotEqual(receipt.parentCompatibilityKey.treeOID, receipt.resolvedBaseTreeOID)
        XCTAssertEqual(receipt.targetAuthorityAfter.treeOID, receipt.resolvedBaseTreeOID)
        XCTAssertNil(receipt.fallbackReason())

        let binding = fixture.binding(for: result.descriptor)
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: binding.worktreeRootPath,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        ).validated(
            matching: binding,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext()
        )
        let evaluator = WorkspaceRootMaterializationHintEvaluator(gitService: git, authority: authority)
        let eligibility = await evaluator.observe(hint, observationEnabled: true)
        XCTAssertEqual(eligibility, .eligible(snapshotIdentity))
    }

    func testSameRepositoryLinkedWorktreeReceiptIsEligibleAndCarriesExactScope() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)

        let observed = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        )
        guard case let .admitted(snapshotIdentity) = observed else {
            return XCTFail("Expected reusable parent snapshot, got \(observed)")
        }

        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        XCTAssertEqual(receipt.parentSnapshotIdentity, snapshotIdentity)
        XCTAssertEqual(receipt.parentCompatibilityKey.treeOID, receipt.resolvedBaseTreeOID)
        XCTAssertEqual(receipt.parentCompatibilityKey, WorkspaceRootSeedCompatibilityKey(authority: receipt.parentAuthorityBefore))
        XCTAssertEqual(receipt.parentCompatibilityKey, WorkspaceRootSeedCompatibilityKey(authority: receipt.targetAuthorityAfter))
        XCTAssertEqual(receipt.repositoryRelativeRootPrefix.value, "")
        XCTAssertEqual(receipt.worktree.worktreeID, result.descriptor.worktreeID)
        XCTAssertEqual(receipt.targetLayout.workTreeRoot.standardizedFileURL.path, result.descriptor.path)
        XCTAssertEqual(receipt.exactCopiedRelativePaths, ["nested/ignored.txt", "secret.txt"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: result.descriptor.path)
                .appendingPathComponent("nested/ignored.txt").path
        ))
        XCTAssertTrue(receipt.witnessCoverage.provesCreationInterval)
        XCTAssertNil(receipt.fallbackReason())

        let binding = fixture.binding(for: result.descriptor)
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: binding.worktreeRootPath,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        ).validated(
            matching: binding,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext()
        )
        let evaluator = WorkspaceRootMaterializationHintEvaluator(gitService: git, authority: authority)
        let eligibility = await evaluator.observe(hint, observationEnabled: true)
        XCTAssertEqual(eligibility, .eligible(snapshotIdentity))
    }

    func testLoadedRootAdmissionRaceRevokesProvisionalAliasAndCoverage() async throws {
        let fixture = try ReceiptFixture()
        addTeardownBlock { fixture.cleanup() }
        let defaults = UserDefaults.standard
        let previousObserve = defaults.object(forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
        let previousServe = defaults.object(forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
        defaults.set(false, forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
        defaults.set(false, forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
        defer {
            if let previousObserve {
                defaults.set(previousObserve, forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
            } else {
                defaults.removeObject(forKey: WorktreeStartupFeatureFlags.observeDefaultsKey)
            }
            if let previousServe {
                defaults.set(previousServe, forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
            } else {
                defaults.removeObject(forKey: WorktreeStartupFeatureFlags.serveDefaultsKey)
            }
        }

        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: fixture.root.path)
        let attachedSyntheticIngress = try await store.attachPublisherIngressWithoutStartingWatcherForTesting(
            rootID: logicalRecord.id
        )
        XCTAssertTrue(
            attachedSyntheticIngress,
            "The test injects a synthetic watcher watermark and should not race the real macOS watcher."
        )
        let authority = GitWorkspaceStateAuthority.shared
        let coordinator = WorkspaceRootReusableSnapshotCoordinator.shared
        let baselineCache = await authority.snapshotForTesting()
        let monitor = await authority.metadataMonitorForTesting()
        let baselineCoverage = await monitor.snapshotForTesting()
        addTeardownBlock {
            await coordinator.setPreparedAdmissionHandlerForTesting(nil)
            await store.stopWatchingRoot(id: logicalRecord.id)
            await store.unloadRoot(id: logicalRecord.id)
        }

        await coordinator.setPreparedAdmissionHandlerForTesting {
            _ = try? await store.acceptWatcherPayloadForTesting(
                rootID: logicalRecord.id,
                events: [(
                    absolutePath: fixture.root.appendingPathComponent("Tracked.swift").path,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile
                    ),
                    eventId: 9001
                )],
                scheduleDrain: false
            )
        }
        let admission = try await store.admitReusableSnapshotForLoadedRoot(
            rootID: logicalRecord.id,
            expectedStandardizedPath: logicalRecord.standardizedFullPath
        )
        await coordinator.setPreparedAdmissionHandlerForTesting(nil)

        XCTAssertEqual(
            admission,
            .failed(.init(stage: .preparedAdmissionCurrentness, cause: .loadedRootWatcherStale))
        )
        let cache = await authority.snapshotForTesting()
        let coverage = await monitor.snapshotForTesting()
        XCTAssertEqual(cache.reusableSnapshotCount, baselineCache.reusableSnapshotCount)
        XCTAssertEqual(cache.reusableSnapshotAliasCount, baselineCache.reusableSnapshotAliasCount)
        XCTAssertEqual(cache.reusableSnapshotEstimatedBytes, baselineCache.reusableSnapshotEstimatedBytes)
        XCTAssertEqual(coverage.retainTokenCount, baselineCoverage.retainTokenCount)
        XCTAssertEqual(coverage.retainedRepositoryCount, baselineCoverage.retainedRepositoryCount)
    }

    func testLoadedRootAdmissionCurrentnessClassifiesOwnerStaleness() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: fixture.root.path)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator.shared
        await coordinator.setPreparedAdmissionHandlerForTesting {
            await store.unloadRoot(id: logicalRecord.id)
        }

        let admission = try await store.admitReusableSnapshotForLoadedRoot(
            rootID: logicalRecord.id,
            expectedStandardizedPath: logicalRecord.standardizedFullPath
        )
        await coordinator.setPreparedAdmissionHandlerForTesting(nil)

        XCTAssertEqual(
            admission,
            .failed(.init(stage: .preparedAdmissionCurrentness, cause: .loadedRootOwnerStale))
        )
    }

    func testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let store = WorkspaceFileContextStore()
        let logicalRecord = try await store.loadRoot(path: fixture.root.path)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator.shared
        await coordinator.setPreparedAdmissionHandlerForTesting {
            await store.replayObservedFileSystemDeltas(
                rootID: logicalRecord.id,
                deltas: [.fileModified("Tracked.swift", Date())]
            )
        }
        addTeardownBlock {
            await coordinator.setPreparedAdmissionHandlerForTesting(nil)
            await store.unloadRoot(id: logicalRecord.id)
        }

        let admission = try await store.admitReusableSnapshotForLoadedRoot(
            rootID: logicalRecord.id,
            expectedStandardizedPath: logicalRecord.standardizedFullPath
        )
        await coordinator.setPreparedAdmissionHandlerForTesting(nil)

        XCTAssertEqual(
            admission,
            .failed(.init(stage: .preparedAdmissionCurrentness, cause: .loadedRootCatalogStale))
        )
    }

    func testReceiptFallbackRestartAndConcurrentBindingIsolationMatrix() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        ) else {
            return XCTFail("Expected reusable parent snapshot")
        }
        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        let binding = fixture.binding(for: result.descriptor)
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: binding.worktreeRootPath,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        )

        XCTAssertEqual(
            receipt.fallbackReason(nowUptimeNanoseconds: receipt.expiresAtUptimeNanoseconds &+ 1),
            .expiredReceipt
        )
        let evaluator = WorkspaceRootMaterializationHintEvaluator(gitService: git, authority: authority)
        let missingReceipt = await evaluator.observe(nil, observationEnabled: true)
        let disabledObservation = await evaluator.observe(hint, observationEnabled: false)
        XCTAssertEqual(missingReceipt, .fallback(.noReceipt))
        XCTAssertEqual(disabledObservation, .observationDisabled)

        let restartedAuthority = GitWorkspaceStateAuthority()
        let restartedEvaluator = WorkspaceRootMaterializationHintEvaluator(
            gitService: GitService(workspaceStateAuthority: restartedAuthority),
            authority: restartedAuthority
        )
        let restartFallback = await restartedEvaluator.observe(hint, observationEnabled: true)
        XCTAssertEqual(restartFallback, .fallback(.baseEvicted))

        let otherSessionBinding = AgentSessionWorktreeBinding(
            id: "other-binding",
            repositoryID: "other-repository",
            repoKey: "other-repository-key",
            logicalRootPath: binding.logicalRootPath,
            worktreeID: "other-worktree",
            worktreeRootPath: fixture.sandbox.appendingPathComponent("other-target").path,
            source: "test"
        )
        let isolatedHint = hint.validated(
            matching: otherSessionBinding,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext()
        )
        XCTAssertEqual(isolatedHint.validationFallbackReason, .compatibilityMismatch)
        let isolatedFallback = await evaluator.observe(isolatedHint, observationEnabled: true)
        XCTAssertEqual(isolatedFallback, .fallback(.compatibilityMismatch))

        let incompatibleIdentity = WorkspaceRootReusableSnapshotIdentity(
            sha256: receipt.parentSnapshotIdentity.sha256,
            searchABI: GitWorkspaceSearchABIIdentity(
                matcherSchemaVersion: 999,
                projectedKeySchemaVersion: 1,
                comparatorSchemaVersion: 1,
                pathNormalizationSchemaVersion: 1
            )
        )
        let incompatibleSnapshot = await authority.reusableSnapshot(
            identity: incompatibleIdentity,
            expectedCompatibilityKey: receipt.parentCompatibilityKey
        )
        XCTAssertNil(incompatibleSnapshot)
    }

    func testReceiptDataIsNotPersistedWithBindingSchema() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        ) else {
            return XCTFail("Expected reusable parent snapshot")
        }
        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        let binding = fixture.binding(for: result.descriptor)
        let encoded = try JSONEncoder().encode(binding)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let decoded = try JSONDecoder().decode(AgentSessionWorktreeBinding.self, from: encoded)

        XCTAssertEqual(decoded, binding)
        XCTAssertFalse(json.contains(receipt.id.uuidString))
        XCTAssertFalse(json.contains(receipt.correlationID.uuidString))
        XCTAssertFalse(json.contains(receipt.parentSnapshotIdentity.sha256))
        XCTAssertFalse(json.contains("secret.txt"))
        XCTAssertFalse(json.contains("witnessCoverage"))
        XCTAssertFalse(json.contains("initializationReceipt"))
    }

    func testConcurrentSameRepositoryCreationsKeepReceiptsSessionIsolated() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        ) else {
            return XCTFail("Expected reusable parent snapshot")
        }
        let firstCorrelation = UUID()
        let secondCorrelation = UUID()
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        async let first = try git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext(
                agentSessionID: firstSessionID,
                correlationID: firstCorrelation
            )
        )
        async let second = try git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext(
                agentSessionID: secondSessionID,
                correlationID: secondCorrelation
            )
        )
        let (firstResult, secondResult) = try await (first, second)
        let firstReceipt = try XCTUnwrap(firstResult.initializationReceipt)
        let secondReceipt = try XCTUnwrap(secondResult.initializationReceipt)
        XCTAssertEqual(firstReceipt.correlationID, firstCorrelation)
        XCTAssertEqual(secondReceipt.correlationID, secondCorrelation)
        XCTAssertNotEqual(firstReceipt.id, secondReceipt.id)
        XCTAssertNotEqual(firstReceipt.actualTargetPath, secondReceipt.actualTargetPath)
        XCTAssertEqual(firstReceipt.parentSnapshotIdentity, secondReceipt.parentSnapshotIdentity)

        let firstBinding = fixture.binding(for: firstResult.descriptor)
        let secondBinding = fixture.binding(for: secondResult.descriptor)
        let firstHint = WorkspaceRootMaterializationHint(
            bindingID: firstBinding.id,
            standardizedTargetPath: firstBinding.worktreeRootPath,
            creationReceipt: firstReceipt,
            correlationID: firstCorrelation
        )
        XCTAssertNil(firstHint.validated(
            matching: firstBinding,
            sessionID: firstSessionID,
            startupContext: fixture.startupContext(
                agentSessionID: firstSessionID,
                correlationID: firstCorrelation
            )
        ).validationFallbackReason)
        XCTAssertEqual(
            firstHint.validated(
                matching: secondBinding,
                sessionID: firstSessionID,
                startupContext: fixture.startupContext(
                    agentSessionID: firstSessionID,
                    correlationID: firstCorrelation
                )
            ).validationFallbackReason,
            .compatibilityMismatch
        )
    }

    func testRootNeutralSnapshotExcludesTargetStateAndEvictsWithinBounds() async throws {
        let first = try ReceiptFixture()
        let second = try ReceiptFixture()
        defer {
            first.cleanup()
            second.cleanup()
        }
        let authority = GitWorkspaceStateAuthority(
            reusableSnapshotCacheLimits: WorkspaceRootReusableSnapshotCacheLimits(
                maximumSnapshotCount: 1,
                maximumSnapshotsPerRepository: 1,
                maximumEstimatedBytes: 8 * 1024 * 1024
            )
        )
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case let .admitted(firstIdentity) = await coordinator.observeAuthoritativeFullLoad(
            rootURL: first.root,
            authoritativeRelativeFilePaths: first.authoritativeRelativeFilePaths
        ) else {
            return XCTFail("Expected first reusable snapshot")
        }
        let firstLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: first.root))
        let firstLease: GitWorkspaceAuthorityLease
        switch try await authority.currentLease(
            for: GitWorkspaceAuthorityRepositoryKey(layout: firstLayout),
            prefix: GitRepositoryRelativeRootPrefix("")
        ) {
        case let .success(value): firstLease = value
        case let .failure(reason): return XCTFail("Missing first authority lease: \(reason)")
        }
        let capturedFirstSnapshot = await authority.currentReusableSnapshot(capturedUsing: firstLease)
        let firstSnapshot = try XCTUnwrap(capturedFirstSnapshot)
        XCTAssertTrue(firstSnapshot.searchBase.relativePaths.allSatisfy { !$0.hasPrefix("/") })
        XCTAssertFalse(firstSnapshot.searchBase.relativePaths.contains { $0.contains(first.root.path) })
        XCTAssertFalse(firstSnapshot.inventory.entries.contains { $0.relativePath.contains(first.root.path) })
        XCTAssertTrue(firstSnapshot.hasValidContentAddress())

        let secondAdmission = await coordinator.observeAuthoritativeFullLoad(
            rootURL: second.root,
            authoritativeRelativeFilePaths: second.authoritativeRelativeFilePaths
        )
        XCTAssertEqual(
            secondAdmission,
            .failed(.init(stage: .admissionCommit, cause: .admissionRejected)),
            "bounded cache must not evict active observed coverage"
        )
        let cache = await authority.snapshotForTesting()
        XCTAssertEqual(cache.reusableSnapshotCount, 1)
        XCTAssertLessThanOrEqual(cache.reusableSnapshotEstimatedBytes, 8 * 1024 * 1024)
        let retainedFirstSnapshot = await authority.reusableSnapshot(
            identity: firstIdentity,
            expectedCompatibilityKey: firstSnapshot.compatibilityKey
        )
        XCTAssertNotNil(retainedFirstSnapshot)
    }

    func testRepeatedAuthorityObservationReplacesAliasAndMetadataRetain() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)

        let repeatedObservationCount = 10
        for iteration in 0 ..< repeatedObservationCount {
            guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
                rootURL: fixture.root,
                authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
            ) else {
                return XCTFail("Repeated unchanged observation failed at iteration \(iteration)")
            }
        }

        let cache = await authority.snapshotForTesting()
        let monitor = await authority.metadataMonitorForTesting()
        let coverage = await monitor.snapshotForTesting()
        XCTAssertEqual(cache.reusableSnapshotCount, 1)
        XCTAssertEqual(cache.reusableSnapshotAliasCount, 1)
        XCTAssertEqual(coverage.retainedRepositoryCount, 1)
        XCTAssertEqual(coverage.retainTokenCount, 1)
    }

    func testMetadataCoverageReplacementIsTransactionalExactAndReleasesObsoletePaths() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let externalA = fixture.sandbox.appendingPathComponent("external-a-ignore")
        let externalB = fixture.sandbox.appendingPathComponent("external-b-ignore")
        try "a\n".write(to: externalA, atomically: true, encoding: .utf8)
        try "b\n".write(to: externalB, atomically: true, encoding: .utf8)

        let discovery = try await authority.retainMetadataObservation(
            for: layout,
            additionalAuthorityPaths: [externalA]
        )
        let monitor = await authority.metadataMonitorForTesting()
        let discoveryCoverage = await monitor.snapshotForTesting()
        let replacement = try await authority.retainMetadataObservation(
            for: layout,
            additionalAuthorityPaths: [externalB]
        )
        let replacementCoverage = await monitor.snapshotForTesting()
        XCTAssertEqual(replacementCoverage.sourceCount, discoveryCoverage.sourceCount + 1)

        let repositoryKey = GitWorkspaceAuthorityRepositoryKey(layout: layout)
        var replacementWatermark = monitor.acceptedWatermark(for: repositoryKey)
        var exactReplacementIsCurrent = false
        for _ in 0 ..< 20 {
            replacementWatermark = monitor.acceptedWatermark(for: repositoryKey)
            exactReplacementIsCurrent = await authority.metadataObservationIsCurrent(
                replacement,
                for: layout,
                additionalAuthorityPaths: [externalB],
                expectedAcceptedWatermark: replacementWatermark
            )
            if exactReplacementIsCurrent { break }
            await Task.yield()
        }
        let mismatchedReplacementIsCurrent = await authority.metadataObservationIsCurrent(
            replacement,
            for: layout,
            additionalAuthorityPaths: [externalA],
            expectedAcceptedWatermark: replacementWatermark
        )
        XCTAssertTrue(exactReplacementIsCurrent)
        XCTAssertFalse(mismatchedReplacementIsCurrent)

        await authority.releaseMetadataObservation(discovery)
        let releasedDiscoveryCoverage = await monitor.snapshotForTesting()
        XCTAssertEqual(releasedDiscoveryCoverage.sourceCount, discoveryCoverage.sourceCount)
        XCTAssertEqual(releasedDiscoveryCoverage.retainTokenCount, 1)
        await authority.releaseMetadataObservation(replacement)
        let finalCoverage = await monitor.snapshotForTesting()
        XCTAssertEqual(finalCoverage.retainTokenCount, 0)
    }

    func testCommonRepositoryMutationFencesNewLinkedWorktreeAuthorityCollection() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)
        let created = try await git.createWorktree(request: fixture.createRequest(), at: fixture.root)
        let sourceLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let targetLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(
            atWorkTreeRoot: URL(fileURLWithPath: created.path)
        ))
        let token = await authority.beginMutation(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: sourceLayout),
            kind: .worktreeCreate
        )
        let targetScope = try GitWorkspaceAuthorityScopeKey(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: targetLayout),
            repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix("")
        )
        switch await authority.beginCollection(scopeKey: targetScope) {
        case .success:
            XCTFail("new linked-worktree repository key escaped the common-directory mutation fence")
        case let .failure(reason):
            XCTAssertEqual(reason, .mutationInProgress)
        }
        do {
            _ = try await git.generationFencedAuthoritySnapshot(
                layout: targetLayout,
                prefix: GitRepositoryRelativeRootPrefix("")
            )
            XCTFail("generation-fenced collection unexpectedly crossed an active mutation")
        } catch let reason as GitWorkspaceAuthorityUnavailableReason {
            XCTAssertEqual(reason, .mutationInProgress)
        }
        await authority.finishMutation(token, outcome: .succeeded)
        let captured = try await git.generationFencedAuthoritySnapshot(
            layout: targetLayout,
            prefix: GitRepositoryRelativeRootPrefix("")
        )
        XCTAssertEqual(captured.repositoryKey, targetScope.repositoryKey)
        switch await authority.currentLease(
            for: targetScope.repositoryKey,
            prefix: targetScope.repositoryRelativeRootPrefix
        ) {
        case .success:
            XCTFail("ephemeral target proof remained published after observation retirement")
        case let .failure(reason):
            XCTAssertEqual(reason, .monitorCoverageUnavailable)
        }
    }

    func testCreationWitnessRecordsParentAndGlobalGapFlagsBeforePathFiltering() {
        let destination = "/tmp/receipt-witness-\(UUID().uuidString)"
        let recorder = WorkspaceRootCreationReceiptCoordinator.Recorder(
            destinationPath: destination,
            watchRootPath: "/tmp",
            startEventID: 39
        )
        let gapFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        let dropFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        recorder.accept([
            WorkspaceRootCreationFSEvent(path: "/tmp", flags: gapFlags, eventID: 40),
            WorkspaceRootCreationFSEvent(path: "/", flags: dropFlags, eventID: 41)
        ])
        let snapshot = recorder.snapshot()
        XCTAssertTrue(snapshot.mustScanSubDirs)
        XCTAssertTrue(snapshot.rootChanged)
        XCTAssertTrue(snapshot.eventIDsWrapped)
        XCTAssertTrue(snapshot.userDropped)
        XCTAssertTrue(snapshot.kernelDropped)
        XCTAssertEqual(snapshot.acceptedDestinationEventCount, 0)
        XCTAssertEqual(snapshot.acceptedNonDestinationEventCount, 1)
    }

    func testReceiptReplayFailsAcrossSessionLogicalRootAndOwnerGeneration() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority.shared
        let git = GitService(workspaceStateAuthority: authority)
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
        guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        ) else { return XCTFail("Expected reusable parent snapshot") }
        let result = try await git.createWorktreeWithResult(
            request: fixture.createRequest(),
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        let receipt = try XCTUnwrap(result.initializationReceipt)
        let binding = fixture.binding(for: result.descriptor)
        let hint = WorkspaceRootMaterializationHint(
            bindingID: binding.id,
            standardizedTargetPath: binding.worktreeRootPath,
            creationReceipt: receipt,
            correlationID: fixture.correlationID
        )

        XCTAssertEqual(hint.validated(
            matching: binding,
            sessionID: UUID(),
            startupContext: fixture.startupContext()
        ).validationFallbackReason, .compatibilityMismatch)
        XCTAssertEqual(hint.validated(
            matching: binding,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext(correlationID: UUID())
        ).validationFallbackReason, .compatibilityMismatch)
        let differentLogicalRoot = AgentSessionWorktreeBinding(
            id: binding.id,
            repositoryID: binding.repositoryID,
            repoKey: binding.repoKey,
            logicalRootPath: fixture.sandbox.path,
            logicalRootName: binding.logicalRootName,
            worktreeID: binding.worktreeID,
            worktreeRootPath: binding.worktreeRootPath,
            worktreeName: binding.worktreeName,
            branch: binding.branch,
            head: binding.head,
            visualLabel: binding.visualLabel,
            visualColorHex: binding.visualColorHex,
            boundAt: binding.boundAt,
            source: binding.source
        )
        XCTAssertEqual(hint.validated(
            matching: differentLogicalRoot,
            sessionID: fixture.agentSessionID,
            startupContext: fixture.startupContext()
        ).validationFallbackReason, .compatibilityMismatch)

        let store = WorkspaceFileContextStore()
        let warmup = try await store.prepareSessionWorktreeOwnership(
            ownerID: fixture.agentSessionID,
            bindingFingerprint: "prior-owner-generation",
            physicalRootPaths: []
        )
        _ = try await store.commitSessionWorktreeOwnership(warmup)
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
        let preparation = try await materializer.prepare(
            sessionID: fixture.agentSessionID,
            bindings: [binding],
            startupContext: fixture.startupContext(),
            initializationHintsByBindingID: [binding.id: hint]
        )
        XCTAssertEqual(
            preparation.ownership.materializationHintObservationsByPhysicalRootPath[result.descriptor.path],
            .fallback(.ownerSuperseded)
        )
        let diagnostics = await store.readSearchRootDiagnosticsSnapshot()
        XCTAssertEqual(diagnostics.first { $0.rootPath == result.descriptor.path }?.crawlCount, 1)
        await materializer.abort(preparation)
    }

    func testExternalAndIncludeCopySkippedDestinationsNeverReceiveReusableReceipt() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let git = GitService(workspaceStateAuthority: authority)

        let externalRequest = GitWorktreeCreateRequest(
            path: fixture.sandbox.appendingPathComponent("external-child"),
            branch: "external-\(UUID().uuidString)",
            baseRef: "HEAD",
            allowExternalPath: true,
            appManagedContainer: fixture.worktrees,
            mainWorktreeRoot: fixture.root,
            knownWorktreeRoots: [fixture.root],
            copyWorktreeIncludeFiles: true
        )
        let externalResult = try await git.createWorktreeWithResult(
            request: externalRequest,
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        XCTAssertNil(externalResult.initializationReceipt)
        XCTAssertEqual(externalResult.initializationFallbackReason, .unsupportedDestination)

        let skippedBase = fixture.createRequest()
        let skippedRequest = GitWorktreeCreateRequest(
            path: skippedBase.path,
            branch: skippedBase.branch,
            baseRef: skippedBase.baseRef,
            appManagedContainer: skippedBase.appManagedContainer,
            mainWorktreeRoot: skippedBase.mainWorktreeRoot,
            knownWorktreeRoots: skippedBase.knownWorktreeRoots,
            copyWorktreeIncludeFiles: false
        )
        let skippedResult = try await git.createWorktreeWithResult(
            request: skippedRequest,
            at: fixture.root,
            initializationContext: fixture.initializationContext()
        )
        XCTAssertNil(skippedResult.initializationReceipt)
        XCTAssertEqual(skippedResult.initializationFallbackReason, .includeCopyFailure)
    }

    func testReusableSnapshotCurrentnessFailuresRetainEveryStage() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let cases: [(failureCall: Int, stage: WorkspaceRootReusableSnapshotCoordinator.ObservationFailureStage)] = [
            (1, .initialCurrentness),
            (2, .discoveryObservation),
            (3, .discoveryAuthorityCapture),
            (4, .replacementObservation),
            (5, .collection),
            (7, .capturedAuthority),
            (9, .treeInventory),
            (10, .catalogClassification),
            (11, .catalogClassification),
            (12, .catalogClassification),
            (13, .catalogClassification),
            (14, .catalogClassification),
            (15, .catalogClassification),
            (16, .admissionPreparation),
            (17, .preparedAdmissionCurrentness),
            (19, .committedAdmissionCurrentness)
        ]

        for testCase in cases {
            let authority = GitWorkspaceStateAuthority()
            let coordinator = WorkspaceRootReusableSnapshotCoordinator(
                gitService: GitService(workspaceStateAuthority: authority),
                authority: authority
            )
            let currentness = CurrentnessFailureGate(failureCall: testCase.failureCall)
            let result = await coordinator.observeAuthoritativeFullLoad(
                rootURL: fixture.root,
                authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths,
                currentnessValidator: { await currentness.validation() }
            )

            XCTAssertEqual(
                result,
                .failed(.init(stage: testCase.stage, cause: .staleCurrentness)),
                "currentness call \(testCase.failureCall)"
            )
            let snapshot = await authority.snapshotForTesting()
            XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
        }
    }

    func testReusableSnapshotCurrentnessPreservesLoadedRootCauseMatrix() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let causes: [WorkspaceRootReusableSnapshotCoordinator.ObservationFailureCause] = [
            .loadedRootOwnerStale,
            .loadedRootCatalogStale,
            .loadedRootWatcherStale
        ]

        for cause in causes {
            let authority = GitWorkspaceStateAuthority()
            let coordinator = WorkspaceRootReusableSnapshotCoordinator(
                gitService: GitService(workspaceStateAuthority: authority),
                authority: authority
            )
            let currentness = CurrentnessFailureGate(failureCall: 17, failureCause: cause)
            let result = await coordinator.observeAuthoritativeFullLoad(
                rootURL: fixture.root,
                authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths,
                currentnessValidator: { await currentness.validation() }
            )

            XCTAssertEqual(
                result,
                .failed(.init(stage: .preparedAdmissionCurrentness, cause: cause))
            )
            let snapshot = await authority.snapshotForTesting()
            XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
        }
    }

    func testReusableSnapshotPreparedCurrentnessCancellationIsNotStaleness() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: authority),
            authority: authority
        )
        let currentness = CurrentnessFailureGate(failureCall: 17, cancelOnFailure: true)

        let result = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths,
            currentnessValidator: { await currentness.validation() }
        )

        XCTAssertEqual(
            result,
            .failed(.init(stage: .preparedAdmissionCurrentness, cause: .cancelled))
        )
        let snapshot = await authority.snapshotForTesting()
        XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
    }

    func testReusableSnapshotPreparedAuthorityInvalidationRetainsStageAndReason() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: authority),
            authority: authority
        )
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let tokenBox = MutationTokenBox()
        await coordinator.setPreparedAdmissionHandlerForTesting {
            let token = await authority.beginMutation(
                repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
                kind: .other
            )
            await tokenBox.set(token)
        }
        defer { Task { await coordinator.setPreparedAdmissionHandlerForTesting(nil) } }

        let result = await coordinator.observeAuthoritativeFullLoad(
            rootURL: fixture.root,
            authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
        )
        if let token = await tokenBox.take() {
            await authority.finishMutation(token, outcome: .cancelled)
        }

        XCTAssertEqual(
            result,
            .authorityUnavailable(
                stage: .preparedAdmissionCurrentness,
                reason: .invalidatedDuringCollection
            )
        )
        let snapshot = await authority.snapshotForTesting()
        XCTAssertEqual(snapshot.reusableSnapshotCount, 0)
    }

    func testReusableSnapshotCancellationIsPathFreeAndTyped() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.cleanup() }
        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(workspaceStateAuthority: authority),
            authority: authority
        )
        let task = Task {
            await coordinator.observeAuthoritativeFullLoad(
                rootURL: fixture.root,
                authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
            )
        }
        task.cancel()

        let result = await task.value
        XCTAssertEqual(
            result,
            .failed(.init(stage: .initialCurrentness, cause: .cancelled))
        )
    }

    #if DEBUG
        func testQueuedMutationLockCancellationRecordsOneTerminalDecisionWithoutReceipt() async throws {
            let fixture = try ReceiptFixture()
            defer { fixture.cleanup() }
            let authority = GitWorkspaceStateAuthority()
            let git = GitService(workspaceStateAuthority: authority)
            let gate = ReceiptMutationLockGate()
            let holderCorrelationID = UUID()
            let cancelledCorrelationID = UUID()
            let holderRequest = fixture.createRequest()
            let cancelledRequest = fixture.createRequest()
            await git.setWorktreeMutationLockAcquiredHandlerForTesting { correlationID in
                guard correlationID == holderCorrelationID else { return }
                await gate.enterAndWaitForRelease()
            }
            defer {
                Task {
                    await gate.release()
                    await git.setWorktreeMutationLockAcquiredHandlerForTesting(nil)
                }
            }
            WorktreeStartupInstrumentation.resetForTesting()

            let holder = Task {
                try await git.createWorktreeWithResult(
                    request: holderRequest,
                    at: fixture.root,
                    initializationContext: fixture.initializationContext(correlationID: holderCorrelationID)
                )
            }
            await gate.waitUntilEntered()
            let cancelled = Task {
                try await git.createWorktreeWithResult(
                    request: cancelledRequest,
                    at: fixture.root,
                    initializationContext: fixture.initializationContext(correlationID: cancelledCorrelationID)
                )
            }
            await git.waitForWorktreeMutationWaiterForTesting(at: fixture.root)
            cancelled.cancel()

            do {
                _ = try await cancelled.value
                XCTFail("Queued worktree creation must remain cancelled before mutation.")
            } catch {
                XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
            }

            let records = WorktreeStartupInstrumentation.receiptDecisions(
                correlationID: cancelledCorrelationID
            )
            XCTAssertEqual(records.count, 1)
            let aggregate = try XCTUnwrap(records.first)
            let decision = try XCTUnwrap(aggregate.creation)
            XCTAssertEqual(aggregate.creationAttemptCount, 1)
            XCTAssertEqual(aggregate.terminalStage, .creation)
            XCTAssertFalse(aggregate.ambiguousOrDuplicate)
            XCTAssertEqual(decision.outcome, .cancelled)
            XCTAssertFalse(decision.receiptEmitted)
            XCTAssertNil(decision.receiptFallbackReason)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledRequest.path.path))
            assertReceiptDecisionIsPathFree(aggregate, fixture: fixture)

            await gate.release()
            _ = try await holder.value
            await git.setWorktreeMutationLockAcquiredHandlerForTesting(nil)
        }

        func testReceiptDecisionClassifiesNaturalRecoveryWithoutCompatibleSnapshot() async throws {
            let fixture = try ReceiptFixture()
            defer { fixture.cleanup() }
            let correlationID = UUID()
            let authority = GitWorkspaceStateAuthority()
            let git = GitService(workspaceStateAuthority: authority)
            WorktreeStartupInstrumentation.resetForTesting()

            let result = try await git.createWorktreeWithResult(
                request: fixture.createRequest(),
                at: fixture.root,
                initializationContext: fixture.initializationContext(correlationID: correlationID)
            )

            XCTAssertNil(result.initializationReceipt)
            XCTAssertEqual(result.initializationFallbackReason, .authorityUnstable)
            let records = WorktreeStartupInstrumentation.receiptDecisions(correlationID: correlationID)
            XCTAssertEqual(records.count, 1)
            let aggregate = try XCTUnwrap(records.first)
            let decision = try XCTUnwrap(aggregate.creation)
            XCTAssertEqual(aggregate.creationAttemptCount, 1)
            XCTAssertFalse(aggregate.ambiguousOrDuplicate)
            XCTAssertEqual(decision.currentLeasePresent, false)
            XCTAssertEqual(decision.parentLookupRoute, .failed)
            XCTAssertEqual(decision.parentLookupFailure, .compatibleSnapshotMissing)
            XCTAssertEqual(decision.targetTreeResolution, .notAttempted)
            XCTAssertEqual(decision.outcome, .receiptAbsent)
            assertReceiptDecisionIsPathFree(aggregate, fixture: fixture)
        }

        func testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed() async throws {
            let fixture = try ReceiptFixture()
            defer { fixture.cleanup() }
            let authority = GitWorkspaceStateAuthority()
            let git = GitService(workspaceStateAuthority: authority)
            let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
            guard case .admitted = await coordinator.observeAuthoritativeFullLoad(
                rootURL: fixture.root,
                authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
            ) else { return XCTFail("Expected reusable parent snapshot") }

            struct GateCase {
                let point: GitService.ReceiptCreationFailurePointForTesting
                let expectedReceipt: Bool
                let expectedFallback: WorkspaceRootSeedFallbackReason?
                let expectedReceiptFallback: WorkspaceRootSeedFallbackReason?
            }
            let cases: [GateCase] = [
                .init(
                    point: .targetTreeUnavailable,
                    expectedReceipt: false,
                    expectedFallback: .authorityUnstable,
                    expectedReceiptFallback: nil
                ),
                .init(
                    point: .witnessCoverageInvalid,
                    expectedReceipt: true,
                    expectedFallback: nil,
                    expectedReceiptFallback: .witnessGap
                ),
                .init(
                    point: .includeCopyIncomplete,
                    expectedReceipt: true,
                    expectedFallback: .includeCopyFailure,
                    expectedReceiptFallback: .includeCopyFailure
                ),
                .init(
                    point: .targetLayoutUnavailable,
                    expectedReceipt: false,
                    expectedFallback: .authorityUnstable,
                    expectedReceiptFallback: nil
                ),
                .init(
                    point: .targetAuthorityUnavailable,
                    expectedReceipt: false,
                    expectedFallback: .authorityUnstable,
                    expectedReceiptFallback: nil
                )
            ]

            for testCase in cases {
                WorktreeStartupInstrumentation.resetForTesting()
                let armedCorrelationID = UUID()
                let unrelatedCorrelationID = UUID()
                await git.setReceiptCreationFailureForTesting(
                    correlationID: armedCorrelationID,
                    point: testCase.point
                )

                let unrelated = try await git.createWorktreeWithResult(
                    request: fixture.createRequest(),
                    at: fixture.root,
                    initializationContext: fixture.initializationContext(correlationID: unrelatedCorrelationID)
                )
                XCTAssertNotNil(unrelated.initializationReceipt, "\(testCase.point)")

                let result = try await git.createWorktreeWithResult(
                    request: fixture.createRequest(),
                    at: fixture.root,
                    initializationContext: fixture.initializationContext(correlationID: armedCorrelationID)
                )
                XCTAssertEqual(result.initializationReceipt != nil, testCase.expectedReceipt, "\(testCase.point)")
                XCTAssertEqual(result.initializationFallbackReason, testCase.expectedFallback, "\(testCase.point)")

                let records = WorktreeStartupInstrumentation.receiptDecisions(
                    correlationID: armedCorrelationID
                )
                XCTAssertEqual(records.count, 1, "\(testCase.point)")
                let aggregate = try XCTUnwrap(records.first)
                let decision = try XCTUnwrap(aggregate.creation)
                XCTAssertEqual(aggregate.creationAttemptCount, 1, "\(testCase.point)")
                XCTAssertFalse(aggregate.ambiguousOrDuplicate, "\(testCase.point)")
                XCTAssertEqual(decision.receiptFallbackReason, testCase.expectedReceiptFallback, "\(testCase.point)")
                XCTAssertEqual(
                    decision.outcome,
                    testCase.expectedReceipt ? .receiptEmitted : .receiptAbsent,
                    "\(testCase.point)"
                )
                assertReceiptDecisionIsPathFree(aggregate, fixture: fixture)

                if let receipt = result.initializationReceipt {
                    let binding = fixture.binding(for: result.descriptor)
                    let hint = WorkspaceRootMaterializationHint(
                        bindingID: binding.id,
                        standardizedTargetPath: binding.worktreeRootPath,
                        creationReceipt: receipt,
                        correlationID: armedCorrelationID
                    ).validated(
                        matching: binding,
                        sessionID: fixture.agentSessionID,
                        startupContext: fixture.startupContext(correlationID: armedCorrelationID)
                    )
                    let evaluator = WorkspaceRootMaterializationHintEvaluator(
                        gitService: git,
                        authority: authority
                    )
                    let observation = await evaluator.observe(hint, observationEnabled: true)
                    let expectedReceiptFallback = try XCTUnwrap(testCase.expectedReceiptFallback)
                    XCTAssertEqual(
                        observation,
                        .fallback(expectedReceiptFallback),
                        "\(testCase.point)"
                    )
                }
            }
        }

        func testLinkedBaseReceiptDecisionMatchesAdmittedSnapshotAndRepositoryScope() async throws {
            let fixture = try ReceiptFixture()
            defer { fixture.cleanup() }
            let linkedBase = fixture.sandbox.appendingPathComponent("linked-base", isDirectory: true)
            try fixture.git([
                "worktree", "add", "-b", "linked-base-\(UUID().uuidString)", linkedBase.path, "HEAD"
            ])
            let sourceLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: linkedBase))
            XCTAssertTrue(sourceLayout.isLinkedWorktree)

            let authority = GitWorkspaceStateAuthority()
            let git = GitService(workspaceStateAuthority: authority)
            let coordinator = WorkspaceRootReusableSnapshotCoordinator(gitService: git, authority: authority)
            let admission = await coordinator.observeAuthoritativeFullLoad(
                rootURL: linkedBase,
                authoritativeRelativeFilePaths: fixture.authoritativeRelativeFilePaths
            )
            guard case let .admitted(snapshotIdentity) = admission else {
                return XCTFail("Expected reusable linked-base snapshot, got \(admission)")
            }

            let correlationID = UUID()
            let target = fixture.worktrees.appendingPathComponent("linked-child-\(UUID().uuidString)")
            let request = GitWorktreeCreateRequest(
                path: target,
                branch: "linked-child-\(UUID().uuidString)",
                baseRef: "HEAD",
                appManagedContainer: fixture.worktrees,
                mainWorktreeRoot: fixture.root,
                knownWorktreeRoots: [fixture.root, linkedBase],
                copyWorktreeIncludeFiles: true
            )
            let context = try GitWorktreeInitializationContext(
                agentSessionID: fixture.agentSessionID,
                correlationID: correlationID,
                logicalRootPath: linkedBase.path,
                expectedOwnerBindingGeneration: fixture.expectedOwnerBindingGeneration,
                repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(""),
                observeReceipt: true
            )
            WorktreeStartupInstrumentation.resetForTesting()

            let result = try await git.createWorktreeWithResult(
                request: request,
                at: linkedBase,
                initializationContext: context
            )
            let receipt = try XCTUnwrap(result.initializationReceipt)
            let targetLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(
                atWorkTreeRoot: URL(fileURLWithPath: result.descriptor.path)
            ))
            XCTAssertEqual(receipt.parentSnapshotIdentity, snapshotIdentity)
            XCTAssertEqual(sourceLayout.commonDir.standardizedFileURL.path, targetLayout.commonDir.standardizedFileURL.path)
            XCTAssertNotEqual(sourceLayout.gitDir.standardizedFileURL.path, targetLayout.gitDir.standardizedFileURL.path)

            let records = WorktreeStartupInstrumentation.receiptDecisions(correlationID: correlationID)
            XCTAssertEqual(records.count, 1)
            let aggregate = try XCTUnwrap(records.first)
            let decision = try XCTUnwrap(aggregate.creation)
            XCTAssertEqual(decision.sourceLayoutState, .linkedWorktree)
            XCTAssertEqual(decision.currentSnapshotSHA256, snapshotIdentity.sha256)
            XCTAssertEqual(decision.parentLookupRoute, .currentAlias)
            XCTAssertEqual(decision.parentAuthorityKeyMatch, .match)
            XCTAssertEqual(decision.parentPrefixMatch, .match)
            XCTAssertEqual(decision.commonDirectoryMatch, .match)
            XCTAssertEqual(decision.repositoryIDMatch, .match)
            XCTAssertEqual(decision.repositoryNamespaceMatch, .match)
            XCTAssertEqual(decision.targetPrefixMatch, .match)
            XCTAssertEqual(decision.targetTreeAuthorityMatch, .match)
            XCTAssertEqual(decision.outcome, .receiptEmitted)
            XCTAssertNil(decision.receiptFallbackReason)
            assertReceiptDecisionIsPathFree(aggregate, fixture: fixture)
        }

        private func assertReceiptDecisionIsPathFree(
            _ decision: WorktreeStartupInstrumentation.ReceiptDecision,
            fixture: ReceiptFixture,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let diagnosticText = String(reflecting: decision)
            XCTAssertFalse(diagnosticText.contains(fixture.sandbox.path), file: file, line: line)
            XCTAssertFalse(diagnosticText.contains(fixture.root.path), file: file, line: line)
            XCTAssertFalse(diagnosticText.contains(fixture.worktrees.path), file: file, line: line)
        }
    #endif

    func testNonGitObservationDoesNotInvokeGit() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("NonGitRootSeedIsolation-\(UUID().uuidString)", isDirectory: true)
        let marker = sandbox.appendingPathComponent("git-invoked")
        let executable = sandbox.appendingPathComponent("fake-git")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 99\n".write(to: executable, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(executable.path, 0o755), 0)

        let authority = GitWorkspaceStateAuthority()
        let coordinator = WorkspaceRootReusableSnapshotCoordinator(
            gitService: GitService(gitExecutableURL: executable, workspaceStateAuthority: authority),
            authority: authority
        )
        let observation = await coordinator.observeAuthoritativeFullLoad(
            rootURL: sandbox,
            authoritativeRelativeFilePaths: []
        )
        XCTAssertEqual(observation, .nonGit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

private actor CurrentnessFailureGate {
    private let failureCall: Int
    private let failureCause: WorkspaceRootReusableSnapshotCoordinator.ObservationFailureCause
    private let cancelOnFailure: Bool
    private var callCount = 0

    init(
        failureCall: Int,
        failureCause: WorkspaceRootReusableSnapshotCoordinator.ObservationFailureCause = .staleCurrentness,
        cancelOnFailure: Bool = false
    ) {
        self.failureCall = failureCall
        self.failureCause = failureCause
        self.cancelOnFailure = cancelOnFailure
    }

    func validation() -> WorkspaceRootReusableSnapshotCoordinator.CurrentnessValidation {
        callCount += 1
        guard callCount == failureCall else { return .current }
        if cancelOnFailure {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return .current
        }
        return .stale(failureCause)
    }
}

private actor MutationTokenBox {
    private var token: GitWorkspaceMutationToken?

    func set(_ token: GitWorkspaceMutationToken) {
        self.token = token
    }

    func take() -> GitWorkspaceMutationToken? {
        defer { token = nil }
        return token
    }
}

#if DEBUG
    private actor ReceiptMutationLockGate {
        private var entered = false
        private var released = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWaitForRelease() async {
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            guard !released else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { continuation in
                enteredWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
#endif

private struct ReceiptFixture {
    let sandbox: URL
    let root: URL
    let worktrees: URL
    let correlationID = UUID()
    let agentSessionID = UUID()
    let expectedOwnerBindingGeneration: UInt64 = 1

    var authoritativeRelativeFilePaths: Set<String> {
        [".gitignore", ".worktreeinclude", "Tracked.swift"]
    }

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeCreationReceiptTests-\(UUID().uuidString)", isDirectory: true)
        root = sandbox.appendingPathComponent("repo", isDirectory: true)
        worktrees = sandbox.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        try git(["init"])
        try git(["config", "user.name", "RepoPrompt Test"])
        try git(["config", "user.email", "repoprompt@example.test"])
        try git(["config", "commit.gpgSign", "false"])
        try write("Tracked.swift", "let value = 1\n")
        try write(".gitignore", "secret.txt\nnested/ignored.txt\n")
        try write(".worktreeinclude", "secret.txt\nnested/ignored.txt\n")
        try write("secret.txt", "ephemeral secret\n")
        try write("nested/ignored.txt", "nested ephemeral secret\n")
        try git(["add", "Tracked.swift", ".gitignore", ".worktreeinclude"])
        try git(["commit", "-m", "base"])
    }

    func initializationContext(
        agentSessionID: UUID? = nil,
        correlationID: UUID? = nil,
        expectedOwnerBindingGeneration: UInt64? = nil
    ) -> GitWorktreeInitializationContext {
        GitWorktreeInitializationContext(
            agentSessionID: agentSessionID ?? self.agentSessionID,
            correlationID: correlationID ?? self.correlationID,
            logicalRootPath: root.path,
            expectedOwnerBindingGeneration: expectedOwnerBindingGeneration
                ?? self.expectedOwnerBindingGeneration,
            repositoryRelativeRootPrefix: try! GitRepositoryRelativeRootPrefix(""),
            observeReceipt: true
        )
    }

    func startupContext(
        agentSessionID: UUID? = nil,
        correlationID: UUID? = nil
    ) -> WorktreeStartupContext {
        WorktreeStartupContext(
            agentSessionID: agentSessionID ?? self.agentSessionID,
            correlationID: correlationID ?? self.correlationID,
            flags: WorktreeStartupFeatureFlags(observeDiffSeededWorktreeStartup: true)
        )
    }

    func createRequest(baseRef: String = "HEAD") -> GitWorktreeCreateRequest {
        let target = worktrees.appendingPathComponent("child-\(UUID().uuidString)", isDirectory: true)
        return GitWorktreeCreateRequest(
            path: target,
            branch: "receipt-\(UUID().uuidString)",
            baseRef: baseRef,
            appManagedContainer: worktrees,
            mainWorktreeRoot: root,
            knownWorktreeRoots: [root],
            copyWorktreeIncludeFiles: true
        )
    }

    func binding(for descriptor: GitWorktreeDescriptor) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(UUID().uuidString)",
            repositoryID: descriptor.repository.repositoryID,
            repoKey: descriptor.repository.repoKey,
            logicalRootPath: root.path,
            logicalRootName: root.lastPathComponent,
            worktreeID: descriptor.worktreeID,
            worktreeRootPath: descriptor.path,
            worktreeName: descriptor.name,
            branch: descriptor.branch,
            head: descriptor.head,
            source: "test"
        )
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func git(_ arguments: [String]) throws {
        _ = try gitOutput(arguments)
    }

    func gitOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitWorktreeCreationReceiptTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }
}
