import Foundation

package enum PromptAuthorizedArtifactKind: String, Equatable {
    case map
    case patch
}

package enum PromptAuthorizedArtifactReadability: Equatable {
    case readable
    case empty
}

package enum PromptAuthorizedArtifactCheckoutKind: String, Equatable {
    case canonical
    case linkedWorktree
}

/// Safe, path-free checkout identity copied only after app-owned authorization succeeds.
package struct PromptAuthorizedArtifactProvenance: Equatable {
    package let repoKey: String
    package let repositoryID: String
    package let worktreeID: String
    package let checkoutKind: PromptAuthorizedArtifactCheckoutKind

    package init(
        repoKey: String,
        repositoryID: String,
        worktreeID: String,
        checkoutKind: PromptAuthorizedArtifactCheckoutKind
    ) {
        self.repoKey = repoKey
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
        self.checkoutKind = checkoutKind
    }
}

package enum PromptAuthorizedArtifactRejectionCode: String, Equatable {
    case invalidAbsolutePath
    case outsideWorkspaceGitData
    case capabilityRootUnavailable
    case notCataloged
    case unsupportedArtifactPath
    case manifestNotCataloged
    case manifestUnreadable
    case manifestInvalid
    case manifestIdentityMismatch
    case tabMismatch
    case legacyTabNotAllowed
    case repositoryProvenanceMissing
    case checkoutProvenanceMismatch
    case unlistedPatch
    case contentUnreadable
    case notInDelegatedSelection
    case delegationConsumerMismatch
    case delegationWorkspaceMismatch
    case legacyArtifactNotDelegable
    case delegationBindingMismatch
}

package enum PromptAuthorizedArtifactDispositionStatus: Equatable {
    case authorized(kind: PromptAuthorizedArtifactKind, readability: PromptAuthorizedArtifactReadability)
    case rejected(PromptAuthorizedArtifactRejectionCode)
}

/// Path-free authorization evidence retained beside the payload so Core never needs to
/// rediscover authority or infer why a selected artifact was omitted.
package struct PromptAuthorizedArtifactDisposition: Equatable {
    package let artifactID: UUID?
    package let displayAlias: String
    package let provenance: PromptAuthorizedArtifactProvenance?
    package let status: PromptAuthorizedArtifactDispositionStatus

    package init(
        artifactID: UUID?,
        displayAlias: String,
        provenance: PromptAuthorizedArtifactProvenance?,
        status: PromptAuthorizedArtifactDispositionStatus
    ) {
        self.artifactID = artifactID
        self.displayAlias = displayAlias
        self.provenance = provenance
        self.status = status
    }
}

/// Capability-free bytes produced only after app-owned authorization has completed.
package struct PromptAuthorizedArtifactPayload: Equatable {
    package let artifactID: UUID
    package let displayAlias: String
    package let kind: PromptAuthorizedArtifactKind
    package let readability: PromptAuthorizedArtifactReadability
    package let provenance: PromptAuthorizedArtifactProvenance
    package let content: String

    package init(
        artifactID: UUID,
        displayAlias: String,
        kind: PromptAuthorizedArtifactKind,
        readability: PromptAuthorizedArtifactReadability,
        provenance: PromptAuthorizedArtifactProvenance,
        content: String
    ) {
        self.artifactID = artifactID
        self.displayAlias = displayAlias
        self.kind = kind
        self.readability = readability
        self.provenance = provenance
        self.content = content
    }
}

package struct PromptAuthorizedArtifactBatch: Equatable {
    package let payloads: [PromptAuthorizedArtifactPayload]
    package let dispositions: [PromptAuthorizedArtifactDisposition]
    package let consumedSelectionPaths: Set<String>

    package init(
        payloads: [PromptAuthorizedArtifactPayload],
        dispositions: [PromptAuthorizedArtifactDisposition],
        consumedSelectionPaths: Set<String>
    ) {
        self.payloads = payloads
        self.dispositions = dispositions
        self.consumedSelectionPaths = consumedSelectionPaths
    }

    package static let empty = PromptAuthorizedArtifactBatch(
        payloads: [],
        dispositions: [],
        consumedSelectionPaths: []
    )
}

package enum PromptAuthorizedArtifactAliasValidation {
    package static func isSafe(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
