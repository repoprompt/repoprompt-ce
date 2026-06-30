import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceCodemapSelectionGraphModelTests: XCTestCase {
    func testContributionIsPathFreeCanonicalAndDeterministicFromV1ArtifactFields() throws {
        let key = try makeArtifactKey(seed: 1)
        let nfc = "Caf\u{00E9}"
        let nfd = "Cafe\u{0301}"
        let definitions = ["\u{4E2D}", "\u{03A9}", "\u{00E9}", "\u{00C5}", "a", "A", nfd, nfc]
        let references = ["ZuluRef", "AlphaRef", "ZuluRef"]

        let permutations = [
            definitions,
            Array(definitions.reversed()),
            [nfc, "A", "\u{03A9}", "\u{00C5}", "\u{4E2D}", "a", nfd, "\u{00E9}"]
        ]
        let referencePermutations = [
            references,
            Array(references.reversed()),
            ["AlphaRef", "ZuluRef", "AlphaRef"]
        ]
        let contributions = zip(permutations, referencePermutations).map { definitions, references in
            CodeMapSelectionGraphContribution(
                artifactKey: key,
                artifact: makeArtifact(
                    definitions: definitions,
                    references: references,
                    imports: ["Ignored/Path/Input"]
                )
            )
        }

        XCTAssertTrue(contributions.dropFirst().allSatisfy { $0 == contributions[0] })
        XCTAssertEqual(contributions[0].schemaVersion, 1)
        XCTAssertEqual(contributions[0].policyVersion, 1)
        XCTAssertEqual(
            contributions[0].sortedUniqueDefinitions,
            ["A", nfc, "a", "\u{00C5}", "\u{00E9}", "\u{03A9}", "\u{4E2D}"]
        )
        XCTAssertEqual(contributions[0].sortedUniqueReferences, ["AlphaRef", "ZuluRef"])
        XCTAssertEqual(contributions[0].contributionDigest.bytes.count, 32)
        XCTAssertTrue(contributions[0].sortedUniqueDefinitions.contains("A"))
        XCTAssertTrue(contributions[0].sortedUniqueDefinitions.contains("a"))

        let ignoredArtifactField = CodeMapSelectionGraphContribution(
            artifactKey: key,
            artifact: makeArtifact(
                definitions: definitions,
                references: references,
                imports: ["Completely/Different/NonGraph/Input"]
            )
        )
        XCTAssertEqual(contributions[0], ignoredArtifactField)

        let swappedDomains = CodeMapSelectionGraphContribution(
            artifactKey: key,
            definitions: references,
            references: definitions
        )
        XCTAssertNotEqual(contributions[0].contributionDigest, swappedDomains.contributionDigest)

        let firstFraming = CodeMapSelectionGraphContribution(
            artifactKey: key,
            definitions: ["ab", "c"],
            references: []
        )
        let secondFraming = CodeMapSelectionGraphContribution(
            artifactKey: key,
            definitions: ["a", "bc"],
            references: []
        )
        XCTAssertNotEqual(firstFraming.contributionDigest, secondFraming.contributionDigest)

        let changedDefinitions = CodeMapSelectionGraphContribution(
            artifactKey: key,
            artifact: makeArtifact(definitions: ["Other"], references: references)
        )
        let changedKey = try CodeMapSelectionGraphContribution(
            artifactKey: makeArtifactKey(seed: 2),
            artifact: makeArtifact(definitions: definitions, references: references)
        )
        XCTAssertNotEqual(contributions[0].contributionDigest, changedDefinitions.contributionDigest)
        XCTAssertNotEqual(contributions[0].contributionDigest, changedKey.contributionDigest)
    }

    func testAuthoritySeededStorePrivatelyIssuesDistinctCurrentNodeIdentities() async throws {
        let rootID = uuid("10000000-0000-0000-0000-000000000001")
        let lifetimeID = uuid("10000000-0000-0000-0000-000000000002")
        let authority = try await makeAuthority(
            name: #function,
            files: ["Sources/Target.swift": "struct Target {}"],
            rootID: rootID,
            rootLifetimeID: lifetimeID
        )
        defer { authority.repositoryFixture.cleanup() }

        let fileID = uuid("10000000-0000-0000-0000-000000000003")
        let firstArtifact = makeArtifact(definitions: ["Target"], references: ["Dependency"])
        let binding = try await makeResolvedBinding(
            authority: authority,
            path: "Sources/Target.swift",
            fileID: fileID,
            artifactOutcome: .ready(firstArtifact)
        )
        let firstStore = try makeStore(binding: binding)
        let first = try acceptedNode(from: firstStore.accept(binding))
        let accountingAfterFirst = firstStore.accounting

        guard case let .exactDuplicate(repeated, repeatedAccounting) = firstStore.accept(binding) else {
            return XCTFail("Repeated current binding must not issue another endpoint.")
        }
        XCTAssertEqual(repeated, first)
        XCTAssertEqual(repeatedAccounting, accountingAfterFirst)
        XCTAssertEqual(firstStore.accounting, accountingAfterFirst)

        let independentStore = try makeStore(binding: binding)
        let independent = try acceptedNode(from: independentStore.accept(binding))
        XCTAssertEqual(first.artifactKey, independent.artifactKey)
        XCTAssertEqual(first.contributionDigest, independent.contributionDigest)
        XCTAssertNotEqual(first.identity, independent.identity)
        XCTAssertEqual(
            firstStore.makeEdge(source: first.identity, target: independent.identity),
            .rejected(.targetStoreMismatch)
        )

        let replacementBinding = try await makeResolvedBinding(
            authority: authority,
            path: "Sources/Target.swift",
            fileID: fileID,
            requestGeneration: 8,
            artifactOutcome: .ready(makeArtifact(definitions: ["TargetV2"], references: ["Dependency"]))
        )
        let replacement = try acceptedNode(from: firstStore.accept(replacementBinding))
        XCTAssertNotEqual(first.identity, replacement.identity)
        XCTAssertEqual(replacement.identity.requestGeneration, 8)
        XCTAssertEqual(replacement.identity.contributionGeneration, firstStore.key.contributionGeneration)
        XCTAssertLessThan(first.identity.bindingGeneration, replacement.identity.bindingGeneration)
        XCTAssertLessThan(first.identity, replacement.identity)
        XCTAssertEqual(
            firstStore.makeEdge(source: first.identity, target: replacement.identity),
            .rejected(.sourceNotCurrent)
        )

        let accountingAfterReplacement = firstStore.accounting
        XCTAssertEqual(
            firstStore.accept(binding),
            .rejected(.staleRequestGeneration(received: 7, current: 8))
        )
        let conflictingGenerationEight = try await makeResolvedBinding(
            authority: authority,
            path: "Sources/Target.swift",
            fileID: fileID,
            requestGeneration: 8,
            artifactOutcome: .ready(makeArtifact(definitions: ["ConflictingV2"], references: []))
        )
        XCTAssertEqual(
            firstStore.accept(conflictingGenerationEight),
            .rejected(.requestGenerationConflict(8))
        )
        XCTAssertEqual(firstStore.accounting, accountingAfterReplacement)
        XCTAssertNotNil(firstStore.makeQuery(selectedSources: [replacement.identity]))
    }

    func testEdgeStoreRejectsEveryForeignGraphKeyComponentAndConsumesBudget() async throws {
        let baseRoot = uuid("30000000-0000-0000-0000-000000000001")
        let baseLifetime = uuid("30000000-0000-0000-0000-000000000002")
        let files = ["Target.swift": "struct Target {}"]
        let baseAuthority = try await makeAuthority(
            name: "\(#function)-base",
            files: files,
            rootID: baseRoot,
            rootLifetimeID: baseLifetime
        )
        let otherRootAuthority = try await makeAuthority(
            name: "\(#function)-root",
            files: files,
            rootID: uuid("30000000-0000-0000-0000-000000000010"),
            rootLifetimeID: baseLifetime
        )
        let otherLifetimeAuthority = try await makeAuthority(
            name: "\(#function)-lifetime",
            files: files,
            rootID: baseRoot,
            rootLifetimeID: uuid("30000000-0000-0000-0000-000000000020")
        )
        let otherRepositoryAuthority = try await makeAuthority(
            name: "\(#function)-authority",
            files: files,
            rootID: baseRoot,
            rootLifetimeID: baseLifetime
        )
        defer {
            baseAuthority.repositoryFixture.cleanup()
            otherRootAuthority.repositoryFixture.cleanup()
            otherLifetimeAuthority.repositoryFixture.cleanup()
            otherRepositoryAuthority.repositoryFixture.cleanup()
        }

        let artifact = makeArtifact(definitions: ["Target"], references: ["Target"])
        let baseBinding = try await makeResolvedBinding(
            authority: baseAuthority,
            path: "Target.swift",
            fileID: uuid("30000000-0000-0000-0000-000000000003"),
            artifactOutcome: .ready(artifact)
        )
        let baseStore = try makeStore(binding: baseBinding)
        let baseNode = try acceptedNode(from: baseStore.accept(baseBinding))

        let sameKeyStore = try makeStore(binding: baseBinding)
        let sameKeyNode = try acceptedNode(from: sameKeyStore.accept(baseBinding))
        XCTAssertEqual(
            sameKeyStore.makeEdge(source: baseNode.identity, target: sameKeyNode.identity),
            .rejected(.sourceStoreMismatch)
        )
        XCTAssertEqual(
            baseStore.makeEdge(source: baseNode.identity, target: sameKeyNode.identity),
            .rejected(.targetStoreMismatch)
        )

        let rootBinding = try await makeResolvedBinding(
            authority: otherRootAuthority,
            path: "Target.swift",
            fileID: UUID(),
            artifactOutcome: .ready(artifact)
        )
        let lifetimeBinding = try await makeResolvedBinding(
            authority: otherLifetimeAuthority,
            path: "Target.swift",
            fileID: UUID(),
            artifactOutcome: .ready(artifact)
        )
        let authorityBinding = try await makeResolvedBinding(
            authority: otherRepositoryAuthority,
            path: "Target.swift",
            fileID: UUID(),
            artifactOutcome: .ready(artifact)
        )
        let catalogBinding = try await makeResolvedBinding(
            authority: baseAuthority,
            path: "Target.swift",
            fileID: UUID(),
            catalogGeneration: 12,
            artifactOutcome: .ready(artifact)
        )

        let projectableVariants = try [
            (makeStore(binding: rootBinding), rootBinding),
            (makeStore(binding: lifetimeBinding), lifetimeBinding),
            (makeStore(binding: authorityBinding), authorityBinding),
            (makeStore(binding: catalogBinding), catalogBinding),
            (makeStore(binding: baseBinding, contributionGeneration: 14), baseBinding)
        ]
        let schemaVariant = try makeStore(binding: baseBinding, schemaVersion: 2)
        let policyVariant = try makeStore(binding: baseBinding, policyVersion: 2)
        let keyVariants = projectableVariants.map(\.0) + [schemaVariant, policyVariant]
        for variant in keyVariants {
            XCTAssertEqual(
                variant.makeEdge(source: baseNode.identity, target: baseNode.identity),
                .rejected(.sourceGraphMismatch)
            )
            XCTAssertEqual(
                WorkspaceCodemapSelectionGraphEdgeValidator.graphMismatch(
                    expected: baseStore.key,
                    actual: variant.key,
                    side: .target
                ),
                .targetGraphMismatch
            )
        }
        for (variant, binding) in projectableVariants {
            let foreignTarget = try acceptedNode(from: variant.accept(binding))
            XCTAssertEqual(
                baseStore.makeEdge(source: baseNode.identity, target: foreignTarget.identity),
                .rejected(.targetGraphMismatch)
            )
        }

        guard case let .edge(edge, accounting) = baseStore.makeEdge(
            source: baseNode.identity,
            target: baseNode.identity
        ) else { return XCTFail("Expected current same-store endpoints to produce an edge.") }
        XCTAssertEqual(edge.source.rootEpoch, edge.target.rootEpoch)
        XCTAssertEqual(accounting.edges, 1)
    }

    func testDuplicateDefinitionsProduceDeterministicAllCandidateSetOrFailClosedOverflow() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: [
                "Z.swift": "struct Z {}",
                "A2.swift": "struct A2 {}",
                "A1.swift": "struct A1 {}"
            ],
            rootID: uuid("50000000-0000-0000-0000-000000000001"),
            rootLifetimeID: uuid("50000000-0000-0000-0000-000000000002")
        )
        defer { authority.repositoryFixture.cleanup() }

        let artifact = makeArtifact(definitions: ["Target"], references: [])
        let bindings = try await [
            makeResolvedBinding(
                authority: authority,
                path: "Z.swift",
                fileID: uuid("50000000-0000-0000-0000-000000000030"),
                artifactOutcome: .ready(artifact)
            ),
            makeResolvedBinding(
                authority: authority,
                path: "A2.swift",
                fileID: uuid("50000000-0000-0000-0000-000000000020"),
                artifactOutcome: .ready(artifact)
            ),
            makeResolvedBinding(
                authority: authority,
                path: "A1.swift",
                fileID: uuid("50000000-0000-0000-0000-000000000010"),
                artifactOutcome: .ready(artifact)
            )
        ]
        let store = try makeStore(binding: bindings[0])
        let nodes = try bindings.map { try acceptedNode(from: store.accept($0)) }
        let expected = [nodes[2].identity, nodes[1].identity, nodes[0].identity]

        for input in [
            [nodes[0], nodes[1], nodes[2]],
            [nodes[2], nodes[0], nodes[1]],
            [nodes[1], nodes[2], nodes[0]]
        ] {
            guard case let .candidates(candidates) = store.definitionCandidates(
                named: "Target",
                among: input
            ) else { return XCTFail("Expected all current candidates.") }
            XCTAssertEqual(candidates.orderedCandidates, expected)
        }

        let sharedFileID = uuid("50000000-0000-0000-0000-000000000020")
        let orderKeys = [
            WorkspaceCodemapSelectionGraphDuplicateOrderKey(
                standardizedRelativePath: "Z.swift",
                fileID: uuid("50000000-0000-0000-0000-000000000001"),
                bindingGeneration: .init(rawValue: 0),
                ordinal: 0
            ),
            WorkspaceCodemapSelectionGraphDuplicateOrderKey(
                standardizedRelativePath: "A.swift",
                fileID: sharedFileID,
                bindingGeneration: .init(rawValue: 2),
                ordinal: 2
            ),
            WorkspaceCodemapSelectionGraphDuplicateOrderKey(
                standardizedRelativePath: "A.swift",
                fileID: uuid("50000000-0000-0000-0000-000000000010"),
                bindingGeneration: .init(rawValue: 9),
                ordinal: 9
            ),
            WorkspaceCodemapSelectionGraphDuplicateOrderKey(
                standardizedRelativePath: "A.swift",
                fileID: sharedFileID,
                bindingGeneration: .init(rawValue: 0),
                ordinal: 9
            ),
            WorkspaceCodemapSelectionGraphDuplicateOrderKey(
                standardizedRelativePath: "A.swift",
                fileID: sharedFileID,
                bindingGeneration: .init(rawValue: 2),
                ordinal: 0
            ),
            WorkspaceCodemapSelectionGraphDuplicateOrderKey(
                standardizedRelativePath: "A.swift",
                fileID: sharedFileID,
                bindingGeneration: .init(rawValue: 1),
                ordinal: 9
            ),
            WorkspaceCodemapSelectionGraphDuplicateOrderKey(
                standardizedRelativePath: "A.swift",
                fileID: sharedFileID,
                bindingGeneration: .init(rawValue: 2),
                ordinal: 1
            )
        ]
        let expectedOrderKeys = [
            orderKeys[2],
            orderKeys[3],
            orderKeys[5],
            orderKeys[4],
            orderKeys[6],
            orderKeys[1],
            orderKeys[0]
        ]
        for permutation in [
            orderKeys,
            Array(orderKeys.reversed()),
            [orderKeys[5], orderKeys[0], orderKeys[3], orderKeys[1], orderKeys[6], orderKeys[2], orderKeys[4]]
        ] {
            XCTAssertEqual(permutation.sorted(), expectedOrderKeys)
        }

        let overflowStore = try makeStore(
            binding: bindings[0],
            sizePolicy: policy(maxDefinitionCandidates: 2)
        )
        let overflowNodes = try bindings.map { try acceptedNode(from: overflowStore.accept($0)) }
        XCTAssertEqual(
            overflowStore.definitionCandidates(named: "Target", among: overflowNodes),
            .candidateOverflow(actual: 3, limit: 2)
        )
        guard case let .candidates(deduplicated) = store.definitionCandidates(
            named: "Target",
            among: nodes + [nodes[0]]
        ) else { return XCTFail("Expected exact duplicate inputs to deduplicate.") }
        XCTAssertEqual(deduplicated.orderedCandidates, expected)
    }

    func testContributionAcceptanceRequiresResolvedCurrentSlice1AAuthority() async throws {
        let rootID = uuid("60000000-0000-0000-0000-000000000001")
        let lifetimeID = uuid("60000000-0000-0000-0000-000000000002")
        let files = ["Target.swift": "struct Target {}"]
        let baseAuthority = try await makeAuthority(
            name: "\(#function)-base",
            files: files,
            rootID: rootID,
            rootLifetimeID: lifetimeID
        )
        let rootAuthority = try await makeAuthority(
            name: "\(#function)-root",
            files: files,
            rootID: UUID(),
            rootLifetimeID: lifetimeID
        )
        let lifetimeAuthority = try await makeAuthority(
            name: "\(#function)-lifetime",
            files: files,
            rootID: rootID,
            rootLifetimeID: UUID()
        )
        let repositoryAuthority = try await makeAuthority(
            name: "\(#function)-authority",
            files: files,
            rootID: rootID,
            rootLifetimeID: lifetimeID
        )
        defer {
            baseAuthority.repositoryFixture.cleanup()
            rootAuthority.repositoryFixture.cleanup()
            lifetimeAuthority.repositoryFixture.cleanup()
            repositoryAuthority.repositoryFixture.cleanup()
        }

        let artifact = makeArtifact(definitions: ["Target"], references: ["Dependency"])
        let baseBinding = try await makeResolvedBinding(
            authority: baseAuthority,
            path: "Target.swift",
            fileID: UUID(),
            artifactOutcome: .ready(artifact)
        )
        let store = try makeStore(binding: baseBinding)
        let mismatches: [(WorkspaceCodemapArtifactBinding, WorkspaceCodemapSelectionGraphContributionRejection)] = try await [
            (
                makeResolvedBinding(
                    authority: rootAuthority,
                    path: "Target.swift",
                    fileID: UUID(),
                    artifactOutcome: .ready(artifact)
                ),
                .rootIDMismatch
            ),
            (
                makeResolvedBinding(
                    authority: lifetimeAuthority,
                    path: "Target.swift",
                    fileID: UUID(),
                    artifactOutcome: .ready(artifact)
                ),
                .rootLifetimeIDMismatch
            ),
            (
                makeResolvedBinding(
                    authority: baseAuthority,
                    path: "Target.swift",
                    fileID: UUID(),
                    catalogGeneration: 12,
                    artifactOutcome: .ready(artifact)
                ),
                .catalogGenerationMismatch
            ),
            (
                makeResolvedBinding(
                    authority: repositoryAuthority,
                    path: "Target.swift",
                    fileID: UUID(),
                    artifactOutcome: .ready(artifact)
                ),
                .repositoryAuthorityMismatch
            )
        ]
        for (binding, expected) in mismatches {
            XCTAssertEqual(store.accept(binding), .rejected(expected))
        }

        let schemaStore = try makeStore(binding: baseBinding, schemaVersion: 2)
        XCTAssertEqual(schemaStore.accept(baseBinding), .rejected(.schemaVersionMismatch))
        let policyStore = try makeStore(binding: baseBinding, policyVersion: 2)
        XCTAssertEqual(policyStore.accept(baseBinding), .rejected(.policyVersionMismatch))

        let unsupported = WorkspaceCodemapArtifactBinding(
            identity: baseBinding.identity,
            unsupportedFileExtension: "txt"
        )
        XCTAssertEqual(store.accept(unsupported), .rejected(.bindingNotResolved))

        let unavailableBinding = try await makeResolvedBinding(
            authority: baseAuthority,
            path: "Target.swift",
            fileID: UUID(),
            artifactOutcome: .oversize(.lines(actual: 2, limit: 1))
        )
        XCTAssertEqual(store.accept(unavailableBinding), .rejected(.artifactUnavailable))
        XCTAssertEqual(store.accounting.nodes, 0)
    }

    func testValidatedQueryResultsFailClosedOnCoverageAuthorityAndStaleness() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: [
                "Source.swift": "struct Source {}",
                "Target.swift": "struct Target {}"
            ],
            rootID: uuid("70000000-0000-0000-0000-000000000001"),
            rootLifetimeID: uuid("70000000-0000-0000-0000-000000000002")
        )
        defer { authority.repositoryFixture.cleanup() }

        let sourceFileID = uuid("70000000-0000-0000-0000-000000000003")
        let targetFileID = uuid("70000000-0000-0000-0000-000000000004")
        let sourceBinding = try await makeResolvedBinding(
            authority: authority,
            path: "Source.swift",
            fileID: sourceFileID,
            artifactOutcome: .ready(makeArtifact(definitions: ["Source"], references: ["Target"]))
        )
        let targetBinding = try await makeResolvedBinding(
            authority: authority,
            path: "Target.swift",
            fileID: targetFileID,
            artifactOutcome: .ready(makeArtifact(definitions: ["Target"], references: []))
        )
        let store = try makeStore(binding: sourceBinding)
        let source = try acceptedNode(from: store.accept(sourceBinding))
        let target = try acceptedNode(from: store.accept(targetBinding))
        let query = try XCTUnwrap(store.makeQuery(selectedSources: [source.identity]))
        let covered = try XCTUnwrap(store.makeSourceCoverage(
            for: query,
            source: source.identity,
            state: .covered
        ))
        let missing = try XCTUnwrap(store.makeSourceCoverage(
            for: query,
            source: source.identity,
            state: .missing
        ))
        let resolution = try XCTUnwrap(store.makeResolvedTarget(
            for: query,
            source: source.identity,
            target: target.identity
        ))
        XCTAssertNil(store.makeResolvedTarget(
            for: query,
            source: source.identity,
            target: source.identity
        ))
        let peerQuery = try XCTUnwrap(store.makeQuery(
            selectedSources: [source.identity, target.identity]
        ))
        let peerSourceCoverage = try XCTUnwrap(store.makeSourceCoverage(
            for: peerQuery,
            source: source.identity,
            state: .covered
        ))
        let peerTargetCoverage = try XCTUnwrap(store.makeSourceCoverage(
            for: peerQuery,
            source: target.identity,
            state: .covered
        ))
        XCTAssertNil(store.makeResolvedTarget(
            for: peerQuery,
            source: source.identity,
            target: target.identity
        ))
        XCTAssertNil(store.immediateResult(
            for: peerQuery,
            resolvedTargets: [resolution],
            sourceCoverage: [peerSourceCoverage, peerTargetCoverage],
            definitionUniverseCoverage: .incomplete(
                progress: .notStarted,
                remainingCount: nil,
                retry: nil
            )
        ))

        let unresolved = try XCTUnwrap(store.makeReferenceFailure(
            for: query,
            source: source.identity,
            referencedName: "Target",
            failure: .unresolvedDefinitionUniverse
        ))

        let matchingComplete = try completeCoverage(for: store)
        let staleComplete = try completeCoverage(
            for: store,
            catalogGeneration: store.key.catalogGeneration + 1
        )
        let foreignAuthorityComplete = try completeCoverage(
            for: store,
            repositoryAuthority: repositoryAuthority(
                like: store.key.repositoryAuthority,
                authorityGeneration: store.key.repositoryAuthority.authorityGeneration + 1
            )
        )
        let provenMissing = try XCTUnwrap(store.makeReferenceFailure(
            for: query,
            source: source.identity,
            referencedName: "Absent",
            failure: .provenMissingDefinition,
            definitionUniverseCoverage: matchingComplete
        ))
        for invalidCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage in [
            .incomplete(progress: .notStarted, remainingCount: nil, retry: nil),
            .busy(progress: .notStarted, retryAfterMilliseconds: 10),
            .budget(dimension: .stagedGraphBytes, attempted: 2, limit: 1),
            .unavailable(.notBuilt),
            staleComplete,
            foreignAuthorityComplete
        ] {
            XCTAssertNil(store.makeReferenceFailure(
                for: query,
                source: source.identity,
                referencedName: "Absent",
                failure: .provenMissingDefinition,
                definitionUniverseCoverage: invalidCoverage
            ))
            XCTAssertNil(store.immediateResult(
                for: query,
                sourceCoverage: [covered],
                definitionUniverseCoverage: invalidCoverage,
                referenceFailures: [provenMissing]
            ))
        }
        XCTAssertNotNil(store.immediateResult(
            for: query,
            sourceCoverage: [covered],
            definitionUniverseCoverage: matchingComplete,
            referenceFailures: [provenMissing]
        ))

        XCTAssertNil(store.immediateResult(
            for: query,
            resolvedTargets: [resolution],
            sourceCoverage: [covered],
            definitionUniverseCoverage: .incomplete(
                progress: .notStarted,
                remainingCount: 1,
                retry: nil
            )
        ))

        let unavailable = try XCTUnwrap(store.immediateResult(
            for: query,
            sourceCoverage: [missing],
            definitionUniverseCoverage: .unavailable(.notBuilt),
            referenceFailures: [unresolved]
        ))
        XCTAssertTrue(unavailable.targets.isEmpty)
        XCTAssertEqual(unavailable.sourceCoverage, [missing])
        XCTAssertEqual(unavailable.referenceFailures, [unresolved])

        XCTAssertNil(store.immediateResult(
            for: query,
            resolvedTargets: [resolution],
            sourceCoverage: [covered],
            definitionUniverseCoverage: .unavailable(.notBuilt)
        ))
        XCTAssertNil(store.immediateResult(
            for: query,
            resolvedTargets: [resolution],
            sourceCoverage: [missing],
            definitionUniverseCoverage: .incomplete(
                progress: .notStarted,
                remainingCount: nil,
                retry: nil
            )
        ))
        XCTAssertNil(store.immediateResult(
            for: query,
            sourceCoverage: [],
            definitionUniverseCoverage: .busy(
                progress: .notStarted,
                retryAfterMilliseconds: nil
            )
        ))
        XCTAssertNil(store.immediateResult(
            for: query,
            sourceCoverage: [covered, covered],
            definitionUniverseCoverage: .unavailable(.notBuilt)
        ))
        XCTAssertNil(store.immediateResult(
            for: query,
            resolvedTargets: [resolution, resolution],
            sourceCoverage: [covered],
            definitionUniverseCoverage: matchingComplete
        ))

        let complete = try XCTUnwrap(store.immediateResult(
            for: query,
            resolvedTargets: [resolution],
            sourceCoverage: [covered],
            definitionUniverseCoverage: matchingComplete
        ))
        XCTAssertEqual(complete.targets, [target.identity])
        XCTAssertNil(store.immediateResult(
            for: query,
            sourceCoverage: [covered],
            definitionUniverseCoverage: staleComplete
        ))
        XCTAssertNil(store.immediateResult(
            for: query,
            sourceCoverage: [covered],
            definitionUniverseCoverage: foreignAuthorityComplete
        ))

        let foreignAuthority = try await makeAuthority(
            name: "\(#function)-foreign",
            files: ["Foreign.swift": "struct Foreign {}"]
        )
        defer { foreignAuthority.repositoryFixture.cleanup() }
        let foreignBinding = try await makeResolvedBinding(
            authority: foreignAuthority,
            path: "Foreign.swift",
            fileID: UUID(),
            artifactOutcome: .ready(makeArtifact(definitions: ["Foreign"], references: []))
        )
        let foreignStore = try makeStore(binding: foreignBinding)
        let foreign = try acceptedNode(from: foreignStore.accept(foreignBinding))
        XCTAssertNil(store.makeResolvedTarget(
            for: query,
            source: source.identity,
            target: foreign.identity
        ))

        let replacementTargetBinding = try await makeResolvedBinding(
            authority: authority,
            path: "Target.swift",
            fileID: targetFileID,
            requestGeneration: 8,
            artifactOutcome: .ready(makeArtifact(definitions: ["TargetV2"], references: []))
        )
        _ = try acceptedNode(from: store.accept(replacementTargetBinding))
        XCTAssertNil(store.immediateResult(
            for: query,
            resolvedTargets: [resolution],
            sourceCoverage: [covered],
            definitionUniverseCoverage: matchingComplete
        ))

        let replacementSourceBinding = try await makeResolvedBinding(
            authority: authority,
            path: "Source.swift",
            fileID: sourceFileID,
            requestGeneration: 8,
            artifactOutcome: .ready(makeArtifact(definitions: ["SourceV2"], references: ["TargetV2"]))
        )
        _ = try acceptedNode(from: store.accept(replacementSourceBinding))
        XCTAssertNil(store.immediateResult(
            for: query,
            sourceCoverage: [covered],
            definitionUniverseCoverage: matchingComplete
        ))
    }

    func testSizeAccountingAndAcceptanceFailClosedOnLimitAndArithmeticOverflow() async throws {
        let authority = try await makeAuthority(
            name: #function,
            files: [
                "Target.swift": "struct Target {}",
                "Other.swift": "struct Other {}"
            ],
            rootID: uuid("80000000-0000-0000-0000-000000000001"),
            rootLifetimeID: uuid("80000000-0000-0000-0000-000000000002")
        )
        defer { authority.repositoryFixture.cleanup() }

        let artifact = makeArtifact(definitions: ["Target"], references: ["Dependency"])
        let binding = try await makeResolvedBinding(
            authority: authority,
            path: "Target.swift",
            fileID: uuid("80000000-0000-0000-0000-000000000003"),
            artifactOutcome: .ready(artifact)
        )
        let otherBinding = try await makeResolvedBinding(
            authority: authority,
            path: "Other.swift",
            fileID: UUID(),
            artifactOutcome: .ready(artifact)
        )
        let baselineStore = try makeStore(binding: binding)
        _ = try acceptedNode(from: baselineStore.accept(binding))
        let nodeBytes = baselineStore.accounting.bytes
        XCTAssertEqual(baselineStore.accounting.nodes, 1)
        XCTAssertEqual(baselineStore.accounting.postings, 2)
        XCTAssertGreaterThan(nodeBytes, 0)
        _ = try acceptedNode(from: baselineStore.accept(otherBinding))
        let cumulativeNodeBytes = baselineStore.accounting.bytes
        XCTAssertEqual(baselineStore.accounting.nodes, 2)
        XCTAssertEqual(baselineStore.accounting.postings, 4)

        let exactStore = try makeStore(
            binding: binding,
            sizePolicy: WorkspaceCodemapSelectionGraphSizePolicy(
                maxNodes: 1,
                maxPostings: 2,
                maxEdges: 1,
                maxBytes: nodeBytes + 64,
                maxDefinitionCandidates: 1
            )
        )
        let exactNode = try acceptedNode(from: exactStore.accept(binding))
        guard case let .edge(_, exactAccounting) = exactStore.makeEdge(
            source: exactNode.identity,
            target: exactNode.identity
        ) else { return XCTFail("All four exact budget boundaries must be accepted.") }
        XCTAssertEqual(exactAccounting.nodes, 1)
        XCTAssertEqual(exactAccounting.postings, 2)
        XCTAssertEqual(exactAccounting.edges, 1)
        XCTAssertEqual(exactAccounting.bytes, nodeBytes + 64)

        let nodeExceeded = try makeStore(binding: binding, sizePolicy: policy(maxNodes: 0))
        XCTAssertEqual(
            nodeExceeded.accept(binding),
            .rejected(.sizeLimitExceeded(.limitExceeded(dimension: .nodes, attempted: 1, limit: 0)))
        )
        let postingsExceeded = try makeStore(binding: binding, sizePolicy: policy(maxPostings: 1))
        XCTAssertEqual(
            postingsExceeded.accept(binding),
            .rejected(.sizeLimitExceeded(.limitExceeded(dimension: .postings, attempted: 2, limit: 1)))
        )
        let bytesExceeded = try makeStore(binding: binding, sizePolicy: policy(maxBytes: nodeBytes - 1))
        XCTAssertEqual(
            bytesExceeded.accept(binding),
            .rejected(.sizeLimitExceeded(.limitExceeded(
                dimension: .bytes,
                attempted: nodeBytes,
                limit: nodeBytes - 1
            )))
        )
        let edgeExceeded = try makeStore(binding: binding, sizePolicy: policy(maxEdges: 0))
        let edgeNode = try acceptedNode(from: edgeExceeded.accept(binding))
        XCTAssertEqual(
            edgeExceeded.makeEdge(source: edgeNode.identity, target: edgeNode.identity),
            .rejected(.sizeLimitExceeded(.limitExceeded(dimension: .edges, attempted: 1, limit: 0)))
        )

        let cumulativeExact = try makeStore(
            binding: binding,
            sizePolicy: policy(
                maxNodes: 2,
                maxPostings: 4,
                maxEdges: 2,
                maxBytes: cumulativeNodeBytes + 128
            )
        )
        let cumulativeExactFirst = try acceptedNode(from: cumulativeExact.accept(binding))
        let cumulativeExactSecond = try acceptedNode(from: cumulativeExact.accept(otherBinding))
        guard case .edge = cumulativeExact.makeEdge(
            source: cumulativeExactFirst.identity,
            target: cumulativeExactSecond.identity
        ),
            case let .edge(_, cumulativeExactAccounting) = cumulativeExact.makeEdge(
                source: cumulativeExactSecond.identity,
                target: cumulativeExactFirst.identity
            )
        else { return XCTFail("Cumulative posting, byte, and second-edge exact boundaries must succeed.") }
        XCTAssertEqual(cumulativeExactAccounting.postings, 4)
        XCTAssertEqual(cumulativeExactAccounting.edges, 2)
        XCTAssertEqual(cumulativeExactAccounting.bytes, cumulativeNodeBytes + 128)

        let cumulativePostings = try makeStore(
            binding: binding,
            sizePolicy: policy(maxNodes: 2, maxPostings: 3)
        )
        _ = try acceptedNode(from: cumulativePostings.accept(binding))
        let postingsBeforeRejection = cumulativePostings.accounting
        XCTAssertEqual(
            cumulativePostings.accept(otherBinding),
            .rejected(.sizeLimitExceeded(.limitExceeded(
                dimension: .postings,
                attempted: 4,
                limit: 3
            )))
        )
        XCTAssertEqual(cumulativePostings.accounting, postingsBeforeRejection)

        let cumulativeBytes = try makeStore(
            binding: binding,
            sizePolicy: policy(maxNodes: 2, maxPostings: 4, maxBytes: cumulativeNodeBytes - 1)
        )
        _ = try acceptedNode(from: cumulativeBytes.accept(binding))
        let bytesBeforeRejection = cumulativeBytes.accounting
        XCTAssertEqual(
            cumulativeBytes.accept(otherBinding),
            .rejected(.sizeLimitExceeded(.limitExceeded(
                dimension: .bytes,
                attempted: cumulativeNodeBytes,
                limit: cumulativeNodeBytes - 1
            )))
        )
        XCTAssertEqual(cumulativeBytes.accounting, bytesBeforeRejection)

        let secondEdgeExceeded = try makeStore(
            binding: binding,
            sizePolicy: policy(
                maxNodes: 2,
                maxPostings: 4,
                maxEdges: 1,
                maxBytes: cumulativeNodeBytes + 128
            )
        )
        let edgeFirst = try acceptedNode(from: secondEdgeExceeded.accept(binding))
        let edgeSecond = try acceptedNode(from: secondEdgeExceeded.accept(otherBinding))
        guard case .edge = secondEdgeExceeded.makeEdge(
            source: edgeFirst.identity,
            target: edgeSecond.identity
        ) else { return XCTFail("First cumulative edge must succeed.") }
        let edgeBeforeRejection = secondEdgeExceeded.accounting
        XCTAssertEqual(
            secondEdgeExceeded.makeEdge(source: edgeSecond.identity, target: edgeFirst.identity),
            .rejected(.sizeLimitExceeded(.limitExceeded(
                dimension: .edges,
                attempted: 2,
                limit: 1
            )))
        )
        XCTAssertEqual(secondEdgeExceeded.accounting, edgeBeforeRejection)

        let cumulative = try makeStore(binding: binding, sizePolicy: policy(maxNodes: 1))
        _ = try acceptedNode(from: cumulative.accept(binding))
        XCTAssertEqual(
            cumulative.accept(otherBinding),
            .rejected(.sizeLimitExceeded(.limitExceeded(dimension: .nodes, attempted: 2, limit: 1)))
        )
        XCTAssertEqual(cumulative.accounting.nodes, 1)

        let unlimited = policy(
            maxNodes: .max,
            maxPostings: .max,
            maxEdges: .max,
            maxBytes: .max,
            maxDefinitionCandidates: .max
        )
        let current = exactAccounting
        let overflowCases: [
            (
                WorkspaceCodemapSelectionGraphSizeDelta,
                WorkspaceCodemapSelectionGraphSizeDimension
            )
        ] = [
            (.init(nodes: .max, postings: 0, edges: 0, bytes: 0), .nodes),
            (.init(nodes: 0, postings: .max, edges: 0, bytes: 0), .postings),
            (.init(nodes: 0, postings: 0, edges: .max, bytes: 0), .edges),
            (.init(nodes: 0, postings: 0, edges: 0, bytes: .max), .bytes)
        ]
        for (delta, dimension) in overflowCases {
            XCTAssertEqual(
                current.adding(delta, policy: unlimited),
                .failure(.arithmeticOverflow(dimension))
            )
        }

        requireSendable(CodeMapSelectionGraphContribution.self)
        requireSendable(WorkspaceCodemapSelectionGraphBindingGeneration.self)
        requireSendable(WorkspaceCodemapSelectionGraphContributionGeneration.self)
        requireSendable(WorkspaceCodemapSelectionGraphKey.self)
        requireSendable(WorkspaceCodemapSelectionGraphNodeIdentity.self)
        requireSendable(WorkspaceCodemapSelectionGraphDuplicateOrderKey.self)
        requireSendable(WorkspaceCodemapSelectionGraphNode.self)
        requireSendable(WorkspaceCodemapSelectionGraphContributionAcceptanceResult.self)
        requireSendable(WorkspaceCodemapSelectionGraphEdge.self)
        requireSendable(WorkspaceCodemapSelectionGraphEdgeConstructionResult.self)
        requireSendable(WorkspaceCodemapSelectionGraphQuery.self)
        requireSendable(WorkspaceCodemapSelectionGraphSourceCoverage.self)
        requireSendable(WorkspaceCodemapSelectionGraphResolvedTarget.self)
        requireSendable(WorkspaceCodemapSelectionGraphQueryResult.self)
        requireSendable(WorkspaceCodemapSelectionGraphSizeAccounting.self)
    }

    private func makeAuthority(
        name: String,
        files: [String: String],
        rootID: UUID = UUID(),
        rootLifetimeID: UUID = UUID()
    ) async throws -> WorkspaceCodemapAuthorityTestFixture {
        try await WorkspaceCodemapAuthorityTestFixture.make(
            name: name,
            files: files,
            rootID: rootID,
            rootLifetimeID: rootLifetimeID
        )
    }

    private func makeResolvedBinding(
        authority: WorkspaceCodemapAuthorityTestFixture,
        path: String,
        fileID: UUID,
        catalogGeneration: UInt64 = 11,
        requestGeneration: UInt64 = 7,
        artifactOutcome: CodeMapSyntaxArtifactOutcome
    ) async throws -> WorkspaceCodemapArtifactBinding {
        let source = try await authority.validatedWorktreeSource(loadedRootRelativePath: path)
        let identity = try authority.bindingIdentity(
            fileID: fileID,
            loadedRootRelativePath: path
        )
        let sourceAuthority = try await authority.sourceAuthority(repositoryRelativePath: path)
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: source.decoderPolicy
        )
        let artifactKey = try CodeMapArtifactKey(source: source, pipelineIdentity: pipeline)
        let expectation = try XCTUnwrap(WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: identity,
            source: source,
            expectedArtifactKey: artifactKey,
            classificationReason: .dirty,
            sourceAuthority: sourceAuthority
        ))
        let token = try XCTUnwrap(WorkspaceCodemapArtifactRequestToken.issue(
            identity: identity,
            requestGeneration: requestGeneration,
            catalogGeneration: catalogGeneration,
            sourceExpectation: expectation
        ))
        let completion = try XCTUnwrap(WorkspaceCodemapArtifactCompletion.validatedWorktree(
            token: token,
            language: .swift,
            outcome: artifactOutcome
        ))
        var binding = try XCTUnwrap(WorkspaceCodemapArtifactBinding(pending: token))
        XCTAssertEqual(binding.apply(completion), .accepted)
        return binding
    }

    private func makeStore(
        binding: WorkspaceCodemapArtifactBinding,
        contributionGeneration: UInt64 = 13,
        schemaVersion: UInt32 = CodeMapSelectionGraphContribution.currentSchemaVersion,
        policyVersion: UInt32 = CodeMapSelectionGraphContribution.currentPolicyVersion,
        sizePolicy: WorkspaceCodemapSelectionGraphSizePolicy = .initial
    ) throws -> WorkspaceCodemapSelectionGraphModelStore {
        try XCTUnwrap(WorkspaceCodemapSelectionGraphModelStore.authorized(
            by: binding,
            contributionGeneration: .init(rawValue: contributionGeneration),
            schemaVersion: schemaVersion,
            policyVersion: policyVersion,
            sizePolicy: sizePolicy
        ))
    }

    private func completeCoverage(
        for store: WorkspaceCodemapSelectionGraphModelStore,
        catalogGeneration: UInt64? = nil,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken? = nil
    ) throws -> WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage {
        let token = WorkspaceCodemapProjectionCatalogToken(
            rootEpoch: store.key.rootEpoch,
            topologyGeneration: 1,
            appliedIndexGeneration: 1,
            catalogGeneration: catalogGeneration ?? store.key.catalogGeneration,
            ingressGeneration: 1,
            projectionInvalidationGeneration: 1
        )
        let generation = WorkspaceCodemapProjectionGeneration(
            catalogToken: token,
            repositoryAuthority: repositoryAuthority ?? store.key.repositoryAuthority,
            contributionGeneration: store.key.contributionGeneration,
            schemaVersion: store.key.schemaVersion,
            policyVersion: store.key.policyVersion
        )
        let counts = WorkspaceCodemapProjectionCounts(
            supportedCandidateCount: 2,
            processedCandidateCount: 2,
            contributedCount: 2,
            emptyCount: 0,
            terminalArtifactCount: 0,
            terminalExcludedCount: 0,
            transientCount: 0
        )
        let completion = WorkspaceCodemapProjectionCatalogCompletion(
            token: token,
            finalCursor: nil,
            supportedCandidateCount: 2
        )
        let proof: WorkspaceCodemapProjectionCoverageProof
        switch WorkspaceCodemapProjectionCoverageProof.validated(
            generation: generation,
            catalogCompletion: completion,
            counts: counts,
            lastSegmentSequence: 0
        ) {
        case let .success(value):
            proof = value
        case let .failure(error):
            throw error
        }
        return .complete(
            proof: proof,
            candidateCount: proof.candidateCount,
            contributedCount: proof.contributedCount,
            terminalCount: proof.terminalCount
        )
    }

    private func acceptedNode(
        from result: WorkspaceCodemapSelectionGraphContributionAcceptanceResult
    ) throws -> WorkspaceCodemapSelectionGraphNode {
        guard case let .accepted(node, _) = result else {
            throw TestError.acceptanceFailed(result)
        }
        return node
    }

    private func makeArtifactKey(seed: UInt8) throws -> CodeMapArtifactKey {
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        return CodeMapArtifactKey(
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: seed, count: 32)),
            rawByteCount: UInt64(seed),
            pipelineIdentity: pipeline
        )
    }

    private func makeArtifact(
        definitions: [String],
        references: [String],
        imports: [String] = []
    ) -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: imports,
            classes: definitions.map { ClassInfo(name: $0, methods: [], properties: []) },
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: references
        )
    }

    private func policy(
        maxNodes: UInt64 = 100,
        maxPostings: UInt64 = 100,
        maxEdges: UInt64 = 100,
        maxBytes: UInt64 = 1_000_000,
        maxDefinitionCandidates: UInt64 = 100
    ) -> WorkspaceCodemapSelectionGraphSizePolicy {
        WorkspaceCodemapSelectionGraphSizePolicy(
            maxNodes: maxNodes,
            maxPostings: maxPostings,
            maxEdges: maxEdges,
            maxBytes: maxBytes,
            maxDefinitionCandidates: maxDefinitionCandidates
        )
    }

    private func repositoryAuthority(
        like value: WorkspaceCodemapRepositoryAuthorityToken,
        authorityGeneration: UInt64
    ) -> WorkspaceCodemapRepositoryAuthorityToken {
        WorkspaceCodemapRepositoryAuthorityToken(
            authorityGeneration: authorityGeneration,
            repositoryNamespace: value.repositoryNamespace,
            objectFormat: value.objectFormat,
            repositoryBindingEpoch: value.repositoryBindingEpoch,
            worktreeBindingEpoch: value.worktreeBindingEpoch,
            layoutGeneration: value.layoutGeneration,
            indexGeneration: value.indexGeneration,
            checkoutConfigurationGeneration: value.checkoutConfigurationGeneration,
            attributeGeneration: value.attributeGeneration,
            sparseGeneration: value.sparseGeneration,
            metadataGeneration: value.metadataGeneration
        )
    }

    private func requireSendable(_: (some Sendable).Type) {}

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}

private enum TestError: Error {
    case acceptanceFailed(WorkspaceCodemapSelectionGraphContributionAcceptanceResult)
}
