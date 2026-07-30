import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class MCPContextBuilderGitReviewPolicyTests: XCTestCase {
    func testAdmissionPreservesGenericRoutingAndFencesDiscoverTargets() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "MCPContextBuilderGitPolicyAdmission")
        defer { fixture.cleanup() }
        let classic = try fixture.makeRepository(
            named: "classic",
            files: ["Sources/Classic.swift": "let classic = true\n"]
        )
        let ce = try fixture.makeRepository(
            named: "ce",
            files: ["Sources/Selected.swift": "let selected = true\n"]
        )
        let classicFile = classic.appendingPathComponent("Sources/Classic.swift").path
        let ceFile = ce.appendingPathComponent("Sources/Selected.swift").path
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: classic.path, kind: .primaryWorkspace)
        _ = try await store.loadRoot(path: ce.path, kind: .primaryWorkspace)
        let repositories = [GitRepoDescriptor(rootURL: classic), GitRepoDescriptor(rootURL: ce)]
        let policy = MCPContextBuilderGitReviewPolicy()

        let generic = try await policy.admit(
            resolution: nil,
            hasExplicitSelector: false,
            requestsArtifactPublication: false,
            operation: .diff,
            allRepositories: repositories,
            store: store
        )
        XCTAssertNil(generic.target)
        XCTAssertNil(generic.implicitRepositories)
        XCTAssertNil(generic.preferredDefaultRepository)
        XCTAssertNil(generic.publicationFence)
        XCTAssertEqual(repositories.first?.rootPath, classic.standardizedFileURL.path)

        let ceResolution = try await resolveTarget(
            selectedPaths: [ceFile],
            roots: [classic, ce],
            workspaceDirectory: fixture.sandbox,
            store: store
        )
        let implicit = try await policy.admit(
            resolution: ceResolution,
            hasExplicitSelector: false,
            requestsArtifactPublication: true,
            operation: .diff,
            allRepositories: repositories,
            store: store
        )
        XCTAssertEqual(implicit.implicitRepositories?.map(\.rootPath), [ce.standardizedFileURL.path])
        XCTAssertEqual(implicit.preferredDefaultRepository?.rootPath, ce.standardizedFileURL.path)
        let fence = try XCTUnwrap(implicit.publicationFence)
        XCTAssertNoThrow(try policy.validatePublicationRepositories([repositories[1]], fence: fence))
        XCTAssertThrowsError(try policy.validatePublicationRepositories([repositories[0]], fence: fence)) { error in
            XCTAssertEqual(
                error as? MCPContextBuilderGitReviewPolicyError,
                .publicationOutsideFrozenTarget
            )
        }

        let explicitInspection = try await policy.admit(
            resolution: ceResolution,
            hasExplicitSelector: true,
            requestsArtifactPublication: false,
            operation: .show,
            allRepositories: repositories,
            store: store
        )
        XCTAssertNil(explicitInspection.implicitRepositories)
        XCTAssertNil(explicitInspection.publicationFence)

        let unavailable: ContextBuilderReviewTargetResolution = .unavailable(.emptySelection)
        let unavailableInspection = try await policy.admit(
            resolution: unavailable,
            hasExplicitSelector: true,
            requestsArtifactPublication: false,
            operation: .log,
            allRepositories: repositories,
            store: store
        )
        XCTAssertNil(unavailableInspection.target)
        await assertPolicyError(.targetUnavailable(.emptySelection)) {
            _ = try await policy.admit(
                resolution: unavailable,
                hasExplicitSelector: false,
                requestsArtifactPublication: false,
                operation: .diff,
                allRepositories: repositories,
                store: store
            )
        }
        await assertPolicyError(.targetUnavailable(.emptySelection)) {
            _ = try await policy.admit(
                resolution: unavailable,
                hasExplicitSelector: true,
                requestsArtifactPublication: true,
                operation: .diff,
                allRepositories: repositories,
                store: store
            )
        }

        let deferred = try await resolveDeferred(
            roots: [classic, ce],
            workspaceDirectory: fixture.sandbox,
            store: store
        )
        let deferredInspection = try await policy.admit(
            resolution: deferred,
            hasExplicitSelector: true,
            requestsArtifactPublication: false,
            operation: .show,
            allRepositories: repositories,
            store: store
        )
        XCTAssertNil(deferredInspection.target)
        XCTAssertNil(deferredInspection.publicationFence)
        await assertPolicyError(.targetDeferred) {
            _ = try await policy.admit(
                resolution: deferred,
                hasExplicitSelector: false,
                requestsArtifactPublication: false,
                operation: .diff,
                allRepositories: repositories,
                store: store
            )
        }
        await assertPolicyError(.targetDeferred) {
            _ = try await policy.admit(
                resolution: deferred,
                hasExplicitSelector: true,
                requestsArtifactPublication: true,
                operation: .diff,
                allRepositories: repositories,
                store: store
            )
        }

        let multiResolution = try await resolveTarget(
            selectedPaths: [ceFile, classicFile],
            roots: [classic, ce],
            workspaceDirectory: fixture.sandbox,
            store: store
        )
        for operation in [MCPContextBuilderGitReviewOperation.status, .diff] {
            let admission = try await policy.admit(
                resolution: multiResolution,
                hasExplicitSelector: false,
                requestsArtifactPublication: false,
                operation: operation,
                allRepositories: repositories,
                store: store
            )
            XCTAssertEqual(Set(admission.implicitRepositories?.map(\.rootPath) ?? []), Set(repositories.map(\.rootPath)))
        }
        for operation in [MCPContextBuilderGitReviewOperation.log, .show, .blame] {
            await assertPolicyError(.implicitMultiRepositoryOperation) {
                _ = try await policy.admit(
                    resolution: multiResolution,
                    hasExplicitSelector: false,
                    requestsArtifactPublication: false,
                    operation: operation,
                    allRepositories: repositories,
                    store: store
                )
            }
        }

        let ceTarget = try XCTUnwrap(ceResolution.availableTarget)
        await store.unloadRoot(id: ceTarget.primaryCheckout.physicalWorkspaceRoot.id)
        await assertPolicyError(.targetUnavailable(.staleWorkspaceRoot)) {
            _ = try await policy.admit(
                resolution: ceResolution,
                hasExplicitSelector: true,
                requestsArtifactPublication: false,
                operation: .show,
                allRepositories: repositories,
                store: store
            )
        }
    }

    func testPublishedOutcomesRequireCompleteExactFrozenCheckoutMatches() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "MCPContextBuilderGitPolicyPublication")
        defer { fixture.cleanup() }
        let classic = try fixture.makeRepository(named: "classic")
        let ce = try fixture.makeRepository(
            named: "ce",
            files: ["Sources/Selected.swift": "let selected = true\n"]
        )
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: classic.path, kind: .primaryWorkspace)
        _ = try await store.loadRoot(path: ce.path, kind: .primaryWorkspace)
        let classicRepo = GitRepoDescriptor(rootURL: classic)
        let ceRepo = GitRepoDescriptor(rootURL: ce)
        let resolution = try await resolveTarget(
            selectedPaths: [ce.appendingPathComponent("Sources/Selected.swift").path],
            roots: [classic, ce],
            workspaceDirectory: fixture.sandbox,
            store: store
        )
        let policy = MCPContextBuilderGitReviewPolicy()
        let admission = try await policy.admit(
            resolution: resolution,
            hasExplicitSelector: true,
            requestsArtifactPublication: true,
            operation: .diff,
            allRepositories: [classicRepo, ceRepo],
            store: store
        )
        let fence = try XCTUnwrap(admission.publicationFence)
        let manifest = makeManifest(repo: ceRepo)
        let valid = MCPContextBuilderGitPublishedOutcome(
            repository: ceRepo,
            manifest: manifest,
            hasPublishedArtifacts: true
        )
        try await policy.validatePublishedOutcomes(
            [valid],
            publishedArtifactSetCount: 1,
            fence: fence,
            store: store
        )

        await assertPolicyError(.incompletePublishedMetadata) {
            try await policy.validatePublishedOutcomes(
                [MCPContextBuilderGitPublishedOutcome(
                    repository: ceRepo,
                    manifest: nil,
                    hasPublishedArtifacts: true
                )],
                publishedArtifactSetCount: 1,
                fence: fence,
                store: store
            )
        }
        await assertPolicyError(.incompletePublishedMetadata) {
            try await policy.validatePublishedOutcomes(
                [MCPContextBuilderGitPublishedOutcome(
                    repository: ceRepo,
                    manifest: manifest,
                    hasPublishedArtifacts: false
                )],
                publishedArtifactSetCount: 0,
                fence: fence,
                store: store
            )
        }
        await assertPolicyError(.publishedRepositoryMismatch) {
            try await policy.validatePublishedOutcomes(
                [MCPContextBuilderGitPublishedOutcome(
                    repository: classicRepo,
                    manifest: manifest,
                    hasPublishedArtifacts: true
                )],
                publishedArtifactSetCount: 1,
                fence: fence,
                store: store
            )
        }
        await assertPolicyError(.publishedCheckoutMismatch) {
            try await policy.validatePublishedOutcomes(
                [MCPContextBuilderGitPublishedOutcome(
                    repository: ceRepo,
                    manifest: makeManifest(repo: ceRepo, isWorktree: true),
                    hasPublishedArtifacts: true
                )],
                publishedArtifactSetCount: 1,
                fence: fence,
                store: store
            )
        }
        await assertPolicyError(.publishedOutcomeMismatch) {
            try await policy.validatePublishedOutcomes(
                [valid],
                publishedArtifactSetCount: 2,
                fence: fence,
                store: store
            )
        }
        await assertPolicyError(.publishedCheckoutMismatch) {
            try await policy.validatePublishedOutcomes(
                [valid, valid],
                publishedArtifactSetCount: 2,
                fence: fence,
                store: store
            )
        }

        let target = try XCTUnwrap(resolution.availableTarget)
        await store.unloadRoot(id: target.primaryCheckout.physicalWorkspaceRoot.id)
        await assertPolicyError(.targetUnavailable(.staleWorkspaceRoot)) {
            try await policy.validatePublishedOutcomes(
                [valid],
                publishedArtifactSetCount: 1,
                fence: fence,
                store: store
            )
        }
    }

    private func resolveTarget(
        selectedPaths: [String],
        roots: [URL],
        workspaceDirectory: URL,
        store: WorkspaceFileContextStore
    ) async throws -> ContextBuilderReviewTargetResolution {
        let workspaceID = UUID()
        let tabID = UUID()
        let rootPaths = roots.map(\.path)
        let lookupContext = WorkspaceLookupContext(
            rootScope: .sessionBoundWorkspace(
                canonicalRootPaths: Set(rootPaths),
                physicalRootPaths: []
            ),
            bindingProjection: nil
        )
        let reviewContext = await FrozenPromptGitReviewContext.make(
            workspaceID: workspaceID,
            workspaceDirectoryPath: workspaceDirectory.path,
            workspaceRootPaths: rootPaths,
            tabID: tabID,
            sessionID: nil,
            bindings: [],
            base: "HEAD",
            store: store
        )
        let resolution = try await ContextBuilderReviewTargetResolver().resolve(
            input: ContextBuilderReviewTargetInput(
                workspaceID: workspaceID,
                tabID: tabID,
                selectionRevision: 1,
                selection: StoredSelection(
                    selectedPaths: selectedPaths,
                    codemapAutoEnabled: false
                ),
                lookupContext: lookupContext,
                reviewGitContext: reviewContext
            ),
            store: store
        )
        _ = try XCTUnwrap(resolution.availableTarget)
        return resolution
    }

    private func resolveDeferred(
        roots: [URL],
        workspaceDirectory: URL,
        store: WorkspaceFileContextStore
    ) async throws -> ContextBuilderReviewTargetResolution {
        let workspaceID = UUID()
        let tabID = UUID()
        let rootPaths = roots.map(\.path)
        let lookupContext = WorkspaceLookupContext(
            rootScope: .sessionBoundWorkspace(
                canonicalRootPaths: Set(rootPaths),
                physicalRootPaths: []
            ),
            bindingProjection: nil
        )
        let reviewContext = await FrozenPromptGitReviewContext.make(
            workspaceID: workspaceID,
            workspaceDirectoryPath: workspaceDirectory.path,
            workspaceRootPaths: rootPaths,
            tabID: tabID,
            sessionID: nil,
            bindings: [],
            base: "HEAD",
            store: store
        )
        let resolution = try await ContextBuilderReviewTargetResolver().resolve(
            input: ContextBuilderReviewTargetInput(
                workspaceID: workspaceID,
                tabID: tabID,
                selectionRevision: 1,
                selection: StoredSelection(codemapAutoEnabled: false),
                lookupContext: lookupContext,
                reviewGitContext: reviewContext
            ),
            store: store
        )
        guard case .deferred = resolution else {
            XCTFail("Expected empty review selection to defer")
            return .unavailable(.emptySelection)
        }
        return resolution
    }

    private func makeManifest(
        repo: GitRepoDescriptor,
        isWorktree: Bool = false
    ) -> GitDiffSnapshotManifest {
        GitDiffSnapshotManifest(
            snapshotID: "2026-06-20/1600",
            generatedAt: Date(timeIntervalSince1970: 1),
            mode: .standard,
            compare: "HEAD",
            compareInput: nil,
            scope: .all,
            requestedPaths: nil,
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
            repoKey: repo.repoKey,
            repoRoot: repo.rootPath,
            isWorktree: isWorktree
        )
    }

    private func assertPolicyError(
        _ expected: MCPContextBuilderGitReviewPolicyError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected policy error: \(expected)")
        } catch {
            XCTAssertEqual(error as? MCPContextBuilderGitReviewPolicyError, expected)
        }
    }
}
