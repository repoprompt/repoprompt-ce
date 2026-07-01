import Foundation

struct WorkspaceCodemapArtifactBindingIdentity: Hashable {
    let rootID: UUID
    let rootLifetimeID: UUID
    let fileID: UUID
    let standardizedRootPath: String
    let standardizedRelativePath: String
    let standardizedFullPath: String

    init?(
        rootID: UUID,
        rootLifetimeID: UUID,
        fileID: UUID,
        standardizedRootPath rootPath: String,
        standardizedRelativePath relativePath: String,
        standardizedFullPath fullPath: String
    ) {
        guard rootPath.hasPrefix("/"), fullPath.hasPrefix("/"), !relativePath.hasPrefix("/"),
              !StandardizedPath.containsNUL(rootPath),
              !StandardizedPath.containsNUL(relativePath),
              !StandardizedPath.containsNUL(fullPath)
        else { return nil }
        let standardizedRoot = StandardizedPath.absolute(rootPath)
        let standardizedRelative = StandardizedPath.relative(relativePath)
        let standardizedFull = StandardizedPath.absolute(fullPath)
        guard !standardizedRelative.isEmpty,
              standardizedRelative != "..",
              !standardizedRelative.hasPrefix("../"),
              StandardizedPath.isDescendant(standardizedFull, of: standardizedRoot),
              standardizedFull != standardizedRoot,
              standardizedFull == StandardizedPath.join(
                  standardizedRoot: standardizedRoot,
                  standardizedRelativePath: standardizedRelative
              )
        else { return nil }

        self.rootID = rootID
        self.rootLifetimeID = rootLifetimeID
        self.fileID = fileID
        standardizedRootPath = standardizedRoot
        standardizedRelativePath = standardizedRelative
        standardizedFullPath = standardizedFull
    }
}

struct WorkspaceCodemapArtifactRequestToken: Hashable {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let requestGeneration: UInt64
    let catalogGeneration: UInt64
    let sourceExpectation: WorkspaceCodemapSourceExpectation

    private init(
        identity: WorkspaceCodemapArtifactBindingIdentity,
        requestGeneration: UInt64,
        catalogGeneration: UInt64,
        sourceExpectation: WorkspaceCodemapSourceExpectation
    ) {
        self.identity = identity
        self.requestGeneration = requestGeneration
        self.catalogGeneration = catalogGeneration
        self.sourceExpectation = sourceExpectation
    }

    static func issue(
        identity: WorkspaceCodemapArtifactBindingIdentity,
        requestGeneration: UInt64,
        catalogGeneration: UInt64,
        sourceExpectation: WorkspaceCodemapSourceExpectation
    ) -> Self? {
        guard sourceExpectation.isFactoryValidated,
              sourceExpectation.bindingIdentity == identity
        else { return nil }
        return Self(
            identity: identity,
            requestGeneration: requestGeneration,
            catalogGeneration: catalogGeneration,
            sourceExpectation: sourceExpectation
        )
    }

    var isFactoryValidated: Bool {
        sourceExpectation.isFactoryValidated && sourceExpectation.bindingIdentity == identity
    }

    var expectedArtifactKey: CodeMapArtifactKey? {
        guard case let .validatedWorktree(_, artifactKey, _, _) = sourceExpectation.storage else { return nil }
        return artifactKey
    }

    var pipelineIdentity: CodeMapPipelineIdentity {
        sourceExpectation.pipelineIdentity
    }
}

private enum WorkspaceCodemapSourceExpectationStorage: Hashable {
    case cleanGitBlob(
        locatorIdentity: GitBlobCodeMapLocatorIdentity,
        sourceAuthority: WorkspaceCodemapSourceAuthorityToken
    )
    case validatedWorktree(
        validationToken: CodeMapSourceValidationToken,
        expectedArtifactKey: CodeMapArtifactKey,
        classificationReason: GitBlobValidatedWorktreeReason,
        sourceAuthority: WorkspaceCodemapSourceAuthorityToken
    )
}

struct WorkspaceCodemapSourceExpectation: Hashable {
    fileprivate let storage: WorkspaceCodemapSourceExpectationStorage
    fileprivate let bindingIdentity: WorkspaceCodemapArtifactBindingIdentity

    private init(
        storage: WorkspaceCodemapSourceExpectationStorage,
        bindingIdentity: WorkspaceCodemapArtifactBindingIdentity
    ) {
        self.storage = storage
        self.bindingIdentity = bindingIdentity
    }

    static func cleanGitBlob(
        bindingIdentity: WorkspaceCodemapArtifactBindingIdentity,
        locatorIdentity: GitBlobCodeMapLocatorIdentity,
        sourceAuthority: WorkspaceCodemapSourceAuthorityToken
    ) -> WorkspaceCodemapSourceExpectation? {
        guard sourceAuthority.isBound(to: bindingIdentity),
              locatorIdentity.repositoryNamespace == sourceAuthority.repositoryAuthority.repositoryNamespace,
              locatorIdentity.objectFormat == sourceAuthority.repositoryAuthority.objectFormat
        else { return nil }
        return WorkspaceCodemapSourceExpectation(
            storage: .cleanGitBlob(
                locatorIdentity: locatorIdentity,
                sourceAuthority: sourceAuthority
            ),
            bindingIdentity: bindingIdentity
        )
    }

    static func validatedWorktree(
        bindingIdentity: WorkspaceCodemapArtifactBindingIdentity,
        source: CodeMapSourceSnapshot,
        expectedArtifactKey: CodeMapArtifactKey,
        classificationReason: GitBlobValidatedWorktreeReason,
        sourceAuthority: WorkspaceCodemapSourceAuthorityToken
    ) -> WorkspaceCodemapSourceExpectation? {
        guard sourceAuthority.isBound(to: bindingIdentity),
              case let .validatedWorktree(validationToken) = source.provenance,
              source.rawSHA256 == expectedArtifactKey.rawSHA256,
              UInt64(source.rawByteCount) == expectedArtifactKey.rawByteCount
        else { return nil }
        return WorkspaceCodemapSourceExpectation(
            storage: .validatedWorktree(
                validationToken: validationToken,
                expectedArtifactKey: expectedArtifactKey,
                classificationReason: classificationReason,
                sourceAuthority: sourceAuthority
            ),
            bindingIdentity: bindingIdentity
        )
    }

    var isFactoryValidated: Bool {
        guard sourceAuthority.isBound(to: bindingIdentity) else { return false }
        switch storage {
        case let .cleanGitBlob(locatorIdentity, authority):
            return locatorIdentity.repositoryNamespace == authority.repositoryAuthority.repositoryNamespace &&
                locatorIdentity.objectFormat == authority.repositoryAuthority.objectFormat
        case .validatedWorktree:
            return true
        }
    }

    var sourceAuthority: WorkspaceCodemapSourceAuthorityToken {
        switch storage {
        case let .cleanGitBlob(_, authority),
             let .validatedWorktree(_, _, _, authority): authority
        }
    }

    var pipelineIdentity: CodeMapPipelineIdentity {
        switch storage {
        case let .cleanGitBlob(locatorIdentity, _):
            locatorIdentity.pipelineIdentity
        case let .validatedWorktree(_, artifactKey, _, _):
            artifactKey.pipelineIdentity
        }
    }
}

struct WorkspaceCodemapArtifactCompletion: Equatable {
    let token: WorkspaceCodemapArtifactRequestToken
    let artifactKey: CodeMapArtifactKey
    let language: LanguageType
    let rawSHA256: CodeMapRawSourceDigest
    let sourceProof: WorkspaceCodemapSourceExpectation
    let outcome: CodeMapSyntaxArtifactOutcome
    fileprivate let cleanBlobAssociation: VerifiedGitBlobCodeMapLocatorAssociation?

    var verifiedCleanAssociation: VerifiedGitBlobCodeMapLocatorAssociation? {
        cleanBlobAssociation
    }

    private init(
        token: WorkspaceCodemapArtifactRequestToken,
        artifactKey: CodeMapArtifactKey,
        language: LanguageType,
        rawSHA256: CodeMapRawSourceDigest,
        sourceProof: WorkspaceCodemapSourceExpectation,
        outcome: CodeMapSyntaxArtifactOutcome,
        cleanBlobAssociation: VerifiedGitBlobCodeMapLocatorAssociation?
    ) {
        self.token = token
        self.artifactKey = artifactKey
        self.language = language
        self.rawSHA256 = rawSHA256
        self.sourceProof = sourceProof
        self.outcome = outcome
        self.cleanBlobAssociation = cleanBlobAssociation
    }

    static func validatedWorktree(
        token: WorkspaceCodemapArtifactRequestToken,
        language: LanguageType,
        outcome: CodeMapSyntaxArtifactOutcome
    ) -> Self? {
        guard token.isFactoryValidated,
              case let .validatedWorktree(_, artifactKey, _, _) = token.sourceExpectation.storage,
              language.codeMapPipelineLanguageID == artifactKey.pipelineIdentity.languageID
        else { return nil }
        return Self(
            token: token,
            artifactKey: artifactKey,
            language: language,
            rawSHA256: artifactKey.rawSHA256,
            sourceProof: token.sourceExpectation,
            outcome: outcome,
            cleanBlobAssociation: nil
        )
    }

    static func cleanGitBlob(
        token: WorkspaceCodemapArtifactRequestToken,
        language: LanguageType,
        association: VerifiedGitBlobCodeMapLocatorAssociation
    ) -> Self? {
        guard token.isFactoryValidated,
              case let .cleanGitBlob(locatorIdentity, _) = token.sourceExpectation.storage,
              association.identity == locatorIdentity,
              language.codeMapPipelineLanguageID == association.artifactKey.pipelineIdentity.languageID
        else { return nil }
        return Self(
            token: token,
            artifactKey: association.artifactKey,
            language: language,
            rawSHA256: association.artifactKey.rawSHA256,
            sourceProof: token.sourceExpectation,
            outcome: association.outcome,
            cleanBlobAssociation: association
        )
    }
}

enum WorkspaceCodemapArtifactBindingAvailability: Equatable {
    case pending(WorkspaceCodemapArtifactRequestToken)
    case unsupported(fileExtension: String)
    case resolved(WorkspaceCodemapArtifactCompletion)
}

enum WorkspaceCodemapArtifactCompletionDisposition: Equatable {
    case accepted
    case exactDuplicate
    case notPending
    case rootIDMismatch
    case rootLifetimeIDMismatch
    case fileIDMismatch
    case rootPathMismatch
    case relativePathMismatch
    case fullPathMismatch
    case requestGenerationMismatch
    case catalogGenerationMismatch
    case repositoryAuthorityMismatch
    case unvalidatedSourceAuthority
    case sourceAuthorityRootEpochMismatch
    case sourceAuthorityPathMismatch
    case sourceAuthorityPathGenerationMismatch
    case sourceAuthorityIngressGenerationMismatch
    case sourceExpectationMismatch
    case sourceProofMismatch
    case sourceValidationTokenMismatch
    case expectedArtifactKeyMismatch
    case cleanBlobResolutionProofMissing
    case cleanBlobRepositoryNamespaceMismatch
    case cleanBlobObjectFormatMismatch
    case cleanBlobOIDMismatch
    case cleanBlobPipelineMismatch
    case cleanBlobArtifactKeyMismatch
    case cleanBlobOutcomeMismatch
    case artifactKeyMismatch
    case languageMismatch
    case rawDigestMismatch
}

struct WorkspaceCodemapArtifactBinding: Equatable {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    private(set) var availability: WorkspaceCodemapArtifactBindingAvailability

    init?(pending token: WorkspaceCodemapArtifactRequestToken) {
        guard token.isFactoryValidated else { return nil }
        identity = token.identity
        availability = .pending(token)
    }

    init(
        identity: WorkspaceCodemapArtifactBindingIdentity,
        unsupportedFileExtension: String
    ) {
        self.identity = identity
        availability = .unsupported(fileExtension: unsupportedFileExtension)
    }

    mutating func apply(
        _ completion: WorkspaceCodemapArtifactCompletion
    ) -> WorkspaceCodemapArtifactCompletionDisposition {
        guard case let .pending(expectedToken) = availability else {
            if case let .resolved(currentCompletion) = availability,
               currentCompletion == completion
            {
                return .exactDuplicate
            }
            return .notPending
        }
        guard expectedToken.isFactoryValidated,
              completion.token.isFactoryValidated,
              completion.sourceProof.isFactoryValidated
        else { return .unvalidatedSourceAuthority }

        let receivedIdentity = completion.token.identity
        guard receivedIdentity.rootID == identity.rootID,
              receivedIdentity.rootID == expectedToken.identity.rootID
        else { return .rootIDMismatch }
        guard receivedIdentity.rootLifetimeID == identity.rootLifetimeID,
              receivedIdentity.rootLifetimeID == expectedToken.identity.rootLifetimeID
        else { return .rootLifetimeIDMismatch }
        guard receivedIdentity.fileID == identity.fileID,
              receivedIdentity.fileID == expectedToken.identity.fileID
        else { return .fileIDMismatch }
        guard receivedIdentity.standardizedRootPath == identity.standardizedRootPath,
              receivedIdentity.standardizedRootPath == expectedToken.identity.standardizedRootPath
        else { return .rootPathMismatch }
        guard receivedIdentity.standardizedRelativePath == identity.standardizedRelativePath,
              receivedIdentity.standardizedRelativePath == expectedToken.identity.standardizedRelativePath
        else { return .relativePathMismatch }
        guard receivedIdentity.standardizedFullPath == identity.standardizedFullPath,
              receivedIdentity.standardizedFullPath == expectedToken.identity.standardizedFullPath
        else { return .fullPathMismatch }
        guard completion.token.requestGeneration == expectedToken.requestGeneration else {
            return .requestGenerationMismatch
        }
        guard completion.token.catalogGeneration == expectedToken.catalogGeneration else {
            return .catalogGenerationMismatch
        }
        if let mismatch = Self.expectationMismatch(
            received: completion.token.sourceExpectation,
            expected: expectedToken.sourceExpectation
        ) {
            return mismatch
        }
        guard completion.sourceProof == completion.token.sourceExpectation else {
            return .sourceProofMismatch
        }
        switch expectedToken.sourceExpectation.storage {
        case let .cleanGitBlob(locatorIdentity, _):
            guard let association = completion.cleanBlobAssociation else {
                return .cleanBlobResolutionProofMissing
            }
            guard association.identity.repositoryNamespace == locatorIdentity.repositoryNamespace else {
                return .cleanBlobRepositoryNamespaceMismatch
            }
            guard association.identity.objectFormat == locatorIdentity.objectFormat else {
                return .cleanBlobObjectFormatMismatch
            }
            guard association.identity.blobOID == locatorIdentity.blobOID else {
                return .cleanBlobOIDMismatch
            }
            guard association.identity.pipelineIdentity == locatorIdentity.pipelineIdentity,
                  association.artifactKey.pipelineIdentity == locatorIdentity.pipelineIdentity
            else {
                return .cleanBlobPipelineMismatch
            }
            guard association.artifactKey.rawSHA256 == completion.artifactKey.rawSHA256 else {
                return .rawDigestMismatch
            }
            guard association.artifactKey.rawByteCount == completion.artifactKey.rawByteCount else {
                return .cleanBlobArtifactKeyMismatch
            }
            guard association.artifactKey == completion.artifactKey else {
                return .cleanBlobArtifactKeyMismatch
            }
            guard association.outcome == completion.outcome else {
                return .cleanBlobOutcomeMismatch
            }
        case let .validatedWorktree(_, expectedArtifactKey, _, _):
            guard completion.cleanBlobAssociation == nil,
                  completion.artifactKey == expectedArtifactKey
            else {
                return .artifactKeyMismatch
            }
        }
        guard completion.language.codeMapPipelineLanguageID == completion.artifactKey.pipelineIdentity.languageID else {
            return .languageMismatch
        }
        guard completion.rawSHA256 == completion.artifactKey.rawSHA256 else {
            return .rawDigestMismatch
        }

        availability = .resolved(completion)
        return .accepted
    }

    private static func expectationMismatch(
        received: WorkspaceCodemapSourceExpectation,
        expected: WorkspaceCodemapSourceExpectation
    ) -> WorkspaceCodemapArtifactCompletionDisposition? {
        let receivedAuthority = received.sourceAuthority
        let expectedAuthority = expected.sourceAuthority
        guard receivedAuthority.repositoryAuthority == expectedAuthority.repositoryAuthority else {
            return .repositoryAuthorityMismatch
        }
        guard receivedAuthority.rootEpoch == expectedAuthority.rootEpoch else {
            return .sourceAuthorityRootEpochMismatch
        }
        guard receivedAuthority.standardizedRepositoryRelativePath ==
            expectedAuthority.standardizedRepositoryRelativePath
        else {
            return .sourceAuthorityPathMismatch
        }
        guard receivedAuthority.pathGeneration == expectedAuthority.pathGeneration else {
            return .sourceAuthorityPathGenerationMismatch
        }
        guard receivedAuthority.ingressGeneration == expectedAuthority.ingressGeneration else {
            return .sourceAuthorityIngressGenerationMismatch
        }

        switch (received.storage, expected.storage) {
        case let (
            .cleanGitBlob(receivedLocator, _),
            .cleanGitBlob(expectedLocator, _)
        ):
            return receivedLocator == expectedLocator ? nil : .sourceExpectationMismatch
        case let (
            .validatedWorktree(receivedValidation, receivedKey, receivedReason, _),
            .validatedWorktree(expectedValidation, expectedKey, expectedReason, _)
        ):
            guard receivedValidation == expectedValidation else { return .sourceValidationTokenMismatch }
            guard receivedKey == expectedKey else { return .expectedArtifactKeyMismatch }
            return receivedReason == expectedReason ? nil : .sourceExpectationMismatch
        default:
            return .sourceExpectationMismatch
        }
    }
}

private extension WorkspaceCodemapSourceAuthorityToken {
    func isBound(to identity: WorkspaceCodemapArtifactBindingIdentity) -> Bool {
        guard isFactoryValidated,
              rootEpoch.rootID == identity.rootID,
              rootEpoch.rootLifetimeID == identity.rootLifetimeID
        else { return false }
        let expectedRepositoryRelativePath = if repositoryRelativeLoadedRootPrefix.isEmpty {
            identity.standardizedRelativePath
        } else {
            repositoryRelativeLoadedRootPrefix + "/" + identity.standardizedRelativePath
        }
        return standardizedRepositoryRelativePath == expectedRepositoryRelativePath
    }
}

struct WorkspaceCodemapArtifactRenderedCodemap: Equatable {
    let text: String
    let tokenCount: Int
}

struct WorkspaceCodemapArtifactPresentation: Equatable {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let displayPath: String
    let completion: WorkspaceCodemapArtifactCompletion

    func renderedCodemap() -> WorkspaceCodemapArtifactRenderedCodemap? {
        guard completion.token.identity == identity,
              completion.sourceProof == completion.token.sourceExpectation,
              completion.language.codeMapPipelineLanguageID == completion.artifactKey.pipelineIdentity.languageID,
              completion.rawSHA256 == completion.artifactKey.rawSHA256,
              case let .ready(artifact) = completion.outcome
        else { return nil }

        let text = CodeMapAPIContentFormatter.pathAndImportsBlock(
            displayPath: displayPath,
            imports: artifact.imports
        ) + artifact.apiDescription
        return WorkspaceCodemapArtifactRenderedCodemap(
            text: text,
            tokenCount: TokenCalculationService.estimateTokens(for: text)
        )
    }
}

private extension LanguageType {
    var codeMapPipelineLanguageID: CodeMapPipelineLanguageID {
        switch self {
        case .swift: .swift
        case .js: .javascript
        case .c_sharp: .cSharp
        case .python: .python
        case .c: .c
        case .rust: .rust
        case .cpp: .cpp
        case .go: .go
        case .java: .java
        case .dart: .dart
        case .ts: .typescript
        case .tsx: .tsx
        case .php: .php
        case .ruby: .ruby
        }
    }
}
