import Foundation
@testable import RepoPromptApp
import XCTest

final class WorkspaceRootBindingProjectionTests: XCTestCase {
    func testSingleBoundRootProjectsRelativeAndLogicalPathsToWorktree() {
        let logicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: "Project",
            fullPath: "/repo/project"
        )
        let physicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: "Project",
            fullPath: "/tmp/worktrees/project-agent"
        )
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)]
        )

        XCTAssertEqual(
            projection.translateInputPath("Sources/App.swift"),
            "/tmp/worktrees/project-agent/Sources/App.swift"
        )
        XCTAssertEqual(
            projection.translateInputPath("/repo/project/Sources/App.swift"),
            "/tmp/worktrees/project-agent/Sources/App.swift"
        )
        XCTAssertEqual(
            projection.translateInputPath("Project/Sources/App.swift"),
            "/tmp/worktrees/project-agent/Sources/App.swift"
        )
        XCTAssertEqual(
            projection.translateInputPath("/tmp/worktrees/project-agent/Sources/App.swift"),
            "/tmp/worktrees/project-agent/Sources/App.swift"
        )
        XCTAssertEqual(
            projection.projectedLogicalDisplayPath(forPhysicalPath: "/tmp/worktrees/project-agent/Sources/App.swift"),
            "Sources/App.swift"
        )
        XCTAssertNil(projection.projectedLogicalDisplayPath(forPhysicalPath: "/repo/project/Sources/App.swift"))
    }

    func testSingleBoundRootDoesNotStealUnboundRootAlias() {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let docsRoot = WorkspaceRootRef(id: UUID(), name: "Docs", fullPath: "/repo/docs")
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/worktrees/project-agent")
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)],
            visibleLogicalRoots: [logicalRoot, docsRoot]
        )

        XCTAssertEqual(projection.translateInputPath("Docs/README.md"), "Docs/README.md")
        XCTAssertEqual(
            projection.translateInputPath("Project/Sources/App.swift"),
            "/tmp/worktrees/project-agent/Sources/App.swift"
        )
        XCTAssertEqual(
            projection.projectedLogicalDisplayPath(forPhysicalPath: "/tmp/worktrees/project-agent/Sources/App.swift"),
            "Project/Sources/App.swift"
        )
    }

    func testExactFileNamespaceUsesStableStoreIdentityForSharedPhysicalWorktree() {
        let firstLogical = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let secondLogical = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project-copy")
        let physicalPath = "/tmp/worktrees/shared"
        let storeRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: physicalPath)
        let firstPhysical = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: physicalPath)
        let secondPhysical = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: physicalPath)
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: firstLogical,
                    physicalRoot: firstPhysical,
                    binding: Self.binding(logicalRoot: firstLogical, physicalRoot: firstPhysical, worktreeID: "wt-a")
                ),
                .init(
                    logicalRoot: secondLogical,
                    physicalRoot: secondPhysical,
                    binding: Self.binding(logicalRoot: secondLogical, physicalRoot: secondPhysical, worktreeID: "wt-b")
                )
            ],
            visibleLogicalRoots: [firstLogical, secondLogical]
        )
        let context = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let namespace = context.exactFileNamespace(storeRoots: [storeRoot])

        XCTAssertEqual(namespace.rootBindings.count, 1)
        XCTAssertEqual(namespace.rootBindings[0].lookupRoot.id, storeRoot.id)
        XCTAssertEqual(Set(namespace.rootBindings[0].clientRoots.map(\.id)), Set([firstLogical.id, secondLogical.id]))
        XCTAssertEqual(namespace.rootBindings[0].preferredClientRoot.id, firstLogical.id)
    }

    func testExactFileNamespaceRetainsUnavailableNestedWorktreeBinding() {
        let canonicalRoot = WorkspaceRootRef(id: UUID(), name: "Repo", fullPath: "/repo")
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let unavailablePhysical = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/missing-worktree")
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRoot,
                    physicalRoot: unavailablePhysical,
                    binding: Self.binding(
                        logicalRoot: logicalRoot,
                        physicalRoot: unavailablePhysical,
                        worktreeID: "wt-missing"
                    )
                )
            ],
            visibleLogicalRoots: [canonicalRoot, logicalRoot]
        )
        let context = WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        let namespace = context.exactFileNamespace(storeRoots: [canonicalRoot])

        XCTAssertEqual(namespace.rootBindings.count, 2)
        let unavailableBinding = namespace.rootBindings.first {
            $0.lookupRoot.standardizedFullPath == unavailablePhysical.standardizedFullPath
        }
        XCTAssertEqual(unavailableBinding?.lookupRole, .projectedPhysical)
        XCTAssertEqual(unavailableBinding?.preferredClientRoot.id, logicalRoot.id)
    }

    func testBoundRootsForMetadataAreDeterministicallySorted() {
        let firstLogical = WorkspaceRootRef(id: UUID(), name: "A", fullPath: "/repo/a")
        let secondLogical = WorkspaceRootRef(id: UUID(), name: "B", fullPath: "/repo/b")
        let firstPhysical = WorkspaceRootRef(id: UUID(), name: "A", fullPath: "/tmp/wt/a")
        let secondPhysical = WorkspaceRootRef(id: UUID(), name: "B", fullPath: "/tmp/wt/b")
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(logicalRoot: secondLogical, physicalRoot: secondPhysical, binding: Self.binding(logicalRoot: secondLogical, physicalRoot: secondPhysical, worktreeID: "wt-b")),
                .init(logicalRoot: firstLogical, physicalRoot: firstPhysical, binding: Self.binding(logicalRoot: firstLogical, physicalRoot: firstPhysical, worktreeID: "wt-a"))
            ]
        )

        XCTAssertEqual(projection.boundRootsForMetadata.map(\.logicalRoot.standardizedFullPath), ["/repo/a", "/repo/b"])
        XCTAssertEqual(projection.boundRootsForMetadata.map(\.binding.worktreeID), ["wt-a", "wt-b"])
    }

    func testWorktreeScopeMetadataUsesBindingWorktreeNameForEffectiveName() throws {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/worktrees/project-agent")
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            worktreeName: "project-agent",
            branch: "feature/demo",
            visualLabel: "Demo Worktree",
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)]
        )

        let scope = try XCTUnwrap(ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: projection))
        let mapping = try XCTUnwrap(scope.rootMappings.first)
        let logicalLabel = try XCTUnwrap(WorkspaceLogicalRootIdentity.labels(
            for: [
                WorkspaceLogicalRootIdentity.RootDescriptor(
                    physicalRootID: physicalRoot.id,
                    rootEpoch: WorkspaceCodemapRootEpoch(
                        rootID: logicalRoot.id,
                        rootLifetimeID: physicalRoot.id
                    ),
                    preferredName: logicalRoot.name
                )
            ]
        )[physicalRoot.id])
        XCTAssertEqual(scope.kind, "session_bound_worktree")
        XCTAssertEqual(mapping.logicalRootName, logicalLabel)
        XCTAssertEqual(mapping.logicalRootPath, logicalLabel)
        XCTAssertEqual(mapping.effectiveRootName, "project-agent")
        XCTAssertEqual(mapping.effectiveRootPath, "session-bound")
        XCTAssertEqual(mapping.worktreeID, "wt-1")
        XCTAssertEqual(mapping.branch, "feature/demo")
        XCTAssertEqual(mapping.label, "Demo Worktree")
    }

    func testWorktreeScopeDeduplicatesSharedPhysicalLabelSourceButPreservesLogicalMappings() throws {
        let sharedPhysicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: "Shared Physical Root",
            fullPath: "/private/worktrees/shared"
        )
        let firstLogicalRoot = WorkspaceRootRef(id: UUID(), name: "Canonical A", fullPath: "/canonical/a")
        let lastLogicalRoot = WorkspaceRootRef(id: UUID(), name: "Canonical Z", fullPath: "/canonical/z")
        let firstBinding = AgentSessionWorktreeBinding(
            id: "binding-a",
            repositoryID: "repo-a",
            repoKey: "repo-key",
            logicalRootPath: firstLogicalRoot.fullPath,
            logicalRootName: firstLogicalRoot.name,
            worktreeID: "worktree-a",
            worktreeRootPath: sharedPhysicalRoot.fullPath,
            worktreeName: "alpha-worktree",
            branch: "feature/a",
            visualLabel: "Alpha Worktree",
            source: "test"
        )
        let lastBinding = AgentSessionWorktreeBinding(
            id: "binding-z",
            repositoryID: "repo-z",
            repoKey: "repo-key",
            logicalRootPath: lastLogicalRoot.fullPath,
            logicalRootName: lastLogicalRoot.name,
            worktreeID: "worktree-z",
            worktreeRootPath: sharedPhysicalRoot.fullPath,
            worktreeName: "zeta-worktree",
            branch: "feature/z",
            visualLabel: "Zeta Worktree",
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(logicalRoot: lastLogicalRoot, physicalRoot: sharedPhysicalRoot, binding: lastBinding),
                .init(logicalRoot: firstLogicalRoot, physicalRoot: sharedPhysicalRoot, binding: firstBinding)
            ]
        )

        let scope = try XCTUnwrap(ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: projection))
        let mappings = scope.rootMappings
        XCTAssertEqual(mappings.count, 2)
        XCTAssertEqual(mappings.map(\.logicalRootName), ["Canonical A", "Canonical A"])
        XCTAssertEqual(mappings.map(\.logicalRootPath), ["Canonical A", "Canonical A"])
        XCTAssertEqual(mappings.map(\.effectiveRootName), ["alpha-worktree", "zeta-worktree"])
        XCTAssertEqual(mappings.map(\.effectiveRootPath), ["session-bound", "session-bound"])
        XCTAssertEqual(mappings.map(\.worktreeID), ["worktree-a", "worktree-z"])
        XCTAssertEqual(mappings.map(\.worktreeName), ["alpha-worktree", "zeta-worktree"])
        XCTAssertEqual(mappings.map(\.branch), ["feature/a", "feature/z"])
        XCTAssertEqual(mappings.map(\.label), ["Alpha Worktree", "Zeta Worktree"])

        let encodedScope = try XCTUnwrap(String(data: JSONEncoder().encode(scope), encoding: .utf8))
        for absolutePath in [
            firstLogicalRoot.standardizedFullPath,
            lastLogicalRoot.standardizedFullPath,
            sharedPhysicalRoot.standardizedFullPath
        ] {
            XCTAssertFalse(encodedScope.contains(absolutePath))
        }

        let identicalSharedPhysicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: "Identical Shared Physical Root",
            fullPath: "/private/worktrees/identical-shared"
        )
        let identicalFirstLogicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: "Shared Logical Root",
            fullPath: "/canonical/identical-a"
        )
        let identicalLastLogicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: "Shared Logical Root",
            fullPath: "/canonical/identical-z"
        )
        let identicalFirstBinding = AgentSessionWorktreeBinding(
            id: "identical-binding-a",
            repositoryID: "shared-repository",
            repoKey: "shared-repo-key",
            logicalRootPath: identicalFirstLogicalRoot.fullPath,
            logicalRootName: identicalFirstLogicalRoot.name,
            worktreeID: "shared-worktree-id",
            worktreeRootPath: identicalSharedPhysicalRoot.fullPath,
            worktreeName: "shared-feature-worktree",
            branch: "feature/shared",
            visualLabel: "Shared Feature",
            source: "test"
        )
        let identicalLastBinding = AgentSessionWorktreeBinding(
            id: "identical-binding-z",
            repositoryID: "shared-repository",
            repoKey: "shared-repo-key",
            logicalRootPath: identicalLastLogicalRoot.fullPath,
            logicalRootName: identicalLastLogicalRoot.name,
            worktreeID: "shared-worktree-id",
            worktreeRootPath: identicalSharedPhysicalRoot.fullPath,
            worktreeName: "shared-feature-worktree",
            branch: "feature/shared",
            visualLabel: "Shared Feature",
            source: "test"
        )
        let identicalProjection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: identicalFirstLogicalRoot,
                    physicalRoot: identicalSharedPhysicalRoot,
                    binding: identicalFirstBinding
                ),
                .init(
                    logicalRoot: identicalLastLogicalRoot,
                    physicalRoot: identicalSharedPhysicalRoot,
                    binding: identicalLastBinding
                )
            ]
        )

        let identicalScope = try XCTUnwrap(
            ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: identicalProjection)
        )
        XCTAssertEqual(identicalScope.rootMappings.count, 2)
        let firstIdenticalMapping = try XCTUnwrap(identicalScope.rootMappings.first)
        let lastIdenticalMapping = try XCTUnwrap(identicalScope.rootMappings.last)
        XCTAssertEqual(firstIdenticalMapping, lastIdenticalMapping)

        let encodedIdenticalScope = try JSONEncoder().encode(identicalScope)
        let decodedIdenticalScope = try JSONDecoder().decode(
            ToolResultDTOs.WorktreeScopeDTO.self,
            from: encodedIdenticalScope
        )
        XCTAssertEqual(decodedIdenticalScope.rootMappings.count, 2)
        XCTAssertEqual(decodedIdenticalScope.rootMappings.first, decodedIdenticalScope.rootMappings.last)
    }

    func testLogicalRootLabelsDeduplicatePhysicalIDsBeforeCollisionAccountingUsingFirstDescriptor() throws {
        let sharedPhysicalID = try XCTUnwrap(UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001"))
        let controlPhysicalID = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001"))
        let logicalRootID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001"))
        let epochA = try WorkspaceCodemapRootEpoch(
            rootID: logicalRootID,
            rootLifetimeID: XCTUnwrap(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001"))
        )
        let epochB = try WorkspaceCodemapRootEpoch(
            rootID: logicalRootID,
            rootLifetimeID: XCTUnwrap(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002"))
        )
        let controlEpoch = try WorkspaceCodemapRootEpoch(
            rootID: XCTUnwrap(UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")),
            rootLifetimeID: XCTUnwrap(UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001"))
        )
        let firstSharedDescriptor = WorkspaceLogicalRootIdentity.RootDescriptor(
            physicalRootID: sharedPhysicalID,
            rootEpoch: epochA,
            preferredName: ""
        )
        let conflictingSharedDescriptor = WorkspaceLogicalRootIdentity.RootDescriptor(
            physicalRootID: sharedPhysicalID,
            rootEpoch: epochB,
            preferredName: "Control"
        )
        let controlDescriptor = WorkspaceLogicalRootIdentity.RootDescriptor(
            physicalRootID: controlPhysicalID,
            rootEpoch: controlEpoch,
            preferredName: "Control"
        )
        let cases: [(
            descriptors: [WorkspaceLogicalRootIdentity.RootDescriptor],
            expectedSharedLabel: String,
            expectedControlLabel: String
        )] = [
            (
                [firstSharedDescriptor, conflictingSharedDescriptor, controlDescriptor],
                WorkspaceLogicalRootIdentity.label(for: epochA),
                "Control"
            ),
            (
                [conflictingSharedDescriptor, firstSharedDescriptor, controlDescriptor],
                WorkspaceLogicalRootIdentity.label(for: epochB),
                WorkspaceLogicalRootIdentity.label(for: controlEpoch)
            )
        ]

        for testCase in cases {
            let labels = WorkspaceLogicalRootIdentity.labels(for: testCase.descriptors)

            XCTAssertEqual(labels.count, 2)
            XCTAssertEqual(labels[sharedPhysicalID], testCase.expectedSharedLabel)
            XCTAssertEqual(labels[controlPhysicalID], testCase.expectedControlLabel)
        }
    }

    func testDuplicateLogicalRootBasenamesProduceStableUniqueNonPhysicalLabels() throws {
        let reusedRootID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001"))
        let firstLifetimeID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001"))
        let secondLifetimeID = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002"))
        let firstEpoch = WorkspaceCodemapRootEpoch(
            rootID: reusedRootID,
            rootLifetimeID: firstLifetimeID
        )
        let secondEpoch = WorkspaceCodemapRootEpoch(
            rootID: reusedRootID,
            rootLifetimeID: secondLifetimeID
        )
        let priorGeneratedLabel = WorkspaceLogicalRootIdentity.label(for: firstEpoch)
        let firstLogical = WorkspaceRootRef(id: UUID(), name: "repo", fullPath: "/canonical/one/repo")
        let secondLogical = WorkspaceRootRef(
            id: UUID(),
            name: priorGeneratedLabel,
            fullPath: "/canonical/two/repo"
        )
        let firstPhysical = WorkspaceRootRef(id: UUID(), name: "secret-one", fullPath: "/private/worktrees/secret-one")
        let secondPhysical = WorkspaceRootRef(
            id: UUID(),
            name: priorGeneratedLabel,
            fullPath: "/private/worktrees/secret-two"
        )
        let repeatedEpochPhysical = WorkspaceRootRef(
            id: UUID(),
            name: "secret-three",
            fullPath: "/private/worktrees/secret-three"
        )
        let descriptors = [
            WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: firstPhysical.id,
                rootEpoch: firstEpoch,
                preferredName: "repo"
            ),
            WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: secondPhysical.id,
                rootEpoch: secondEpoch,
                preferredName: priorGeneratedLabel
            ),
            WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: repeatedEpochPhysical.id,
                rootEpoch: firstEpoch,
                preferredName: "repo"
            )
        ]

        let first = WorkspaceLogicalRootIdentity.labels(for: descriptors)
        let second = WorkspaceLogicalRootIdentity.labels(for: Array(descriptors.reversed()))

        XCTAssertEqual(first, second)
        let firstLabel = "root@aaaaaaaa-0000-0000-0000-000000000001+bbbbbbbb-0000-0000-0000-000000000001"
        let secondLabel = "root@aaaaaaaa-0000-0000-0000-000000000001+bbbbbbbb-0000-0000-0000-000000000002"
        XCTAssertEqual(first[firstPhysical.id], firstLabel)
        XCTAssertEqual(first[repeatedEpochPhysical.id], firstLabel)
        XCTAssertEqual(first[secondPhysical.id], secondLabel)
        XCTAssertNotEqual(firstLabel, secondLabel)
        XCTAssertEqual(priorGeneratedLabel, firstLabel)
        let logicalPaths = try [firstPhysical.id, secondPhysical.id].map { physicalRootID in
            try XCTUnwrap(try WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: XCTUnwrap(first[physicalRootID]),
                standardizedRelativePath: "Sources/App.swift"
            )).displayPath
        }.sorted()
        XCTAssertEqual(
            logicalPaths,
            [
                "\(firstLabel)/Sources/App.swift",
                "\(secondLabel)/Sources/App.swift"
            ]
        )
        XCTAssertFalse(first.values.contains { $0.contains("/canonical/") || $0.contains("/private/") })

        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: secondLogical,
                    physicalRoot: secondPhysical,
                    binding: Self.binding(
                        logicalRoot: secondLogical,
                        physicalRoot: secondPhysical,
                        worktreeID: "two"
                    )
                ),
                .init(
                    logicalRoot: firstLogical,
                    physicalRoot: firstPhysical,
                    binding: Self.binding(
                        logicalRoot: firstLogical,
                        physicalRoot: firstPhysical,
                        worktreeID: "one"
                    )
                )
            ]
        )
        let scope = try XCTUnwrap(ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: projection))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(scope), encoding: .utf8))
        XCTAssertEqual(Set(scope.rootMappings.map(\.logicalRootName)).count, 2)
        XCTAssertFalse(encoded.contains(firstPhysical.standardizedFullPath))
        XCTAssertFalse(encoded.contains(secondPhysical.standardizedFullPath))
        XCTAssertFalse(encoded.contains(firstLogical.standardizedFullPath))
        XCTAssertFalse(encoded.contains(secondLogical.standardizedFullPath))
    }

    func testFileTreeSnapshotIsDisplayedAsLogicalRoot() {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/worktrees/project-agent")
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)]
        )
        let rootID = UUID()
        let childID = UUID()
        let snapshot = FileTreeSelectionSnapshot(
            roots: [
                FileTreeFolderSnapshot(
                    id: rootID,
                    name: "project-agent",
                    fullPath: "/tmp/worktrees/project-agent",
                    standardizedFullPath: "/tmp/worktrees/project-agent",
                    standardizedRootPath: "/tmp/worktrees/project-agent",
                    children: [
                        .folder(FileTreeFolderSnapshot(
                            id: childID,
                            name: "Sources",
                            fullPath: "/tmp/worktrees/project-agent/Sources",
                            standardizedFullPath: "/tmp/worktrees/project-agent/Sources",
                            standardizedRootPath: "/tmp/worktrees/project-agent",
                            children: []
                        ))
                    ]
                )
            ],
            selectedFileIDs: [],
            mode: "full",
            showFullPaths: false,
            onlyIncludeRootsWithSelectedFiles: false,
            includeLegend: false
        )

        let logicalized = projection.logicalizeFileTreeSnapshot(snapshot)

        XCTAssertEqual(logicalized.roots.first?.name, "Project")
        XCTAssertEqual(logicalized.roots.first?.standardizedFullPath, "/repo/project")
        XCTAssertEqual(logicalized.roots.first?.standardizedRootPath, "/repo/project")
        guard case let .folder(child)? = logicalized.roots.first?.children.first else {
            return XCTFail("Expected logicalized child folder")
        }
        XCTAssertEqual(child.standardizedFullPath, "/repo/project/Sources")
        XCTAssertEqual(child.standardizedRootPath, "/repo/project")
    }

    func testSelectionCanPhysicalizeForLookupThenLogicalizeForPersistence() {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/repo/project")
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "Project", fullPath: "/tmp/worktrees/project-agent")
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [
                .init(
                    logicalRoot: logicalRoot,
                    physicalRoot: physicalRoot,
                    binding: Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "wt-1")
                )
            ]
        )
        let logicalSelection = StoredSelection(
            selectedPaths: ["Sources/App.swift"],
            manualCodemapPaths: ["Sources/Manual.swift"],
            slices: ["Sources/Sliced.swift": [LineRange(start: 3, end: 9)]],
            codemapAutoEnabled: false
        )

        let physicalSelection = projection.physicalizeSelection(logicalSelection)
        XCTAssertEqual(physicalSelection.selectedPaths, ["/tmp/worktrees/project-agent/Sources/App.swift"])
        XCTAssertEqual(
            physicalSelection.manualCodemapPaths,
            ["/tmp/worktrees/project-agent/Sources/Manual.swift"]
        )
        XCTAssertEqual(
            physicalSelection.slices["/tmp/worktrees/project-agent/Sources/Sliced.swift"],
            [LineRange(start: 3, end: 9)]
        )

        let persistedSelection = projection.logicalizeSelection(physicalSelection)
        XCTAssertEqual(persistedSelection.selectedPaths, ["/repo/project/Sources/App.swift"])
        XCTAssertEqual(
            persistedSelection.manualCodemapPaths,
            ["/repo/project/Sources/Manual.swift"]
        )
        XCTAssertEqual(
            persistedSelection.slices["/repo/project/Sources/Sliced.swift"],
            [LineRange(start: 3, end: 9)]
        )

        let mixedAliasSelection = StoredSelection(
            selectedPaths: [
                "/repo/project/Sources/Sliced.swift",
                "/tmp/worktrees/project-agent/Sources/Sliced.swift"
            ],
            slices: [
                "/repo/project/Sources/Sliced.swift": [LineRange(start: 1, end: 20)],
                "/tmp/worktrees/project-agent/Sources/Sliced.swift": [LineRange(start: 5, end: 25)]
            ]
        )
        XCTAssertEqual(
            projection.logicalizeSelection(mixedAliasSelection).slices["/repo/project/Sources/Sliced.swift"],
            [LineRange(start: 1, end: 25)]
        )
        XCTAssertEqual(
            projection.physicalizeSelection(mixedAliasSelection).slices["/tmp/worktrees/project-agent/Sources/Sliced.swift"],
            [LineRange(start: 1, end: 25)]
        )
    }

    func testMaterializerFailsClosedWhenPhysicalRootCannotBeLoaded() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "ProjectionLogical")
        try write("let origin = \"base\"\n", to: logicalRootURL.appendingPathComponent("Sources/App.swift"))

        let store = WorkspaceFileContextStore()
        let loadedLogicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRoot = WorkspaceRootRef(
            id: loadedLogicalRoot.id,
            name: loadedLogicalRoot.name,
            fullPath: loadedLogicalRoot.standardizedFullPath
        )
        // Reusing the already-loaded logical root as the bound physical root forces
        // `.sessionWorktree` materialization to fail with a different root configuration.
        let unloadablePhysicalRoot = logicalRootURL
        let physicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: logicalRoot.name,
            fullPath: unloadablePhysicalRoot.path
        )
        let binding = Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "missing")

        let sessionID = UUID()
        let materializedProjection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: [binding]
        )
        let visibleLookup = await store.lookupPath("Sources/App.swift", profile: .uiAssisted, rootScope: .visibleWorkspace)
        let ownership = await store.sessionWorktreeOwnershipDebugSnapshotForTesting()

        let failClosedProjection = try XCTUnwrap(materializedProjection)
        let scopedLookup = await store.lookupPath(
            "Sources/App.swift",
            profile: .uiAssisted,
            rootScope: failClosedProjection.lookupRootScope
        )
        let scopeAvailability = await store.rootScopeAvailability(failClosedProjection.lookupRootScope)
        let catalogAccess = await store.searchCatalogAccess(rootScope: failClosedProjection.lookupRootScope)
        XCTAssertEqual(failClosedProjection.physicalRootPaths, Set([unloadablePhysicalRoot.standardizedFileURL.path]))
        XCTAssertFalse(failClosedProjection.isFullyMaterialized)
        XCTAssertEqual(
            failClosedProjection.lookupRootScope,
            .validatedSessionBoundWorkspace(canonicalRoots: [], physicalRoots: [])
        )
        XCTAssertEqual(scopeAvailability, .sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
        XCTAssertEqual(
            catalogAccess,
            .unavailable(.sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
        )
        XCTAssertNotNil(visibleLookup)
        XCTAssertNil(scopedLookup)
        XCTAssertEqual(ownership.installedOwnerCount, 0)
        XCTAssertEqual(ownership.provisionalOwnerCount, 0)
        XCTAssertEqual(ownership.rootClaimCount, 0)
    }

    func testMaterializerCommitsOwnershipWithoutCodemapDemandOrBuild() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "ProjectionCommitLogical")
        let physicalRootURL = try makeTemporaryRoot(name: "ProjectionCommitPhysical")
        try write(SwiftFixtureSource.emptyStruct("CommitOnlyType"), to: physicalRootURL.appendingPathComponent("Sources/App.swift"))
        let store = WorkspaceFileContextStore()
        let loadedLogicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRoot = WorkspaceRootRef(
            id: loadedLogicalRoot.id,
            name: loadedLogicalRoot.name,
            fullPath: loadedLogicalRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: physicalRootURL.path)
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
        let sessionID = UUID()
        let preparation = try await materializer.prepare(
            sessionID: sessionID,
            bindings: [Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "commit")]
        )

        let projection = try await materializer.commit(preparation)
        let counts = await store.codemapPresentationOperationCountsForTesting()

        XCTAssertNotNil(projection)
        XCTAssertEqual(counts.artifactDemandRequests, 0)
        XCTAssertEqual(counts.presentationFreezeRequests, 0)
        await materializer.release(sessionID: sessionID)
        await store.unloadRoot(id: loadedLogicalRoot.id)
    }

    func testMaterializationStartsZeroCodemapTasks() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "ProjectionMaterializeLogical")
        let physicalRootURL = try makeTemporaryRoot(name: "ProjectionMaterializePhysical")
        try write(SwiftFixtureSource.emptyStruct("MaterializedWithoutCodemapType"), to: physicalRootURL.appendingPathComponent("Sources/App.swift"))
        let store = WorkspaceFileContextStore()
        let loadedLogicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRoot = WorkspaceRootRef(
            id: loadedLogicalRoot.id,
            name: loadedLogicalRoot.name,
            fullPath: loadedLogicalRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: physicalRootURL.path)
        let sessionID = UUID()
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)

        let projection = await materializer.materialize(
            sessionID: sessionID,
            bindings: [Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "materialize")]
        )
        await Task.yield()
        let counts = await store.codemapPresentationOperationCountsForTesting()

        XCTAssertNotNil(projection)
        XCTAssertEqual(counts.artifactDemandRequests, 0)
        XCTAssertEqual(counts.presentationFreezeRequests, 0)
        await materializer.release(sessionID: sessionID)
        await store.unloadRoot(id: loadedLogicalRoot.id)
    }

    func testTwoBindingsSharingWorktreeEmitOneDeterministicPhysicalRoot() async throws {
        let firstLogicalURL = try makeTemporaryRoot(name: "ProjectionSharedWorktreeFirst")
        let secondLogicalURL = try makeTemporaryRoot(name: "ProjectionSharedWorktreeSecond")
        let physicalRootURL = try makeTemporaryRoot(name: "ProjectionSharedWorktreePhysical")
        let fixtureContent = "let origin = \"worktree\"\n"
        try write(fixtureContent, to: physicalRootURL.appendingPathComponent("Sources/App.swift"))

        let store = WorkspaceFileContextStore()
        let firstRecord = try await store.loadRoot(path: firstLogicalURL.path)
        let secondRecord = try await store.loadRoot(path: secondLogicalURL.path)
        let firstLogicalRoot = WorkspaceRootRef(
            id: firstRecord.id,
            name: "First Logical Name",
            fullPath: firstRecord.standardizedFullPath
        )
        let secondLogicalRoot = WorkspaceRootRef(
            id: secondRecord.id,
            name: "Second Logical Name",
            fullPath: secondRecord.standardizedFullPath
        )
        let sharedPhysicalRoot = WorkspaceRootRef(
            id: UUID(),
            name: "Ignored Input Name",
            fullPath: physicalRootURL.path
        )
        let sessionID = UUID()
        let materializer = WorkspaceRootBindingProjectionMaterializer(store: store)
        addTeardownBlock {
            await materializer.release(sessionID: sessionID)
            await store.unloadRoot(id: firstRecord.id)
            await store.unloadRoot(id: secondRecord.id)
        }

        let materializedProjection = await materializer.materialize(
            sessionID: sessionID,
            bindings: [
                Self.binding(
                    logicalRoot: secondLogicalRoot,
                    physicalRoot: sharedPhysicalRoot,
                    worktreeID: "shared-second"
                ),
                Self.binding(
                    logicalRoot: firstLogicalRoot,
                    physicalRoot: sharedPhysicalRoot,
                    worktreeID: "shared-first"
                )
            ]
        )
        let projection = try XCTUnwrap(materializedProjection)
        let physicalRoot = try XCTUnwrap(projection.physicalRootRefs.first)
        let lookupContext = WorkspaceLookupContext(
            rootScope: projection.lookupRootScope,
            bindingProjection: projection
        )
        let logicalInputPath = firstLogicalURL.appendingPathComponent("Sources/App.swift").path
        let translatedInputPath = lookupContext.translateInputPath(logicalInputPath)
        let lookupResult = await store.lookupPath(
            translatedInputPath,
            profile: .mcpRead,
            rootScope: lookupContext.rootScope
        )
        let readRecord = try XCTUnwrap(lookupResult?.file)
        let optionalReadContent = try await store.readContent(
            rootID: readRecord.rootID,
            relativePath: readRecord.standardizedRelativePath
        )
        let readContent = try XCTUnwrap(optionalReadContent)
        let logicalRootDisplayNames = await lookupContext.logicalRootDisplayNamesByRootID(store: store)
        let sharedLogicalRootLabel = try XCTUnwrap(logicalRootDisplayNames[physicalRoot.id])
        let projectedDisplayPath = try XCTUnwrap(
            projection.projectedLogicalDisplayPath(forPhysicalPath: readRecord.standardizedFullPath)
        )
        let baseReply = ToolResultDTOs.ReadFileReply(
            content: readContent,
            totalLines: 1,
            firstLine: 1,
            lastLine: 1,
            displayPath: readRecord.standardizedFullPath
        )
        let worktreeScope = try XCTUnwrap(ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: projection))
        let projectedReply = try await MCPReadFileToolProjection.projectReply(
            baseReply,
            displayPath: projectedDisplayPath,
            worktreeScope: worktreeScope
        )
        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        let scopedRoots = await store.rootRefs(scope: projection.lookupRootScope)

        XCTAssertTrue(projection.isFullyMaterialized)
        XCTAssertEqual(projection.logicalRootRefs.count, 2)
        XCTAssertEqual(projection.physicalRootRefs, [physicalRoot])
        XCTAssertEqual(projection.boundRootsForMetadata.count, 2)
        XCTAssertEqual(projection.boundRootsForMetadata.map(\.physicalRoot), [physicalRoot, physicalRoot])
        XCTAssertEqual(physicalRoot.name, physicalRootURL.lastPathComponent)
        XCTAssertEqual(availability, .available)
        XCTAssertEqual(scopedRoots.map(\.id), [physicalRoot.id])

        XCTAssertTrue(logicalInputPath.hasPrefix(firstLogicalRoot.standardizedFullPath + "/"))
        XCTAssertEqual(
            translatedInputPath,
            physicalRootURL.appendingPathComponent("Sources/App.swift").standardizedFileURL.path
        )
        XCTAssertEqual(readRecord.rootID, physicalRoot.id)
        XCTAssertEqual(readRecord.standardizedRelativePath, "Sources/App.swift")
        XCTAssertEqual(readContent, fixtureContent)

        let preferredLogicalRootName = try XCTUnwrap(projection.boundRootsForMetadata.first?.logicalRoot.name)
        XCTAssertEqual(projection.boundRootsForMetadata.first?.logicalRoot.id, firstRecord.id)
        XCTAssertFalse(preferredLogicalRootName.isEmpty)
        XCTAssertEqual(sharedLogicalRootLabel, preferredLogicalRootName)
        XCTAssertEqual(worktreeScope.rootMappings.count, 2)
        XCTAssertEqual(worktreeScope.rootMappings.map(\.worktreeID), ["shared-first", "shared-second"])
        XCTAssertEqual(
            worktreeScope.rootMappings.map(\.logicalRootName),
            [sharedLogicalRootLabel, sharedLogicalRootLabel]
        )
        XCTAssertEqual(Set(worktreeScope.rootMappings.map(\.logicalRootName)), [sharedLogicalRootLabel])
        XCTAssertEqual(projectedReply.content, fixtureContent)
        XCTAssertEqual(projectedReply.totalLines, 1)
        XCTAssertEqual(projectedReply.firstLine, 1)
        XCTAssertEqual(projectedReply.lastLine, 1)
        XCTAssertEqual(projectedReply.displayPath, projectedDisplayPath)
        XCTAssertTrue(projectedDisplayPath.hasSuffix("Sources/App.swift"))
        XCTAssertEqual(projectedReply.worktreeScope, worktreeScope)

        let encodedReply = try XCTUnwrap(String(data: JSONEncoder().encode(projectedReply), encoding: .utf8))
        for absoluteRootPath in [
            firstLogicalRoot.standardizedFullPath,
            secondLogicalRoot.standardizedFullPath,
            physicalRoot.standardizedFullPath
        ] {
            XCTAssertFalse(encodedReply.contains(absoluteRootPath))
        }
    }

    func testMaterializedSessionWorktreeScopeReportsAvailable() async throws {
        let logicalRootURL = try makeTemporaryRoot(name: "ProjectionAvailableLogical")
        let physicalRootURL = try makeTemporaryRoot(name: "ProjectionAvailablePhysical")
        try write("let origin = \"worktree\"\n", to: physicalRootURL.appendingPathComponent("Sources/App.swift"))
        let store = WorkspaceFileContextStore()
        let loadedLogicalRoot = try await store.loadRoot(path: logicalRootURL.path)
        let logicalRoot = WorkspaceRootRef(
            id: loadedLogicalRoot.id,
            name: loadedLogicalRoot.name,
            fullPath: loadedLogicalRoot.standardizedFullPath
        )
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: logicalRoot.name, fullPath: physicalRootURL.path)
        let materializedProjection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: UUID(),
            bindings: [Self.binding(logicalRoot: logicalRoot, physicalRoot: physicalRoot, worktreeID: "available")]
        )
        let projection = try XCTUnwrap(materializedProjection)

        let availability = await store.rootScopeAvailability(projection.lookupRootScope)
        let scopedRoots = await store.rootRefs(scope: projection.lookupRootScope)
        XCTAssertEqual(availability, .available)
        XCTAssertTrue(scopedRoots.contains {
            $0.standardizedFullPath == physicalRootURL.standardizedFileURL.path
        })
    }

    private static func binding(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef,
        worktreeID: String
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding-\(worktreeID)",
            repositoryID: "repo-\(worktreeID)",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: worktreeID,
            worktreeRootPath: physicalRoot.fullPath,
            worktreeName: physicalRoot.fullPath.split(separator: "/").last.map(String.init),
            source: "test"
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
