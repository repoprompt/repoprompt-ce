import CryptoKit
import Darwin
import Foundation

package enum GitBlobIdentityError: LocalizedError, Equatable {
    case invalidRelativePath
    case invalidObjectFormat(String)
    case invalidOID
    case malformedGitOutput(String)
    case batchTooLarge
    case unsupportedGit(String)
    /// A filesystem root's non-Git proof could not be re-established for this batch. Transient by
    /// construction: it means "classify again later", not "this root is an unsupported Git root".
    case filesystemProofUnavailable

    package var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            "Git blob identity requires a standardized relative path."
        case let .invalidObjectFormat(value):
            "Unsupported Git object format: \(value)"
        case .invalidOID:
            "Invalid Git object ID."
        case let .malformedGitOutput(detail):
            "Malformed Git identity output: \(detail)"
        case .batchTooLarge:
            "Git blob identity batch exceeds the bounded request policy."
        case let .unsupportedGit(detail):
            "Git does not support the required identity operation: \(detail)"
        case .filesystemProofUnavailable:
            "The filesystem root proof required for process-free classification is unavailable."
        }
    }
}

package enum GitBlobObjectReadError: Error, Equatable {
    case unavailable
    case malformedSize
    case stdoutLimitExceeded
    case stderrLimitExceeded
}

public enum GitObjectFormat: String, Codable, Hashable, Sendable {
    case sha1
    case sha256

    public var oidHexCount: Int {
        switch self {
        case .sha1: 40
        case .sha256: 64
        }
    }

    public init(gitValue: String) throws {
        guard let value = Self(rawValue: gitValue) else {
            throw GitBlobIdentityError.invalidObjectFormat(gitValue)
        }
        self = value
    }
}

public struct GitBlobOID: Codable, Hashable, Sendable {
    public let objectFormat: GitObjectFormat
    public let lowercaseHex: String

    public init(objectFormat: GitObjectFormat, lowercaseHex: String) throws {
        guard lowercaseHex.count == objectFormat.oidHexCount,
              lowercaseHex.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                      (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
              })
        else {
            throw GitBlobIdentityError.invalidOID
        }
        self.objectFormat = objectFormat
        self.lowercaseHex = lowercaseHex
    }

    public static func blob(bytes: Data, objectFormat: GitObjectFormat) -> GitBlobOID {
        var canonical = Data("blob \(bytes.count)\0".utf8)
        canonical.append(bytes)
        let digest = switch objectFormat {
        case .sha1: Data(Insecure.SHA1.hash(data: canonical))
        case .sha256: Data(SHA256.hash(data: canonical))
        }
        return try! GitBlobOID(
            objectFormat: objectFormat,
            lowercaseHex: digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}

package struct GitBlobIndexEntry: Equatable {
    package let mode: String
    package let oid: String
    package let stage: Int
    package let path: String
    package let assumeUnchanged: Bool
    package let skipWorktree: Bool

    package var isRegularFile: Bool {
        mode == "100644" || mode == "100755"
    }

    package var isSymlink: Bool {
        mode == "120000"
    }

    package var isGitlink: Bool {
        mode == "160000"
    }

    package init(
        mode: String,
        oid: String,
        stage: Int,
        path: String,
        assumeUnchanged: Bool,
        skipWorktree: Bool
    ) {
        self.mode = mode
        self.oid = oid
        self.stage = stage
        self.path = path
        self.assumeUnchanged = assumeUnchanged
        self.skipWorktree = skipWorktree
    }
}

package enum GitPorcelainV2RecordKind: Equatable {
    case ordinary
    case renamedOrCopied(originalPath: String, score: String)
    case unmerged
    case untracked
    case ignored
}

package struct GitPorcelainV2PathRecord: Equatable {
    package let kind: GitPorcelainV2RecordKind
    package let path: String
    package let indexStatus: Character?
    package let workTreeStatus: Character?
    package let submoduleState: String?
    package let headMode: String?
    package let indexMode: String?
    package let workTreeMode: String?
    package let headOID: String?
    package let indexOID: String?
    package let conflictStage1Mode: String?
    package let conflictStage2Mode: String?
    package let conflictStage3Mode: String?
    package let conflictStage1OID: String?
    package let conflictStage2OID: String?
    package let conflictStage3OID: String?

    package var hasIndexChange: Bool {
        guard let indexStatus else { return false }
        return indexStatus != "." && indexStatus != "?"
    }

    package var hasWorkTreeChange: Bool {
        guard let workTreeStatus else { return false }
        return workTreeStatus != "." && workTreeStatus != "?"
    }

    package init(
        kind: GitPorcelainV2RecordKind,
        path: String,
        indexStatus: Character? = nil,
        workTreeStatus: Character? = nil,
        submoduleState: String? = nil,
        headMode: String? = nil,
        indexMode: String? = nil,
        workTreeMode: String? = nil,
        headOID: String? = nil,
        indexOID: String? = nil,
        conflictStage1Mode: String? = nil,
        conflictStage2Mode: String? = nil,
        conflictStage3Mode: String? = nil,
        conflictStage1OID: String? = nil,
        conflictStage2OID: String? = nil,
        conflictStage3OID: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.submoduleState = submoduleState
        self.headMode = headMode
        self.indexMode = indexMode
        self.workTreeMode = workTreeMode
        self.headOID = headOID
        self.indexOID = indexOID
        self.conflictStage1Mode = conflictStage1Mode
        self.conflictStage2Mode = conflictStage2Mode
        self.conflictStage3Mode = conflictStage3Mode
        self.conflictStage1OID = conflictStage1OID
        self.conflictStage2OID = conflictStage2OID
        self.conflictStage3OID = conflictStage3OID
    }
}

package enum GitAttributeState: Equatable {
    case unspecified
    case unset
    case set(String)

    package var semanticValue: String {
        switch self {
        case .unspecified: "u"
        case .unset: "n"
        case let .set(value): "s:\(value)"
        }
    }
}

package struct GitBlobPathAttributes: Equatable {
    package let text: GitAttributeState
    package let eol: GitAttributeState
    package let filter: GitAttributeState
    package let ident: GitAttributeState
    package let workingTreeEncoding: GitAttributeState

    package static let unspecified = GitBlobPathAttributes(
        text: .unspecified,
        eol: .unspecified,
        filter: .unspecified,
        ident: .unspecified,
        workingTreeEncoding: .unspecified
    )

    package init(
        text: GitAttributeState,
        eol: GitAttributeState,
        filter: GitAttributeState,
        ident: GitAttributeState,
        workingTreeEncoding: GitAttributeState
    ) {
        self.text = text
        self.eol = eol
        self.filter = filter
        self.ident = ident
        self.workingTreeEncoding = workingTreeEncoding
    }
}

package struct GitBlobCheckoutConfiguration: Equatable {
    package let coreAutoCRLF: String?
    package let coreEOL: String?
    package let filterDriverConfiguration: [String: String]

    package init(
        coreAutoCRLF: String? = nil,
        coreEOL: String? = nil,
        filterDriverConfiguration: [String: String]
    ) {
        self.coreAutoCRLF = coreAutoCRLF
        self.coreEOL = coreEOL
        self.filterDriverConfiguration = filterDriverConfiguration
    }
}

package struct GitCodemapAuthorityConfiguration: Equatable {
    package let checkout: GitBlobCheckoutConfiguration
    package let attributesFilePath: String?
    package let sparseCheckoutEnabled: Bool
    package let sparseCheckoutConeEnabled: Bool

    package init(
        checkout: GitBlobCheckoutConfiguration,
        attributesFilePath: String? = nil,
        sparseCheckoutEnabled: Bool,
        sparseCheckoutConeEnabled: Bool
    ) {
        self.checkout = checkout
        self.attributesFilePath = attributesFilePath
        self.sparseCheckoutEnabled = sparseCheckoutEnabled
        self.sparseCheckoutConeEnabled = sparseCheckoutConeEnabled
    }
}

package enum GitBlobCheckoutTransformReason: String, Codable, CaseIterable {
    case textAttribute
    case eolAttribute
    case coreAutoCRLF
    case coreEOL
    case filterAttribute
    case lfsFilter
    case identAttribute
    case workingTreeEncoding
    case unknownFilterDriver
}

package enum GitBlobCheckoutMaterialization: Equatable {
    case bytePreserving
    case requiresValidatedWorktreeBytes([GitBlobCheckoutTransformReason])
}

package struct GitBlobLStatFingerprint: Codable, Equatable, Hashable {
    package let device: UInt64
    package let inode: UInt64
    package let mode: UInt16
    package let size: Int64
    package let modificationSeconds: Int64
    package let modificationNanoseconds: Int64
    package let changeSeconds: Int64
    package let changeNanoseconds: Int64

    package var isRegularFile: Bool {
        (mode & UInt16(S_IFMT)) == UInt16(S_IFREG)
    }

    package var isSymbolicLink: Bool {
        (mode & UInt16(S_IFMT)) == UInt16(S_IFLNK)
    }

    package init(
        device: UInt64,
        inode: UInt64,
        mode: UInt16,
        size: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        changeSeconds: Int64,
        changeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }
}

package struct GitBlobRepositoryValidationToken: Equatable {
    package let indexFingerprint: GitBlobLStatFingerprint?
    package let layoutSHA256: String
    package let metadataSHA256: String
    package let semanticSHA256: String

    package init(
        indexFingerprint: GitBlobLStatFingerprint? = nil,
        layoutSHA256: String,
        metadataSHA256: String,
        semanticSHA256: String
    ) {
        self.indexFingerprint = indexFingerprint
        self.layoutSHA256 = layoutSHA256
        self.metadataSHA256 = metadataSHA256
        self.semanticSHA256 = semanticSHA256
    }
}

package struct GitBlobValidationTokens: Equatable {
    package let preRepository: GitBlobRepositoryValidationToken?
    package let postRepository: GitBlobRepositoryValidationToken?
    package let preWorktree: GitBlobLStatFingerprint?
    package let postWorktree: GitBlobLStatFingerprint?

    package var isStable: Bool {
        preRepository == postRepository && preWorktree == postWorktree
    }

    package init(
        preRepository: GitBlobRepositoryValidationToken? = nil,
        postRepository: GitBlobRepositoryValidationToken? = nil,
        preWorktree: GitBlobLStatFingerprint? = nil,
        postWorktree: GitBlobLStatFingerprint? = nil
    ) {
        self.preRepository = preRepository
        self.postRepository = postRepository
        self.preWorktree = preWorktree
        self.postWorktree = postWorktree
    }
}

package enum GitBlobValidatedWorktreeReason: String, Codable, Hashable {
    case nonGit
    case dirty
    case stagedAndUnstaged
    case untracked
    case ignored
    case intentToAdd
    case unmerged
    case indexFlag
    case checkoutTransformation
    case changedDuringClassification
    case nestedRepository
    case generatedOrExplicit
}

package enum GitBlobUnavailableReason: String, Codable {
    case missing
    case sparseAbsent
    case repositoryUnavailable
}

package enum GitBlobSecurityExclusionReason: String, Codable {
    case symlinkLeaf
    case symlinkPathComponent
}

package enum GitBlobUnsupportedReason: String, Codable {
    case gitlink
    case nonRegularFile
    case unsupportedGit
    case invalidObjectFormat
    case invalidPath
    case unknownIndexMode
}

package enum GitBlobIdentityOutcome: Equatable {
    case oidEligible(GitBlobOID)
    case requiresValidatedWorktreeBytes(GitBlobValidatedWorktreeReason)
    case unavailable(GitBlobUnavailableReason)
    case securityExcluded(GitBlobSecurityExclusionReason)
    case unsupported(GitBlobUnsupportedReason)
}

package struct GitBlobIdentityClassification: Equatable {
    package let relativePath: String
    package let repositoryRelativePath: String?
    package let objectFormat: GitObjectFormat?
    package let indexEntries: [GitBlobIndexEntry]
    package let porcelainRecord: GitPorcelainV2PathRecord?
    package let intentToAdd: Bool
    package let hasConflictStages: Bool
    package let skipWorktree: Bool
    package let assumeUnchanged: Bool
    package let attributes: GitBlobPathAttributes?
    package let checkoutConfiguration: GitBlobCheckoutConfiguration?
    package let checkoutMaterialization: GitBlobCheckoutMaterialization?
    package let validationTokens: GitBlobValidationTokens
    package let outcome: GitBlobIdentityOutcome

    package init(
        relativePath: String,
        repositoryRelativePath: String? = nil,
        objectFormat: GitObjectFormat? = nil,
        indexEntries: [GitBlobIndexEntry],
        porcelainRecord: GitPorcelainV2PathRecord? = nil,
        intentToAdd: Bool,
        hasConflictStages: Bool,
        skipWorktree: Bool,
        assumeUnchanged: Bool,
        attributes: GitBlobPathAttributes? = nil,
        checkoutConfiguration: GitBlobCheckoutConfiguration? = nil,
        checkoutMaterialization: GitBlobCheckoutMaterialization? = nil,
        validationTokens: GitBlobValidationTokens,
        outcome: GitBlobIdentityOutcome
    ) {
        self.relativePath = relativePath
        self.repositoryRelativePath = repositoryRelativePath
        self.objectFormat = objectFormat
        self.indexEntries = indexEntries
        self.porcelainRecord = porcelainRecord
        self.intentToAdd = intentToAdd
        self.hasConflictStages = hasConflictStages
        self.skipWorktree = skipWorktree
        self.assumeUnchanged = assumeUnchanged
        self.attributes = attributes
        self.checkoutConfiguration = checkoutConfiguration
        self.checkoutMaterialization = checkoutMaterialization
        self.validationTokens = validationTokens
        self.outcome = outcome
    }
}

package struct GitBlobIdentityBatch: Equatable {
    package let objectFormat: GitObjectFormat?
    package let classifications: [GitBlobIdentityClassification]
    package let retriedAfterInstability: Bool
    package let failure: GitBlobIdentityError?

    package init(
        objectFormat: GitObjectFormat?,
        classifications: [GitBlobIdentityClassification],
        retriedAfterInstability: Bool,
        failure: GitBlobIdentityError? = nil
    ) {
        self.objectFormat = objectFormat
        self.classifications = classifications
        self.retriedAfterInstability = retriedAfterInstability
        self.failure = failure
    }
}

package struct GitBlobShadowDiagnostics: Equatable {
    package let eligibleOpportunityCount: UInt64
    package let digestMatchCount: UInt64
    package let digestMismatchCount: UInt64

    package init(
        eligibleOpportunityCount: UInt64,
        digestMatchCount: UInt64,
        digestMismatchCount: UInt64
    ) {
        self.eligibleOpportunityCount = eligibleOpportunityCount
        self.digestMatchCount = digestMatchCount
        self.digestMismatchCount = digestMismatchCount
    }
}

package enum GitBlobShadowValidationResult: Equatable {
    case notEligible
    case match
    case mismatch
}
