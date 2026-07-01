import CryptoKit
import Darwin
import Foundation

enum GitBlobIdentityError: LocalizedError, Equatable {
    case invalidRelativePath
    case invalidObjectFormat(String)
    case invalidOID
    case malformedGitOutput(String)
    case batchTooLarge
    case unsupportedGit(String)

    var errorDescription: String? {
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
        }
    }
}

enum GitBlobObjectReadError: Error, Equatable {
    case unavailable
    case malformedSize
    case stdoutLimitExceeded
    case stderrLimitExceeded
}

enum GitObjectFormat: String, Codable, Hashable {
    case sha1
    case sha256

    var oidHexCount: Int {
        switch self {
        case .sha1: 40
        case .sha256: 64
        }
    }

    init(gitValue: String) throws {
        guard let value = Self(rawValue: gitValue) else {
            throw GitBlobIdentityError.invalidObjectFormat(gitValue)
        }
        self = value
    }
}

struct GitBlobOID: Codable, Hashable {
    let objectFormat: GitObjectFormat
    let lowercaseHex: String

    init(objectFormat: GitObjectFormat, lowercaseHex: String) throws {
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

    static func blob(bytes: Data, objectFormat: GitObjectFormat) -> GitBlobOID {
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

struct GitBlobIndexEntry: Equatable {
    let mode: String
    let oid: String
    let stage: Int
    let path: String
    let assumeUnchanged: Bool
    let skipWorktree: Bool

    var isRegularFile: Bool {
        mode == "100644" || mode == "100755"
    }

    var isSymlink: Bool {
        mode == "120000"
    }

    var isGitlink: Bool {
        mode == "160000"
    }
}

enum GitPorcelainV2RecordKind: Equatable {
    case ordinary
    case renamedOrCopied(originalPath: String, score: String)
    case unmerged
    case untracked
    case ignored
}

struct GitPorcelainV2PathRecord: Equatable {
    let kind: GitPorcelainV2RecordKind
    let path: String
    let indexStatus: Character?
    let workTreeStatus: Character?
    let submoduleState: String?
    let headMode: String?
    let indexMode: String?
    let workTreeMode: String?
    let headOID: String?
    let indexOID: String?
    let conflictStage1Mode: String?
    let conflictStage2Mode: String?
    let conflictStage3Mode: String?
    let conflictStage1OID: String?
    let conflictStage2OID: String?
    let conflictStage3OID: String?

    var hasIndexChange: Bool {
        guard let indexStatus else { return false }
        return indexStatus != "." && indexStatus != "?"
    }

    var hasWorkTreeChange: Bool {
        guard let workTreeStatus else { return false }
        return workTreeStatus != "." && workTreeStatus != "?"
    }
}

enum GitAttributeState: Equatable {
    case unspecified
    case unset
    case set(String)

    var semanticValue: String {
        switch self {
        case .unspecified: "u"
        case .unset: "n"
        case let .set(value): "s:\(value)"
        }
    }
}

struct GitBlobPathAttributes: Equatable {
    let text: GitAttributeState
    let eol: GitAttributeState
    let filter: GitAttributeState
    let ident: GitAttributeState
    let workingTreeEncoding: GitAttributeState

    static let unspecified = GitBlobPathAttributes(
        text: .unspecified,
        eol: .unspecified,
        filter: .unspecified,
        ident: .unspecified,
        workingTreeEncoding: .unspecified
    )
}

struct GitBlobCheckoutConfiguration: Equatable {
    let coreAutoCRLF: String?
    let coreEOL: String?
    let filterDriverConfiguration: [String: String]
}

struct GitCodemapAuthorityConfiguration: Equatable {
    let checkout: GitBlobCheckoutConfiguration
    let attributesFilePath: String?
    let sparseCheckoutEnabled: Bool
    let sparseCheckoutConeEnabled: Bool
}

enum GitBlobCheckoutTransformReason: String, Codable, CaseIterable {
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

enum GitBlobCheckoutMaterialization: Equatable {
    case bytePreserving
    case requiresValidatedWorktreeBytes([GitBlobCheckoutTransformReason])
}

struct GitBlobLStatFingerprint: Codable, Equatable, Hashable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    var isRegularFile: Bool {
        (mode & UInt16(S_IFMT)) == UInt16(S_IFREG)
    }

    var isSymbolicLink: Bool {
        (mode & UInt16(S_IFMT)) == UInt16(S_IFLNK)
    }
}

struct GitBlobRepositoryValidationToken: Equatable {
    let indexFingerprint: GitBlobLStatFingerprint?
    let layoutSHA256: String
    let metadataSHA256: String
    let semanticSHA256: String
}

struct GitBlobValidationTokens: Equatable {
    let preRepository: GitBlobRepositoryValidationToken?
    let postRepository: GitBlobRepositoryValidationToken?
    let preWorktree: GitBlobLStatFingerprint?
    let postWorktree: GitBlobLStatFingerprint?

    var isStable: Bool {
        preRepository == postRepository && preWorktree == postWorktree
    }
}

enum GitBlobValidatedWorktreeReason: String, Codable, Hashable {
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
    case generatedOrExplicit
}

enum GitBlobUnavailableReason: String, Codable {
    case missing
    case sparseAbsent
    case repositoryUnavailable
}

enum GitBlobSecurityExclusionReason: String, Codable {
    case symlinkLeaf
    case symlinkPathComponent
}

enum GitBlobUnsupportedReason: String, Codable {
    case gitlink
    case nonRegularFile
    case unsupportedGit
    case invalidObjectFormat
    case invalidPath
    case unknownIndexMode
}

enum GitBlobIdentityOutcome: Equatable {
    case oidEligible(GitBlobOID)
    case requiresValidatedWorktreeBytes(GitBlobValidatedWorktreeReason)
    case unavailable(GitBlobUnavailableReason)
    case securityExcluded(GitBlobSecurityExclusionReason)
    case unsupported(GitBlobUnsupportedReason)
}

struct GitBlobIdentityClassification: Equatable {
    let relativePath: String
    let repositoryRelativePath: String?
    let objectFormat: GitObjectFormat?
    let indexEntries: [GitBlobIndexEntry]
    let porcelainRecord: GitPorcelainV2PathRecord?
    let intentToAdd: Bool
    let hasConflictStages: Bool
    let skipWorktree: Bool
    let assumeUnchanged: Bool
    let attributes: GitBlobPathAttributes?
    let checkoutConfiguration: GitBlobCheckoutConfiguration?
    let checkoutMaterialization: GitBlobCheckoutMaterialization?
    let validationTokens: GitBlobValidationTokens
    let outcome: GitBlobIdentityOutcome
}

struct GitBlobIdentityBatch: Equatable {
    let objectFormat: GitObjectFormat?
    let classifications: [GitBlobIdentityClassification]
    let retriedAfterInstability: Bool
    let failure: GitBlobIdentityError?

    init(
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

struct GitBlobShadowDiagnostics: Equatable {
    let eligibleOpportunityCount: UInt64
    let digestMatchCount: UInt64
    let digestMismatchCount: UInt64
}

enum GitBlobShadowValidationResult: Equatable {
    case notEligible
    case match
    case mismatch
}
