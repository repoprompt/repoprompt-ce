import Foundation
import RepoPromptCore

enum FrozenAuthorizedGitArtifactAdapter {
    enum Failure: Error, Equatable {
        case inconsistentAuthorization
        case unsafeDisplayAlias
    }

    static func freeze(
        _ result: SelectedGitArtifactAuthorizationResult
    ) throws -> PromptAuthorizedArtifactBatch {
        let entriesByPath = Dictionary(
            result.entries.map { ($0.file.standardizedFullPath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var payloads: [PromptAuthorizedArtifactPayload] = []
        var frozenDispositions: [PromptAuthorizedArtifactDisposition] = []

        for disposition in result.dispositions {
            let path: String = switch disposition {
            case let .authorized(value, _, _), let .rejected(value, _):
                value
            }
            let standardizedPath = StandardizedPath.absolute(path)
            guard let alias = result.displayAliasesByAbsolutePath[path]
                ?? result.displayAliasesByAbsolutePath[standardizedPath],
                isSafeAlias(alias)
            else { throw Failure.unsafeDisplayAlias }

            let provenance = result.checkoutProvenanceByAbsolutePath[path]
                ?? result.checkoutProvenanceByAbsolutePath[standardizedPath]
            let frozenProvenance = provenance.map(freezeProvenance)

            switch disposition {
            case let .authorized(_, kind, readability):
                guard let entry = entriesByPath[standardizedPath],
                      let content = entry.loadedContent,
                      let frozenProvenance
                else { throw Failure.inconsistentAuthorization }
                let frozenKind: PromptAuthorizedArtifactKind = kind == .map ? .map : .patch
                let frozenReadability: PromptAuthorizedArtifactReadability = readability == .empty ? .empty : .readable
                let payload = PromptAuthorizedArtifactPayload(
                    artifactID: entry.file.id,
                    displayAlias: alias,
                    kind: frozenKind,
                    readability: frozenReadability,
                    provenance: frozenProvenance,
                    content: content
                )
                payloads.append(payload)
                frozenDispositions.append(
                    PromptAuthorizedArtifactDisposition(
                        artifactID: entry.file.id,
                        displayAlias: alias,
                        provenance: frozenProvenance,
                        status: .authorized(kind: frozenKind, readability: frozenReadability)
                    )
                )
            case let .rejected(_, reason):
                frozenDispositions.append(
                    PromptAuthorizedArtifactDisposition(
                        artifactID: nil,
                        displayAlias: alias,
                        provenance: frozenProvenance,
                        status: .rejected(freezeRejection(reason))
                    )
                )
            }
        }

        guard payloads.count == result.entries.count else {
            throw Failure.inconsistentAuthorization
        }
        return PromptAuthorizedArtifactBatch(
            payloads: payloads,
            dispositions: frozenDispositions,
            consumedSelectionPaths: result.consumedSelectionPaths
        )
    }

    private static func isSafeAlias(_ value: String) -> Bool {
        PromptAuthorizedArtifactAliasValidation.isSafe(value)
    }

    private static func freezeProvenance(
        _ value: SelectedGitArtifactCheckoutProvenance
    ) -> PromptAuthorizedArtifactProvenance {
        PromptAuthorizedArtifactProvenance(
            repoKey: value.repoKey,
            repositoryID: value.repositoryID,
            worktreeID: value.worktreeID,
            checkoutKind: value.kind == .canonical ? .canonical : .linkedWorktree
        )
    }

    private static func freezeRejection(
        _ value: SelectedGitArtifactRejectionReason
    ) -> PromptAuthorizedArtifactRejectionCode {
        switch value {
        case .invalidAbsolutePath: .invalidAbsolutePath
        case .outsideWorkspaceGitData: .outsideWorkspaceGitData
        case .capabilityRootUnavailable: .capabilityRootUnavailable
        case .notCataloged: .notCataloged
        case .unsupportedArtifactPath: .unsupportedArtifactPath
        case .manifestNotCataloged: .manifestNotCataloged
        case .manifestUnreadable: .manifestUnreadable
        case .manifestInvalid: .manifestInvalid
        case .manifestIdentityMismatch: .manifestIdentityMismatch
        case .tabMismatch: .tabMismatch
        case .legacyTabNotAllowed: .legacyTabNotAllowed
        case .repositoryProvenanceMissing: .repositoryProvenanceMissing
        case .checkoutProvenanceMismatch: .checkoutProvenanceMismatch
        case .unlistedPatch: .unlistedPatch
        case .contentUnreadable: .contentUnreadable
        case .notInDelegatedSelection: .notInDelegatedSelection
        case .delegationConsumerMismatch: .delegationConsumerMismatch
        case .delegationWorkspaceMismatch: .delegationWorkspaceMismatch
        case .legacyArtifactNotDelegable: .legacyArtifactNotDelegable
        case .delegationBindingMismatch: .delegationBindingMismatch
        }
    }
}
