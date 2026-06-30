import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceCodemapArtifactBindingTests: XCTestCase {
    func testBindingAcceptsCurrentCompletionAndPreservesValueStateForReplays() async throws {
        let fixture = try await makeWorktreeFixture(name: #function)
        let completion = try validatedCompletion(fixture)
        var binding = try XCTUnwrap(WorkspaceCodemapArtifactBinding(pending: fixture.token))
        let pendingCopy = binding

        XCTAssertEqual(binding.apply(completion), .accepted)
        XCTAssertEqual(binding.availability, .resolved(completion))
        XCTAssertEqual(pendingCopy.availability, .pending(fixture.token))

        let resolved = binding
        XCTAssertEqual(binding.apply(completion), .exactDuplicate)
        XCTAssertEqual(binding, resolved)

        let conflicting = try XCTUnwrap(WorkspaceCodemapArtifactCompletion.validatedWorktree(
            token: fixture.token,
            language: .swift,
            outcome: .decodeFailed(.undecodable)
        ))
        XCTAssertEqual(binding.apply(conflicting), .notPending)
        XCTAssertEqual(binding, resolved)
    }

    func testBindingRejectsLegitimatelyIssuedStaleTokensWithoutChangingValue() async throws {
        let rootID = UUID()
        let lifetimeID = UUID()
        let fixture = try await makeWorktreeFixture(
            name: #function,
            rootID: rootID,
            rootLifetimeID: lifetimeID
        )
        let differentRoot = try await makeWorktreeFixture(
            name: "\(#function)-root",
            rootID: UUID(),
            rootLifetimeID: lifetimeID
        )
        let differentLifetime = try await makeWorktreeFixture(
            name: "\(#function)-lifetime",
            rootID: rootID,
            rootLifetimeID: UUID()
        )
        let differentRepository = try await makeWorktreeFixture(
            name: "\(#function)-repository",
            rootID: rootID,
            rootLifetimeID: lifetimeID
        )

        let differentFileIdentity = try fixture.authorityFixture.bindingIdentity(
            fileID: UUID(),
            loadedRootRelativePath: fixture.loadedRootRelativePath
        )
        let differentFileToken = try issueWorktreeToken(
            identity: differentFileIdentity,
            source: fixture.source,
            sourceAuthority: fixture.sourceAuthority
        )
        let differentPath = "Sources/Other.swift"
        let differentPathSource = try await fixture.authorityFixture.validatedWorktreeSource(
            loadedRootRelativePath: differentPath
        )
        let differentPathAuthority = try await fixture.authorityFixture.sourceAuthority(
            repositoryRelativePath: differentPath
        )
        let differentPathIdentity = try fixture.authorityFixture.bindingIdentity(
            fileID: fixture.identity.fileID,
            loadedRootRelativePath: differentPath
        )
        let differentPathToken = try issueWorktreeToken(
            identity: differentPathIdentity,
            source: differentPathSource,
            sourceAuthority: differentPathAuthority
        )
        let differentRootPath = try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
            rootID: rootID,
            rootLifetimeID: lifetimeID,
            fileID: fixture.identity.fileID,
            standardizedRootPath: "/tmp/other-project",
            standardizedRelativePath: fixture.identity.standardizedRelativePath,
            standardizedFullPath: "/tmp/other-project/\(fixture.identity.standardizedRelativePath)"
        ))
        let differentRootPathToken = try issueWorktreeToken(
            identity: differentRootPath,
            source: fixture.source,
            sourceAuthority: fixture.sourceAuthority
        )
        let pathGenerationAuthority = try await fixture.authorityFixture.sourceAuthority(
            repositoryRelativePath: fixture.repositoryRelativePath,
            pathGeneration: 4
        )
        let pathGenerationToken = try issueWorktreeToken(
            identity: fixture.identity,
            source: fixture.source,
            sourceAuthority: pathGenerationAuthority
        )
        let ingressGenerationAuthority = try await fixture.authorityFixture.sourceAuthority(
            repositoryRelativePath: fixture.repositoryRelativePath,
            ingressGeneration: 5
        )
        let ingressGenerationToken = try issueWorktreeToken(
            identity: fixture.identity,
            source: fixture.source,
            sourceAuthority: ingressGenerationAuthority
        )
        let auxiliarySource = try await fixture.authorityFixture.validatedWorktreeSource(
            loadedRootRelativePath: "Sources/Auxiliary.swift"
        )
        let sourceValidationToken = try issueWorktreeToken(
            identity: fixture.identity,
            source: auxiliarySource,
            sourceAuthority: fixture.sourceAuthority
        )
        let repositoryAuthorityToken = try issueWorktreeToken(
            identity: fixture.identity,
            source: differentRepository.source,
            sourceAuthority: differentRepository.sourceAuthority
        )

        let cases: [(String, WorkspaceCodemapArtifactRequestToken, WorkspaceCodemapArtifactCompletionDisposition)] = try [
            ("root ID", differentRoot.token, .rootIDMismatch),
            ("root lifetime", differentLifetime.token, .rootLifetimeIDMismatch),
            ("file ID", differentFileToken, .fileIDMismatch),
            ("root path", differentRootPathToken, .rootPathMismatch),
            ("relative path", differentPathToken, .relativePathMismatch),
            (
                "request generation",
                issueWorktreeToken(
                    identity: fixture.identity,
                    source: fixture.source,
                    sourceAuthority: fixture.sourceAuthority,
                    requestGeneration: 8
                ),
                .requestGenerationMismatch
            ),
            (
                "catalog generation",
                issueWorktreeToken(
                    identity: fixture.identity,
                    source: fixture.source,
                    sourceAuthority: fixture.sourceAuthority,
                    catalogGeneration: 12
                ),
                .catalogGenerationMismatch
            ),
            ("repository authority", repositoryAuthorityToken, .repositoryAuthorityMismatch),
            ("path generation", pathGenerationToken, .sourceAuthorityPathGenerationMismatch),
            ("ingress generation", ingressGenerationToken, .sourceAuthorityIngressGenerationMismatch),
            ("source validation", sourceValidationToken, .sourceValidationTokenMismatch)
        ]

        for (label, token, expectedDisposition) in cases {
            let completion = try XCTUnwrap(WorkspaceCodemapArtifactCompletion.validatedWorktree(
                token: token,
                language: .swift,
                outcome: .readyNoSymbols
            ))
            var binding = try XCTUnwrap(WorkspaceCodemapArtifactBinding(pending: fixture.token))
            let original = binding
            XCTAssertEqual(binding.apply(completion), expectedDisposition, label)
            XCTAssertEqual(binding, original, label)
        }
    }

    func testBindingAcceptsOnlyProofBoundCleanGitBlobCompletion() async throws {
        let fixture = try await makeCleanFixture(
            name: #function,
            text: "struct Clean {}"
        )
        let completion = try XCTUnwrap(WorkspaceCodemapArtifactCompletion.cleanGitBlob(
            token: fixture.token,
            language: .swift,
            association: fixture.association
        ))
        var binding = try XCTUnwrap(WorkspaceCodemapArtifactBinding(pending: fixture.token))

        XCTAssertEqual(binding.apply(completion), .accepted)
        XCTAssertEqual(binding.apply(completion), .exactDuplicate)
    }

    func testCleanCompletionFactoryRejectsUnrelatedVerifiedAssociations() async throws {
        let expected = try await makeCleanFixture(
            name: "\(#function)-expected",
            text: "struct Expected {}"
        )
        let wrongNamespace = try await makeCleanFixture(
            name: "\(#function)-namespace",
            text: "struct Expected {}"
        )
        let wrongFormat = try await makeCleanFixture(
            name: "\(#function)-format",
            text: "struct Expected {}",
            format: .sha256
        )
        let wrongOID = try await makeCleanFixture(
            name: "\(#function)-oid",
            text: "struct OtherOID {}"
        )
        let wrongPipeline = try await makeCleanFixture(
            name: "\(#function)-pipeline",
            text: "struct Expected {}",
            language: .python
        )

        for (label, association) in [
            ("namespace", wrongNamespace.association),
            ("object format", wrongFormat.association),
            ("OID", wrongOID.association),
            ("pipeline", wrongPipeline.association)
        ] {
            XCTAssertNil(
                WorkspaceCodemapArtifactCompletion.cleanGitBlob(
                    token: expected.token,
                    language: .swift,
                    association: association
                ),
                label
            )
        }

        let worktree = try await makeWorktreeFixture(name: "\(#function)-worktree")
        XCTAssertNil(WorkspaceCodemapArtifactCompletion.validatedWorktree(
            token: worktree.token,
            language: .python,
            outcome: .readyNoSymbols
        ))
    }

    func testFactoriesTieServiceIssuedAuthorityPrefixRepositoryPathAndBindingIdentity() async throws {
        let fixture = try await makeWorktreeFixture(
            name: #function,
            loadedRootRelativePath: "Sources"
        )
        let mismatchedLifetime = try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
            rootID: fixture.identity.rootID,
            rootLifetimeID: UUID(),
            fileID: fixture.identity.fileID,
            standardizedRootPath: fixture.identity.standardizedRootPath,
            standardizedRelativePath: fixture.identity.standardizedRelativePath,
            standardizedFullPath: fixture.identity.standardizedFullPath
        ))
        XCTAssertNil(WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: mismatchedLifetime,
            source: fixture.source,
            expectedArtifactKey: fixture.artifactKey,
            classificationReason: .dirty,
            sourceAuthority: fixture.sourceAuthority
        ))

        let mismatchedPath = try XCTUnwrap(WorkspaceCodemapArtifactBindingIdentity(
            rootID: fixture.identity.rootID,
            rootLifetimeID: fixture.identity.rootLifetimeID,
            fileID: fixture.identity.fileID,
            standardizedRootPath: fixture.identity.standardizedRootPath,
            standardizedRelativePath: "Other.swift",
            standardizedFullPath: fixture.authorityFixture.loadedRoot.appendingPathComponent("Other.swift").path
        ))
        XCTAssertNil(WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: mismatchedPath,
            source: fixture.source,
            expectedArtifactKey: fixture.artifactKey,
            classificationReason: .dirty,
            sourceAuthority: fixture.sourceAuthority
        ))

        XCTAssertEqual(fixture.sourceAuthority.repositoryRelativeLoadedRootPrefix, "Sources")
        XCTAssertEqual(fixture.sourceAuthority.standardizedRepositoryRelativePath, "Sources/Example.swift")
        XCTAssertNil(try WorkspaceCodemapArtifactRequestToken.issue(
            identity: fixture.authorityFixture.bindingIdentity(
                fileID: UUID(),
                loadedRootRelativePath: fixture.loadedRootRelativePath
            ),
            requestGeneration: 7,
            catalogGeneration: 11,
            sourceExpectation: fixture.expectation
        ))

        let cleanSource = try await fixture.authorityFixture.cleanSource(bytes: Data("clean".utf8))
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: cleanSource.decoderPolicy
        )
        guard case let .cleanGitBlob(namespace, blobOID) = cleanSource.provenance else {
            return XCTFail("expected clean Git blob provenance")
        }
        let locator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: namespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline
        )
        XCTAssertNotNil(WorkspaceCodemapSourceExpectation.cleanGitBlob(
            bindingIdentity: fixture.identity,
            locatorIdentity: locator,
            sourceAuthority: fixture.sourceAuthority
        ))
        let otherNamespace = try GitBlobRepositoryNamespace(
            rawValue: String(repeating: "cd", count: 32)
        )
        XCTAssertNil(WorkspaceCodemapSourceExpectation.cleanGitBlob(
            bindingIdentity: fixture.identity,
            locatorIdentity: GitBlobCodeMapLocatorIdentity(
                repositoryNamespace: otherNamespace,
                blobOID: blobOID,
                pipelineIdentity: pipeline
            ),
            sourceAuthority: fixture.sourceAuthority
        ))
        XCTAssertNil(WorkspaceCodemapSourceExpectation.cleanGitBlob(
            bindingIdentity: fixture.identity,
            locatorIdentity: GitBlobCodeMapLocatorIdentity(
                repositoryNamespace: namespace,
                blobOID: GitBlobOID.blob(
                    bytes: cleanSource.rawBytes,
                    objectFormat: .sha256
                ),
                pipelineIdentity: pipeline
            ),
            sourceAuthority: fixture.sourceAuthority
        ))
    }

    func testIdentityRequiresAuthoritativeRootRelativeContainmentAndAcceptsSymlinkRootSpelling() throws {
        let rootID = UUID()
        let lifetimeID = UUID()
        let fileID = UUID()
        func identity(root: String, relative: String, full: String) -> WorkspaceCodemapArtifactBindingIdentity? {
            WorkspaceCodemapArtifactBindingIdentity(
                rootID: rootID,
                rootLifetimeID: lifetimeID,
                fileID: fileID,
                standardizedRootPath: root,
                standardizedRelativePath: relative,
                standardizedFullPath: full
            )
        }

        XCTAssertNil(identity(root: "/tmp/project", relative: "../Outside.swift", full: "/tmp/Outside.swift"))
        XCTAssertNil(identity(root: "/tmp/project", relative: "/tmp/project/File.swift", full: "/tmp/project/File.swift"))
        XCTAssertNil(identity(root: "/tmp/project", relative: "File.swift", full: "/tmp/project-sibling/File.swift"))
        XCTAssertNil(identity(root: "/tmp/project", relative: "A.swift", full: "/tmp/project/B.swift"))

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceCodemapArtifactBindingTests-\(UUID().uuidString)", isDirectory: true)
        let realRoot = parent.appendingPathComponent("real", isDirectory: true)
        let symlinkRoot = parent.appendingPathComponent("logical", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)

        let accepted = identity(
            root: symlinkRoot.path,
            relative: "Sources/Example.swift",
            full: symlinkRoot.appendingPathComponent("Sources/Example.swift").path
        )
        XCTAssertEqual(accepted?.standardizedRootPath, symlinkRoot.path)
        XCTAssertNil(identity(
            root: symlinkRoot.path,
            relative: "Sources/Example.swift",
            full: realRoot.appendingPathComponent("Sources/Example.swift").path
        ))
    }

    func testUnsupportedAvailabilityIsBindingLocalAndRejectsCompletionWithoutMutation() async throws {
        let fixture = try await makeWorktreeFixture(name: #function)
        var binding = WorkspaceCodemapArtifactBinding(
            identity: fixture.identity,
            unsupportedFileExtension: "unsupported"
        )
        let original = binding

        XCTAssertEqual(binding.availability, .unsupported(fileExtension: "unsupported"))
        XCTAssertEqual(try binding.apply(validatedCompletion(fixture)), .notPending)
        XCTAssertEqual(binding, original)
    }

    func testPresentationRendersOneArtifactAtDistinctPathsWithoutMutationOrLeakage() async throws {
        let fixture = try await makeWorktreeFixture(name: #function)
        let artifact = makeArtifact()
        let artifactBeforeRendering = artifact
        let completion = try XCTUnwrap(WorkspaceCodemapArtifactCompletion.validatedWorktree(
            token: fixture.token,
            language: .swift,
            outcome: .ready(artifact)
        ))
        let displayPaths = [
            "/tmp/worktrees/project/Sources/Example.swift",
            "Sources/Example.swift",
            "Project/Sources/Example.swift"
        ]

        let rendered = try displayPaths.map { displayPath in
            try XCTUnwrap(
                WorkspaceCodemapArtifactPresentation(
                    identity: completion.token.identity,
                    displayPath: displayPath,
                    completion: completion
                ).renderedCodemap()
            )
        }

        for (index, value) in rendered.enumerated() {
            XCTAssertTrue(value.text.hasPrefix("File: \(displayPaths[index])\nImports:\n  - Foundation"))
            XCTAssertEqual(value.tokenCount, TokenCalculationService.estimateTokens(for: value.text))
        }
        XCTAssertEqual(Set(rendered.map(\.text)).count, displayPaths.count)
        XCTAssertEqual(
            rendered.map { String($0.text.suffix(artifact.apiDescription.count)) },
            Array(repeating: artifact.apiDescription, count: displayPaths.count)
        )
        XCTAssertEqual(artifact, artifactBeforeRendering)
        XCTAssertEqual(completion.outcome, .ready(artifactBeforeRendering))

        let serializedArtifact = try XCTUnwrap(String(data: JSONEncoder().encode(artifact), encoding: .utf8))
        for displayPath in displayPaths {
            XCTAssertFalse(serializedArtifact.contains(displayPath))
        }
    }

    func testPresentationRendersOnlyReadyMatchingIdentityAndModelsAreSendable() async throws {
        let fixture = try await makeWorktreeFixture(name: #function)
        let outcomes: [CodeMapSyntaxArtifactOutcome] = [
            .readyNoSymbols,
            .oversize(.lines(actual: 2, limit: 1)),
            .decodeFailed(.undecodable),
            .parseFailed(.parserReturnedNilTree)
        ]

        for outcome in outcomes {
            let completion = try XCTUnwrap(WorkspaceCodemapArtifactCompletion.validatedWorktree(
                token: fixture.token,
                language: .swift,
                outcome: outcome
            ))
            XCTAssertNil(
                WorkspaceCodemapArtifactPresentation(
                    identity: fixture.identity,
                    displayPath: "Sources/Example.swift",
                    completion: completion
                ).renderedCodemap()
            )
        }

        let ready = try XCTUnwrap(WorkspaceCodemapArtifactCompletion.validatedWorktree(
            token: fixture.token,
            language: .swift,
            outcome: .ready(makeArtifact())
        ))
        XCTAssertNil(
            try WorkspaceCodemapArtifactPresentation(
                identity: fixture.authorityFixture.bindingIdentity(
                    fileID: UUID(),
                    loadedRootRelativePath: fixture.loadedRootRelativePath
                ),
                displayPath: "Sources/Example.swift",
                completion: ready
            ).renderedCodemap()
        )

        requireSendable(WorkspaceCodemapArtifactBindingIdentity.self)
        requireSendable(WorkspaceCodemapArtifactRequestToken.self)
        requireSendable(WorkspaceCodemapSourceExpectation.self)
        requireSendable(WorkspaceCodemapArtifactCompletion.self)
        requireSendable(WorkspaceCodemapArtifactBindingAvailability.self)
        requireSendable(WorkspaceCodemapArtifactBinding.self)
        requireSendable(WorkspaceCodemapArtifactPresentation.self)
        requireSendable(WorkspaceCodemapArtifactRenderedCodemap.self)
    }

    private struct WorktreeFixture {
        let authorityFixture: WorkspaceCodemapAuthorityTestFixture
        let loadedRootRelativePath: String
        let repositoryRelativePath: String
        let identity: WorkspaceCodemapArtifactBindingIdentity
        let source: CodeMapSourceSnapshot
        let artifactKey: CodeMapArtifactKey
        let sourceAuthority: WorkspaceCodemapSourceAuthorityToken
        let expectation: WorkspaceCodemapSourceExpectation
        let token: WorkspaceCodemapArtifactRequestToken
    }

    private struct CleanFixture {
        let authorityFixture: WorkspaceCodemapAuthorityTestFixture
        let token: WorkspaceCodemapArtifactRequestToken
        let association: VerifiedGitBlobCodeMapLocatorAssociation
    }

    private func makeWorktreeFixture(
        name: String,
        text: String = "struct Example {}",
        loadedRootRelativePath: String = "",
        rootID: UUID = UUID(),
        rootLifetimeID: UUID = UUID()
    ) async throws -> WorktreeFixture {
        let repositoryPath = "Sources/Example.swift"
        let loadedPath = loadedRootRelativePath.isEmpty
            ? repositoryPath
            : "Example.swift"
        let authorityFixture = try await WorkspaceCodemapAuthorityTestFixture.make(
            name: name,
            files: [
                repositoryPath: text,
                "Sources/Other.swift": "struct Other {}",
                "Sources/Auxiliary.swift": "struct Auxiliary {}"
            ],
            loadedRootRelativePath: loadedRootRelativePath,
            rootID: rootID,
            rootLifetimeID: rootLifetimeID
        )
        let source = try await authorityFixture.validatedWorktreeSource(
            loadedRootRelativePath: loadedPath
        )
        let identity = try authorityFixture.bindingIdentity(
            fileID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            loadedRootRelativePath: loadedPath
        )
        let sourceAuthority = try await authorityFixture.sourceAuthority(
            repositoryRelativePath: repositoryPath
        )
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: source.decoderPolicy
        )
        let artifactKey = try CodeMapArtifactKey(
            source: source,
            pipelineIdentity: pipeline
        )
        let expectation = try XCTUnwrap(WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: identity,
            source: source,
            expectedArtifactKey: artifactKey,
            classificationReason: .dirty,
            sourceAuthority: sourceAuthority
        ))
        let token = try XCTUnwrap(WorkspaceCodemapArtifactRequestToken.issue(
            identity: identity,
            requestGeneration: 7,
            catalogGeneration: 11,
            sourceExpectation: expectation
        ))
        return WorktreeFixture(
            authorityFixture: authorityFixture,
            loadedRootRelativePath: loadedPath,
            repositoryRelativePath: repositoryPath,
            identity: identity,
            source: source,
            artifactKey: artifactKey,
            sourceAuthority: sourceAuthority,
            expectation: expectation,
            token: token
        )
    }

    private func issueWorktreeToken(
        identity: WorkspaceCodemapArtifactBindingIdentity,
        source: CodeMapSourceSnapshot,
        sourceAuthority: WorkspaceCodemapSourceAuthorityToken,
        requestGeneration: UInt64 = 7,
        catalogGeneration: UInt64 = 11
    ) throws -> WorkspaceCodemapArtifactRequestToken {
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: source.decoderPolicy
        )
        let artifactKey = try CodeMapArtifactKey(
            source: source,
            pipelineIdentity: pipeline
        )
        let expectation = try XCTUnwrap(WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: identity,
            source: source,
            expectedArtifactKey: artifactKey,
            classificationReason: .dirty,
            sourceAuthority: sourceAuthority
        ))
        return try XCTUnwrap(WorkspaceCodemapArtifactRequestToken.issue(
            identity: identity,
            requestGeneration: requestGeneration,
            catalogGeneration: catalogGeneration,
            sourceExpectation: expectation
        ))
    }

    private func validatedCompletion(
        _ fixture: WorktreeFixture,
        outcome: CodeMapSyntaxArtifactOutcome = .readyNoSymbols
    ) throws -> WorkspaceCodemapArtifactCompletion {
        try XCTUnwrap(WorkspaceCodemapArtifactCompletion.validatedWorktree(
            token: fixture.token,
            language: .swift,
            outcome: outcome
        ))
    }

    private func makeCleanFixture(
        name: String,
        text: String,
        format: GitObjectFormat = .sha1,
        language: LanguageType = .swift
    ) async throws -> CleanFixture {
        let path = "Sources/Example.swift"
        let authorityFixture = try await WorkspaceCodemapAuthorityTestFixture.make(
            name: name,
            files: [path: text],
            objectFormat: format
        )
        let source = try await authorityFixture.cleanSource(bytes: Data(text.utf8))
        let pipeline = try SyntaxManager().pipelineIdentity(
            for: language,
            decoderPolicy: source.decoderPolicy
        )
        let artifactKey = try CodeMapArtifactKey(
            source: source,
            pipelineIdentity: pipeline
        )
        guard case let .cleanGitBlob(namespace, blobOID) = source.provenance else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        let locator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: namespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline
        )
        let store = try CodeMapArtifactStore(
            rootURL: authorityFixture.secureArtifactRoot()
        )
        _ = try await store.insert(
            key: artifactKey,
            deterministicOutcome: .readyNoSymbols
        )
        let handle: CodeMapArtifactHandle
        switch try await store.lookup(key: artifactKey) {
        case let .hit(_, verified): handle = verified
        case .miss: throw GitBlobCodeMapLocatorStoreError.integrityCollision
        }
        let association = try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: locator,
            artifactKey: artifactKey,
            casHandle: handle
        )
        let identity = try authorityFixture.bindingIdentity(
            loadedRootRelativePath: path
        )
        let authority = try await authorityFixture.sourceAuthority(
            repositoryRelativePath: path
        )
        let expectation = try XCTUnwrap(WorkspaceCodemapSourceExpectation.cleanGitBlob(
            bindingIdentity: identity,
            locatorIdentity: locator,
            sourceAuthority: authority
        ))
        let token = try XCTUnwrap(WorkspaceCodemapArtifactRequestToken.issue(
            identity: identity,
            requestGeneration: 7,
            catalogGeneration: 11,
            sourceExpectation: expectation
        ))
        return CleanFixture(
            authorityFixture: authorityFixture,
            token: token,
            association: association
        )
    }

    private func makeArtifact() -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: ["Foundation"],
            classes: [
                ClassInfo(
                    name: "Example",
                    methods: [
                        FunctionInfo(
                            name: "run",
                            parameters: [],
                            returnType: "Void",
                            definitionLine: "func run()",
                            lineNumber: 3
                        )
                    ],
                    properties: []
                )
            ],
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: []
        )
    }

    private func requireSendable(_: (some Sendable).Type) {}
}
