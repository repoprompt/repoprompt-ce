import Foundation
#if DEBUG
    import CryptoKit
#endif
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#else
    import Glibc
#endif

#if DEBUG
    /// Trusted operator policy validation is a composition-root capability. MCP request JSON cannot
    /// construct or install an activation: the caller must already hold a product-owned authority.
    protocol GitWorktreeRetirementOperatorPolicyAuthority: Sendable {
        func validateRetirementPolicyReceipt(
            _ receipt: Data,
            policyVersion: Int
        ) throws -> GitWorktreeRetirementPolicyValidation
    }

    struct GitWorktreeRetirementPolicyValidation: Equatable {
        let authorityID: String
        let receiptID: String
        let approvedAt: Date
    }

    enum GitWorktreeRetirementActivationInstallationError: Error, Equatable {
        case invalidReceipt
        case alreadyInstalled
    }
#endif

/// Retirement is advertised before activation so clients can discover the future contract.
/// Release builds are permanently fail-closed. Debug builds require the composition root to
/// install one validated, process-local policy receipt before any server startup can expose it.
enum GitWorktreeRetirementActivation {
    static let requiredPolicyVersion = 1

    #if DEBUG
        private struct InstalledActivation {
            let policyVersion: Int
            let receiptDigest: String
            let validation: GitWorktreeRetirementPolicyValidation
        }

        private static let lock = NSLock()
        private static var installed: InstalledActivation?
        private static var testingOverride = false
    #endif

    static var isEnabled: Bool {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            if testingOverride { return true }
            guard let installed else { return false }
            return installed.policyVersion == requiredPolicyVersion
                && !installed.receiptDigest.isEmpty
                && !installed.validation.authorityID.isEmpty
                && !installed.validation.receiptID.isEmpty
        #else
            return false
        #endif
    }

    #if DEBUG
        static func install(
            policyVersion: Int,
            receipt: Data,
            authority: any GitWorktreeRetirementOperatorPolicyAuthority
        ) throws {
            guard policyVersion == requiredPolicyVersion, !receipt.isEmpty else {
                throw GitWorktreeRetirementActivationInstallationError.invalidReceipt
            }
            let validation = try authority.validateRetirementPolicyReceipt(
                receipt,
                policyVersion: policyVersion
            )
            guard !validation.authorityID.isEmpty, !validation.receiptID.isEmpty else {
                throw GitWorktreeRetirementActivationInstallationError.invalidReceipt
            }
            let receiptDigest = SHA256.hash(data: receipt)
                .map { String(format: "%02x", $0) }
                .joined()
            lock.lock()
            defer { lock.unlock() }
            guard installed == nil else {
                throw GitWorktreeRetirementActivationInstallationError.alreadyInstalled
            }
            installed = InstalledActivation(
                policyVersion: policyVersion,
                receiptDigest: receiptDigest,
                validation: validation
            )
        }
    #endif

    static func requireEnabled() throws {
        guard isEnabled else { throw GitWorktreeRetirementError.activationRequired }
    }

    #if DEBUG
        static func setEnabledForTesting(_ enabled: Bool) {
            lock.lock()
            testingOverride = enabled
            lock.unlock()
        }

        static func resetForTesting() {
            lock.lock()
            installed = nil
            testingOverride = false
            lock.unlock()
        }
    #endif
}

struct GitWorktreeRetirementDirectoryIdentity: Equatable, Codable {
    let registeredPath: String
    let canonicalPath: String
    let device: UInt64
    let inode: UInt64

    init(path: String) throws {
        let registered = Self.lexicallyStandardizedAbsolutePath(path)
        let immutableRootCanonical = Self.replacingImmutableMacOSRootAlias(in: registered)
        try Self.rejectSymbolicLinkComponents(in: immutableRootCanonical)
        let canonical = try Self.physicalCanonicalPath(immutableRootCanonical)
        guard canonical == immutableRootCanonical else {
            throw GitWorktreeRetirementError.symlinkIdentityEvidence(registered)
        }
        var linkInfo = stat()
        guard lstat(canonical, &linkInfo) == 0 else {
            throw GitWorktreeRetirementError.missingIdentityEvidence(canonical)
        }
        guard linkInfo.st_mode & S_IFMT != S_IFLNK else {
            throw GitWorktreeRetirementError.symlinkIdentityEvidence(canonical)
        }
        var info = stat()
        guard stat(canonical, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw GitWorktreeRetirementError.missingIdentityEvidence(canonical)
        }
        registeredPath = registered
        canonicalPath = canonical
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
    }

    private static func physicalCanonicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw GitWorktreeRetirementError.missingIdentityEvidence(path)
        }
        defer { free(resolved) }
        return lexicallyStandardizedAbsolutePath(String(cString: resolved))
    }

    private static func replacingImmutableMacOSRootAlias(in path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    private static func lexicallyStandardizedAbsolutePath(_ path: String) -> String {
        var components: [String] = []
        for component in (path as NSString).pathComponents where component != "/" && component != "." {
            if component == ".." {
                _ = components.popLast()
            } else {
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func rejectSymbolicLinkComponents(in absolutePath: String) throws {
        guard absolutePath.hasPrefix("/") else {
            throw GitWorktreeRetirementError.missingIdentityEvidence(absolutePath)
        }
        var current = ""
        for component in (absolutePath as NSString).pathComponents where component != "/" {
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0 else {
                throw GitWorktreeRetirementError.missingIdentityEvidence(current)
            }
            guard info.st_mode & S_IFMT != S_IFLNK else {
                throw GitWorktreeRetirementError.symlinkIdentityEvidence(current)
            }
        }
    }
}

struct GitWorktreeRetirementCandidate: Equatable, Codable {
    let repositoryID: String
    let repositoryRoot: GitWorktreeRetirementDirectoryIdentity
    let commonGitDirectory: GitWorktreeRetirementDirectoryIdentity
    let worktreeID: String
    let registeredPath: String
    let canonicalPath: String
    let worktreeParentDirectory: GitWorktreeRetirementDirectoryIdentity
    let worktreeDirectory: GitWorktreeRetirementDirectoryIdentity
    let gitDirectoryParent: GitWorktreeRetirementDirectoryIdentity
    let gitDirectory: GitWorktreeRetirementDirectoryIdentity

    init(descriptor: GitWorktreeDescriptor) throws {
        guard !descriptor.isMain else { throw GitWorktreeRetirementError.mainWorktree }
        guard !descriptor.isPrunable else { throw GitWorktreeRetirementError.targetChanged }
        guard let mainRoot = descriptor.repository.mainWorktreeRoot,
              let gitDir = descriptor.gitDir
        else { throw GitWorktreeRetirementError.missingIdentityEvidence(descriptor.path) }

        let repositoryRootIdentity = try GitWorktreeRetirementDirectoryIdentity(path: mainRoot)
        let commonGitDirectoryIdentity = try GitWorktreeRetirementDirectoryIdentity(
            path: descriptor.repository.commonGitDir
        )
        let worktreeDirectoryIdentity = try GitWorktreeRetirementDirectoryIdentity(path: descriptor.path)
        repositoryID = descriptor.repository.repositoryID
        repositoryRoot = repositoryRootIdentity
        commonGitDirectory = commonGitDirectoryIdentity
        worktreeID = descriptor.worktreeID
        registeredPath = worktreeDirectoryIdentity.registeredPath
        canonicalPath = worktreeDirectoryIdentity.canonicalPath
        worktreeParentDirectory = try GitWorktreeRetirementDirectoryIdentity(
            path: URL(fileURLWithPath: descriptor.path).deletingLastPathComponent().path
        )
        worktreeDirectory = worktreeDirectoryIdentity
        gitDirectoryParent = try GitWorktreeRetirementDirectoryIdentity(
            path: URL(fileURLWithPath: gitDir).deletingLastPathComponent().path
        )
        gitDirectory = try GitWorktreeRetirementDirectoryIdentity(path: gitDir)
    }

    func matches(_ descriptor: GitWorktreeDescriptor) -> Bool {
        guard let current = try? Self(descriptor: descriptor) else { return false }
        return self == current
    }

    func requireCurrentPhysicalIdentity() throws {
        guard try GitWorktreeRetirementDirectoryIdentity(path: repositoryRoot.registeredPath) == repositoryRoot,
              try GitWorktreeRetirementDirectoryIdentity(path: commonGitDirectory.registeredPath) == commonGitDirectory,
              try GitWorktreeRetirementDirectoryIdentity(path: worktreeParentDirectory.registeredPath) == worktreeParentDirectory,
              try GitWorktreeRetirementDirectoryIdentity(path: worktreeDirectory.registeredPath) == worktreeDirectory,
              try GitWorktreeRetirementDirectoryIdentity(path: gitDirectoryParent.registeredPath) == gitDirectoryParent,
              try GitWorktreeRetirementDirectoryIdentity(path: gitDirectory.registeredPath) == gitDirectory
        else { throw GitWorktreeRetirementError.targetChanged }
    }

    func requireCurrentParentPhysicalIdentity() throws {
        guard try GitWorktreeRetirementDirectoryIdentity(path: repositoryRoot.registeredPath) == repositoryRoot,
              try GitWorktreeRetirementDirectoryIdentity(path: commonGitDirectory.registeredPath) == commonGitDirectory,
              try GitWorktreeRetirementDirectoryIdentity(path: worktreeParentDirectory.registeredPath)
              == worktreeParentDirectory
        else { throw GitWorktreeRetirementError.targetChanged }
        if try GitWorktreeRetirementPathInspector.requireAbsentNoFollow(
            gitDirectoryParent.registeredPath
        ) {
            return
        }
        guard try GitWorktreeRetirementDirectoryIdentity(path: gitDirectoryParent.registeredPath)
            == gitDirectoryParent
        else { throw GitWorktreeRetirementError.targetChanged }
    }

    func isStillRegistered(by descriptor: GitWorktreeDescriptor) -> Bool {
        if descriptor.worktreeID == worktreeID { return true }
        if descriptor.path == registeredPath || descriptor.path == canonicalPath { return true }
        if let identity = try? GitWorktreeRetirementDirectoryIdentity(path: descriptor.path),
           identity == worktreeDirectory
        {
            return true
        }
        guard let descriptorGitDirectory = descriptor.gitDir else { return false }
        if descriptorGitDirectory == gitDirectory.registeredPath
            || descriptorGitDirectory == gitDirectory.canonicalPath
        {
            return true
        }
        return (try? GitWorktreeRetirementDirectoryIdentity(path: descriptorGitDirectory)) == gitDirectory
    }
}

struct GitWorktreeRetirementTarget: Equatable, Codable {
    let candidate: GitWorktreeRetirementCandidate
    let branch: String?
    let registeredHead: String
    let liveHead: String
    let generation: UInt64
    let contentManifestDigest: String
    let targetDigest: String
    let locked: Bool
    let activeOperationCount: Int

    var repositoryID: String {
        candidate.repositoryID
    }

    var repositoryRoot: String {
        candidate.repositoryRoot.registeredPath
    }

    var commonGitDirectory: String {
        candidate.commonGitDirectory.canonicalPath
    }

    var worktreeID: String {
        candidate.worktreeID
    }

    var path: String {
        candidate.registeredPath
    }

    var canonicalPath: String {
        candidate.canonicalPath
    }

    var gitDir: String {
        candidate.gitDirectory.registeredPath
    }

    var head: String {
        liveHead
    }

    init(
        descriptor: GitWorktreeDescriptor,
        liveHead: String,
        generation: UInt64,
        contentManifestDigest: String,
        activeOperationCount: Int
    ) throws {
        let candidate = try GitWorktreeRetirementCandidate(descriptor: descriptor)
        guard !descriptor.isLocked, descriptor.lockReason == nil else {
            throw GitWorktreeRetirementError.lockedWorktree(descriptor.lockReason)
        }
        guard activeOperationCount == 0 else {
            throw GitWorktreeRetirementError.activeOperations(activeOperationCount)
        }
        guard let registeredHead = descriptor.head?.trimmingCharacters(in: .whitespacesAndNewlines),
              !registeredHead.isEmpty,
              registeredHead == liveHead
        else { throw GitWorktreeRetirementError.targetChanged }
        self.candidate = candidate
        branch = descriptor.branch
        self.registeredHead = registeredHead
        self.liveHead = liveHead
        self.generation = generation
        self.contentManifestDigest = contentManifestDigest
        locked = descriptor.isLocked
        self.activeOperationCount = activeOperationCount
        targetDigest = Self.digest(
            [
                candidate.repositoryID,
                candidate.repositoryRoot.canonicalPath,
                candidate.commonGitDirectory.canonicalPath,
                candidate.worktreeID,
                candidate.registeredPath,
                candidate.canonicalPath,
                candidate.gitDirectory.canonicalPath,
                descriptor.branch ?? "<detached>",
                registeredHead,
                liveHead,
                String(generation),
                contentManifestDigest,
                String(candidate.worktreeParentDirectory.device),
                String(candidate.worktreeParentDirectory.inode),
                String(candidate.worktreeDirectory.device),
                String(candidate.worktreeDirectory.inode),
                String(candidate.gitDirectoryParent.device),
                String(candidate.gitDirectoryParent.inode),
                String(candidate.gitDirectory.device),
                String(candidate.gitDirectory.inode)
            ].joined(separator: "\u{0}")
        )
    }

    func matches(_ descriptor: GitWorktreeDescriptor, liveHead: String, manifestDigest: String) -> Bool {
        guard let current = try? Self(
            descriptor: descriptor,
            liveHead: liveHead,
            generation: generation,
            contentManifestDigest: manifestDigest,
            activeOperationCount: activeOperationCount
        ) else { return false }
        return current == self
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct GitWorktreeRetirementCleanupTarget: Equatable, Codable {
    let candidate: GitWorktreeRetirementCandidate
    let branch: String?
    let registeredHead: String
    let liveHead: String
    let generation: UInt64
    let targetDigest: String
    let activeOperationCount: Int

    var repositoryID: String {
        candidate.repositoryID
    }

    var repositoryRoot: String {
        candidate.repositoryRoot.registeredPath
    }

    var worktreeID: String {
        candidate.worktreeID
    }

    var path: String {
        candidate.registeredPath
    }

    var canonicalPath: String {
        candidate.canonicalPath
    }

    init(
        descriptor: GitWorktreeDescriptor,
        liveHead: String,
        generation: UInt64,
        activeOperationCount: Int
    ) throws {
        let candidate = try GitWorktreeRetirementCandidate(descriptor: descriptor)
        guard !descriptor.isLocked, descriptor.lockReason == nil else {
            throw GitWorktreeRetirementError.lockedWorktree(descriptor.lockReason)
        }
        guard activeOperationCount == 0 else {
            throw GitWorktreeRetirementError.activeOperations(activeOperationCount)
        }
        guard let registeredHead = descriptor.head?.trimmingCharacters(in: .whitespacesAndNewlines),
              !registeredHead.isEmpty,
              registeredHead == liveHead
        else { throw GitWorktreeRetirementError.targetChanged }
        self.candidate = candidate
        branch = descriptor.branch
        self.registeredHead = registeredHead
        self.liveHead = liveHead
        self.generation = generation
        self.activeOperationCount = activeOperationCount
        targetDigest = GitWorktreeRetirementTarget.digest(
            [
                "cleanup",
                candidate.repositoryID,
                candidate.repositoryRoot.canonicalPath,
                candidate.commonGitDirectory.canonicalPath,
                candidate.worktreeID,
                candidate.registeredPath,
                candidate.canonicalPath,
                candidate.gitDirectory.canonicalPath,
                descriptor.branch ?? "<detached>",
                registeredHead,
                liveHead,
                String(generation),
                String(candidate.worktreeDirectory.device),
                String(candidate.worktreeDirectory.inode),
                String(candidate.gitDirectory.device),
                String(candidate.gitDirectory.inode)
            ].joined(separator: "\u{0}")
        )
    }

    func matches(_ target: GitWorktreeRetirementTarget) -> Bool {
        candidate == target.candidate
            && branch == target.branch
            && registeredHead == target.registeredHead
            && liveHead == target.liveHead
            && generation == target.generation
            && activeOperationCount == target.activeOperationCount
    }

    func matchesIdentityAndHead(_ other: GitWorktreeRetirementCleanupTarget) -> Bool {
        candidate == other.candidate
            && branch == other.branch
            && registeredHead == other.registeredHead
            && liveHead == other.liveHead
            && activeOperationCount == other.activeOperationCount
    }
}

struct GitWorktreeRetirementDrainEvidence: Equatable, Codable {
    let drainedSessionIDs: [String]
    let activeAdmissionsBefore: Int
    let activeAdmissionsAfter: Int
    let liveBindingsRemaining: Int
    let workspaceClaimsRemaining: Int
    let watchersRemaining: Int
    let pendingPublicationsRemaining: Int

    var isFullyDrained: Bool {
        activeAdmissionsAfter == 0
            && liveBindingsRemaining == 0
            && workspaceClaimsRemaining == 0
            && watchersRemaining == 0
            && pendingPublicationsRemaining == 0
    }
}

struct GitWorktreeRetirementMutationEvidence: Equatable, Codable {
    let serializedExecutor: Bool
    let authorizationConsumedAt: Date?
    let gitRemoveExitCode: Int32?
}

struct GitWorktreeRetirementPostconditions: Equatable, Codable {
    let gitRegistrationAbsent: Bool
    let registeredPathAbsent: Bool
    let gitDirectoryAbsent: Bool
    let pathAbsent: Bool
    let verifiedAt: Date?

    var provesRetirement: Bool {
        gitRegistrationAbsent && registeredPathAbsent && gitDirectoryAbsent && pathAbsent && verifiedAt != nil
    }

    static let unknown = Self(
        gitRegistrationAbsent: false,
        registeredPathAbsent: false,
        gitDirectoryAbsent: false,
        pathAbsent: false,
        verifiedAt: nil
    )
}

struct GitWorktreeRetirementAttestedIdentity: Equatable, Codable {
    let repositoryRoot: GitWorktreeRetirementDirectoryIdentity
    let commonGitDirectory: GitWorktreeRetirementDirectoryIdentity
    let worktreeParentDirectory: GitWorktreeRetirementDirectoryIdentity
    let worktreeDirectory: GitWorktreeRetirementDirectoryIdentity
    let gitDirectoryParent: GitWorktreeRetirementDirectoryIdentity
    let gitDirectory: GitWorktreeRetirementDirectoryIdentity
}

struct GitWorktreeRetirementEvidence: Equatable, Codable {
    enum State: String, Codable {
        case retired
        case blockedResidue = "blocked_residue"
    }

    let evidenceID: String
    let state: State
    let reason: String?
    let authorityScope: String
    let appVersion: String
    let operationVersion: Int
    let generation: UInt64
    let repositoryID: String
    let repositoryRoot: String
    let attestedIdentity: GitWorktreeRetirementAttestedIdentity
    let worktreeID: String
    let registeredPath: String
    let canonicalPath: String
    let targetDigest: String?
    let manifestDigest: String?
    let cleanupManifestDigest: String?
    let cleanupAuthorizationDigest: String?
    let consumedAuthorizationDigest: String
    let drain: GitWorktreeRetirementDrainEvidence?
    let mutation: GitWorktreeRetirementMutationEvidence
    let postconditions: GitWorktreeRetirementPostconditions
    let recordedAt: Date
}

struct GitWorktreeRetirementPreparation: Equatable {
    let token: String
    let tokenDigest: String
    let candidate: GitWorktreeRetirementCandidate
    let generation: UInt64
    let issuedAt: Date
    let expiresAt: Date
}

struct GitWorktreeRetirementCleanupPreparation: Equatable {
    let token: String
    let tokenDigest: String
    let target: GitWorktreeRetirementCleanupTarget
    let cleanupManifestDigest: String
    let generation: UInt64
    let startedAt: Date
}

struct GitWorktreeRetirementCleanupAuthorization: Equatable {
    let token: String
    let tokenDigest: String
    let target: GitWorktreeRetirementCleanupTarget
    let cleanupManifestDigest: String
    let drain: GitWorktreeRetirementDrainEvidence
    let issuedAt: Date
    let expiresAt: Date

    var generation: UInt64 {
        target.generation
    }
}

struct GitWorktreeRetirementAuthorization: Equatable {
    let token: String
    let tokenDigest: String
    let cleanupAuthorizationDigest: String?
    let cleanupManifestDigest: String?
    let target: GitWorktreeRetirementTarget
    let drain: GitWorktreeRetirementDrainEvidence
    let issuedAt: Date
    let expiresAt: Date
}

struct GitWorktreeRetirementProgress: Equatable {
    enum Phase: String, Equatable {
        case cleanupAuthorized = "cleanup_authorized"
        case authorized
        case applying
    }

    let phase: Phase
    let tokenDigest: String
    let cleanupAuthorizationDigest: String?
    let candidate: GitWorktreeRetirementCandidate
    let generation: UInt64
    let drain: GitWorktreeRetirementDrainEvidence
    let targetDigest: String
    let manifestDigest: String?
    let cleanupManifestDigest: String?
    let issuedAt: Date
    let expiresAt: Date
}

struct GitWorktreeRetirementPermit: Equatable {
    enum Phase: String, Codable {
        case draining
        case cleanupDraining = "cleanup_draining"
        case cleanupAuthorized = "cleanup_authorized"
        case authorized
        case applying
    }

    let authorizationDigest: String
    let candidate: GitWorktreeRetirementCandidate
    let generation: UInt64
    let phase: Phase
}

final class GitWorktreeRetirementAdmissionLease: @unchecked Sendable {
    let id: UUID
    let generation: UInt64
    private weak var authority: GitWorktreeRetirementAuthority?
    private let lock = NSLock()
    private var released = false

    fileprivate init(id: UUID, generation: UInt64, authority: GitWorktreeRetirementAuthority) {
        self.id = id
        self.generation = generation
        self.authority = authority
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        authority?.releaseAdmissionLease(id: id, generation: generation)
    }

    deinit { release() }
}

enum GitWorktreeRetirementError: LocalizedError, Equatable {
    case activationRequired
    case alreadyRetiring(String)
    case bindingRejected(String)
    case mutationRejected(String)
    case gitAccessRejected(String)
    case invalidAuthorization
    case authorizationAlreadyConsumed
    case authorizationExpired
    case invalidCleanupAuthorization
    case cleanupAuthorizationAlreadyConsumed
    case cleanupAuthorizationExpired
    case targetChanged
    case mainWorktree
    case nonAppManagedPath(String)
    case dirtyWorktree
    case ignoredContent
    case lockedWorktree(String?)
    case missingIdentityEvidence(String)
    case symlinkIdentityEvidence(String)
    case activeOperations(Int)
    case drainTimedOut(Int)
    case persistenceFailed(String)
    case corruptPersistentState(String)
    case removalFailed(String)
    case postconditionFailed(String)

    var errorDescription: String? {
        switch self {
        case .activationRequired:
            "Worktree retirement is unavailable until the explicit retirement policy activation gate is enabled."
        case let .alreadyRetiring(worktreeID):
            "Worktree \(worktreeID) already has durable retirement state; worktree IDs are never reused."
        case let .bindingRejected(worktreeID):
            "Worktree \(worktreeID) is retiring or retired; RepoPrompt refuses the binding."
        case let .mutationRejected(path):
            "Worktree at \(path) is retiring or retired; RepoPrompt refuses filesystem mutation."
        case let .gitAccessRejected(path):
            "Worktree at \(path) is retiring; RepoPrompt refuses Git process admission outside its retirement transaction."
        case .invalidAuthorization:
            "Retirement authorization is invalid or does not match the sealed target."
        case .authorizationAlreadyConsumed:
            "Retirement authorization was already consumed and can only be used for durable evidence readback."
        case .authorizationExpired:
            "Retirement authorization expired and the target is durably blocked as residue."
        case .invalidCleanupAuthorization:
            "Cleanup authorization is invalid or does not match the sealed worktree target."
        case .cleanupAuthorizationAlreadyConsumed:
            "Cleanup authorization was already consumed; read the durable retirement phase instead."
        case .cleanupAuthorizationExpired:
            "Cleanup authorization expired and the target is durably blocked as residue."
        case .targetChanged:
            "Worktree identity or content changed after retirement admission closed. No removal was attempted."
        case .mainWorktree:
            "The main worktree cannot be retired."
        case let .nonAppManagedPath(path):
            "Worktree at \(path) is outside RepoPrompt's app-managed worktree container."
        case .dirtyWorktree:
            "Worktree has staged, unstaged, or untracked content; retirement is fail-closed."
        case .ignoredContent:
            "Worktree contains ignored content; retirement is fail-closed."
        case let .lockedWorktree(reason):
            "Worktree is Git-locked\(reason.map { ": \($0)" } ?? ".")"
        case let .missingIdentityEvidence(path):
            "Required directory identity evidence is missing at \(path)."
        case let .symlinkIdentityEvidence(path):
            "Required directory identity evidence resolves through a symlink leaf at \(path)."
        case let .activeOperations(count):
            "Retirement target still has \(count) RepoPrompt-controlled active operation(s)."
        case let .drainTimedOut(count):
            "Retirement drain timed out with \(count) RepoPrompt-controlled admission lease(s) remaining."
        case let .persistenceFailed(message):
            "Retirement durable-state persistence failed: \(message)"
        case let .corruptPersistentState(message):
            "Retirement durable state is corrupt or unsupported; all retirement admission is fail-closed: \(message)"
        case let .removalFailed(message):
            "Git worktree removal failed: \(message)"
        case let .postconditionFailed(message):
            "Worktree removal postcondition failed: \(message)"
        }
    }
}

final class GitWorktreeRetirementFileLease: @unchecked Sendable {
    private let descriptor: Int32
    private let releaseLock = NSLock()
    private var released = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL, nonBlocking: Bool) throws -> GitWorktreeRetirementFileLease {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw GitWorktreeRetirementError.persistenceFailed(
                "could not open interprocess lock at \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        let operation = LOCK_EX | (nonBlocking ? LOCK_NB : 0)
        guard flock(descriptor, operation) == 0 else {
            let code = errno
            _ = close(descriptor)
            if nonBlocking, code == EWOULDBLOCK {
                throw GitWorktreeRetirementError.alreadyRetiring(url.deletingLastPathComponent().lastPathComponent)
            }
            throw GitWorktreeRetirementError.persistenceFailed(
                "could not acquire interprocess lock at \(url.path): \(String(cString: strerror(code)))"
            )
        }
        return GitWorktreeRetirementFileLease(descriptor: descriptor)
    }

    func release() {
        releaseLock.lock()
        guard !released else {
            releaseLock.unlock()
            return
        }
        released = true
        releaseLock.unlock()
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    deinit { release() }
}

/// Generation-aware authority for the operations RepoPrompt controls. It intentionally does not
/// claim authority over arbitrary external processes, open handles, or same-user filesystem writes.
final class GitWorktreeRetirementAuthority: @unchecked Sendable {
    static let shared = GitWorktreeRetirementAuthority(persistenceURL: defaultPersistenceURL())
    #if DEBUG
        private static let operationalOverrideLock = NSLock()
        private static var operationalOverrideForTesting: GitWorktreeRetirementAuthority?

        static var operational: GitWorktreeRetirementAuthority {
            operationalOverrideLock.lock()
            defer { operationalOverrideLock.unlock() }
            return operationalOverrideForTesting ?? shared
        }

        static func setOperationalAuthorityForTesting(
            _ authority: GitWorktreeRetirementAuthority?
        ) {
            operationalOverrideLock.lock()
            operationalOverrideForTesting = authority
            operationalOverrideLock.unlock()
        }
    #else
        static var operational: GitWorktreeRetirementAuthority {
            shared
        }
    #endif
    static let authorityScope = "repoprompt_control_plane"
    static let operationVersion = 4
    static let authorizationTTL: TimeInterval = 60
    static let cleanupAuthorizationTTL: TimeInterval = 10 * 60

    private enum Resource {
        case binding(repositoryID: String?, worktreeID: String, canonicalPath: String?)
        case mutation(paths: [String])
        case workspace(paths: [String])
        case git(path: String, commonGitDirectory: String?, affectedWorktreeID: String?, affectedPaths: [String])
    }

    private struct ActiveLease {
        let id: UUID
        let generation: UInt64
        let resource: Resource
    }

    private struct PreparationRecord: Codable, Equatable {
        let tokenDigest: String
        let candidate: GitWorktreeRetirementCandidate
        let generation: UInt64
        let issuedAt: Date
        let expiresAt: Date
    }

    private struct AuthorizationRecord: Codable, Equatable {
        let tokenDigest: String
        let cleanupAuthorizationDigest: String?
        let cleanupManifestDigest: String?
        let target: GitWorktreeRetirementTarget
        let drain: GitWorktreeRetirementDrainEvidence
        let issuedAt: Date
        let expiresAt: Date
    }

    private struct CleanupPreparationRecord: Codable, Equatable {
        let tokenDigest: String
        let target: GitWorktreeRetirementCleanupTarget
        let cleanupManifestDigest: String
        let generation: UInt64
        let startedAt: Date
    }

    private struct CleanupAuthorizationRecord: Codable, Equatable {
        let tokenDigest: String
        let target: GitWorktreeRetirementCleanupTarget
        let cleanupManifestDigest: String
        let drain: GitWorktreeRetirementDrainEvidence
        let issuedAt: Date
        let expiresAt: Date
    }

    private struct ApplyingRecord: Codable, Equatable {
        let authorization: AuthorizationRecord
        let consumedAt: Date
    }

    private enum Record: Codable, Equatable {
        case draining(PreparationRecord)
        case cleanupDraining(CleanupPreparationRecord)
        case cleanupAuthorized(CleanupAuthorizationRecord)
        case authorized(AuthorizationRecord)
        case applying(ApplyingRecord)
        case retired(GitWorktreeRetirementEvidence)
        case blockedResidue(GitWorktreeRetirementEvidence)
    }

    private struct PersistedState: Codable {
        let schemaLineage: String
        let schemaVersion: Int
        var stateGeneration: UInt64
        var recordsByWorktreeID: [String: Record]
    }

    private static let schemaLineage = "repoprompt.git-worktree-retirement"
    private static let schemaVersion = 3

    private let lock = NSLock()
    private let persistenceURL: URL
    private let persistenceLockURL: URL
    private var state: PersistedState
    private var lastPersistedGeneration: UInt64 = 0
    private var activeLeases: [UUID: ActiveLease] = [:]
    private var operationLeasesByWorktreeID: [String: GitWorktreeRetirementFileLease] = [:]
    private var loadFailure: GitWorktreeRetirementError?

    init(persistenceURL: URL) {
        self.persistenceURL = persistenceURL
        persistenceLockURL = persistenceURL.appendingPathExtension("lock")
        state = PersistedState(
            schemaLineage: Self.schemaLineage,
            schemaVersion: Self.schemaVersion,
            stateGeneration: 0,
            recordsByWorktreeID: [:]
        )
        do {
            try loadPersistentState()
            lastPersistedGeneration = state.stateGeneration
            try recoverInterruptedState()
        } catch let error as GitWorktreeRetirementError {
            loadFailure = error
        } catch {
            loadFailure = .corruptPersistentState(error.localizedDescription)
        }
    }

    func acquireBindingLease(
        worktreeID: String,
        repositoryID: String? = nil,
        canonicalPath: String? = nil,
        permit: GitWorktreeRetirementPermit? = nil
    ) throws -> GitWorktreeRetirementAdmissionLease {
        try acquire(
            resource: .binding(
                repositoryID: repositoryID,
                worktreeID: worktreeID,
                canonicalPath: canonicalPath.map(Self.canonicalPath)
            ),
            permit: permit
        )
    }

    func acquireMutationLease(
        paths: [String],
        permit: GitWorktreeRetirementPermit? = nil
    ) throws -> GitWorktreeRetirementAdmissionLease {
        try acquire(resource: .mutation(paths: paths.map(Self.canonicalPath)), permit: permit)
    }

    func acquireWorkspaceRootLease(
        paths: [String],
        permit: GitWorktreeRetirementPermit? = nil
    ) throws -> GitWorktreeRetirementAdmissionLease {
        try acquire(resource: .workspace(paths: paths.map(Self.canonicalPath)), permit: permit)
    }

    func acquireGitProcessLease(
        at path: URL,
        commonGitDirectory: URL?,
        affectedWorktreeID: String? = nil,
        affectedPaths: [URL] = [],
        permit: GitWorktreeRetirementPermit? = nil
    ) throws -> GitWorktreeRetirementAdmissionLease {
        try acquire(
            resource: .git(
                path: Self.canonicalPath(path.path),
                commonGitDirectory: commonGitDirectory.map { Self.canonicalPath($0.path) },
                affectedWorktreeID: affectedWorktreeID,
                affectedPaths: affectedPaths.map { Self.canonicalPath($0.path) }
            ),
            permit: permit
        )
    }

    func begin(_ candidate: GitWorktreeRetirementCandidate, now: Date = Date()) throws -> GitWorktreeRetirementPreparation {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        for (existingWorktreeID, record) in state.recordsByWorktreeID {
            let identity = Self.identity(of: record)
            guard existingWorktreeID != candidate.worktreeID,
                  identity.repositoryID != candidate.repositoryID
                  || identity.canonicalPath != candidate.canonicalPath
            else {
                throw GitWorktreeRetirementError.alreadyRetiring(existingWorktreeID)
            }
        }
        let operationLease = try GitWorktreeRetirementFileLease.acquire(
            at: URL(fileURLWithPath: candidate.commonGitDirectory.canonicalPath, isDirectory: true)
                .appendingPathComponent("repoprompt-retirement.lock"),
            nonBlocking: true
        )
        operationLeasesByWorktreeID[candidate.worktreeID] = operationLease
        let token = "retire_\(UUID().uuidString.lowercased())"
        let digest = Self.digest(token)
        state.stateGeneration &+= 1
        let record = PreparationRecord(
            tokenDigest: digest,
            candidate: candidate,
            generation: state.stateGeneration,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(Self.authorizationTTL)
        )
        state.recordsByWorktreeID[candidate.worktreeID] = .draining(record)
        do {
            try persistLocked(expectedOnDiskGeneration: lastPersistedGeneration)
            lastPersistedGeneration = state.stateGeneration
        } catch {
            markPersistenceAmbiguousLocked(error)
            throw error
        }
        return GitWorktreeRetirementPreparation(
            token: token,
            tokenDigest: digest,
            candidate: candidate,
            generation: record.generation,
            issuedAt: record.issuedAt,
            expiresAt: record.expiresAt
        )
    }

    func beginCleanup(
        _ target: GitWorktreeRetirementCleanupTarget,
        cleanupManifestDigest: String,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementCleanupPreparation {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        for (existingWorktreeID, record) in state.recordsByWorktreeID {
            let identity = Self.identity(of: record)
            guard existingWorktreeID != target.worktreeID,
                  identity.repositoryID != target.repositoryID
                  || identity.canonicalPath != target.canonicalPath
            else {
                throw GitWorktreeRetirementError.alreadyRetiring(existingWorktreeID)
            }
        }
        guard !cleanupManifestDigest.isEmpty else {
            throw GitWorktreeRetirementError.invalidCleanupAuthorization
        }
        let operationLease = try GitWorktreeRetirementFileLease.acquire(
            at: URL(fileURLWithPath: target.candidate.commonGitDirectory.canonicalPath, isDirectory: true)
                .appendingPathComponent("repoprompt-retirement.lock"),
            nonBlocking: true
        )
        operationLeasesByWorktreeID[target.worktreeID] = operationLease
        let token = "cleanup_\(UUID().uuidString.lowercased())"
        let digest = Self.digest(token)
        state.stateGeneration &+= 1
        let record = CleanupPreparationRecord(
            tokenDigest: digest,
            target: target,
            cleanupManifestDigest: cleanupManifestDigest,
            generation: state.stateGeneration,
            startedAt: now
        )
        state.recordsByWorktreeID[target.worktreeID] = .cleanupDraining(record)
        do {
            try persistLocked(expectedOnDiskGeneration: lastPersistedGeneration)
            lastPersistedGeneration = state.stateGeneration
        } catch {
            markPersistenceAmbiguousLocked(error)
            throw error
        }
        return GitWorktreeRetirementCleanupPreparation(
            token: token,
            tokenDigest: digest,
            target: target,
            cleanupManifestDigest: cleanupManifestDigest,
            generation: record.generation,
            startedAt: now
        )
    }

    func cancelCleanupPreparationForRetry(
        _ preparation: GitWorktreeRetirementCleanupPreparation
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .cleanupDraining(record)? = state.recordsByWorktreeID[preparation.target.worktreeID],
              record.tokenDigest == preparation.tokenDigest,
              record.generation == preparation.generation,
              record.target == preparation.target,
              record.cleanupManifestDigest == preparation.cleanupManifestDigest
        else { throw GitWorktreeRetirementError.invalidCleanupAuthorization }
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID.removeValue(forKey: preparation.target.worktreeID)
        }
        operationLeasesByWorktreeID.removeValue(forKey: preparation.target.worktreeID)?.release()
    }

    func permit(
        for preparation: GitWorktreeRetirementCleanupPreparation
    ) throws -> GitWorktreeRetirementPermit {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .cleanupDraining(record)? = state.recordsByWorktreeID[preparation.target.worktreeID],
              record.tokenDigest == preparation.tokenDigest,
              record.generation == preparation.generation,
              record.target == preparation.target,
              record.cleanupManifestDigest == preparation.cleanupManifestDigest
        else { throw GitWorktreeRetirementError.invalidCleanupAuthorization }
        return GitWorktreeRetirementPermit(
            authorizationDigest: record.tokenDigest,
            candidate: record.target.candidate,
            generation: record.generation,
            phase: .cleanupDraining
        )
    }

    func activeAdmissionCount(
        for preparation: GitWorktreeRetirementCleanupPreparation
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        return activeLeases.values.count {
            Self.resource($0.resource, matches: preparation.target.candidate, includeRepository: true)
        }
    }

    func awaitZeroAdmissions(
        for preparation: GitWorktreeRetirementCleanupPreparation,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let count = try activeAdmissionCount(for: preparation)
            if count == 0 { return }
            guard clock.now < deadline else { throw GitWorktreeRetirementError.drainTimedOut(count) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func authorizeCleanupAfterDrain(
        _ preparation: GitWorktreeRetirementCleanupPreparation,
        target: GitWorktreeRetirementCleanupTarget,
        drain: GitWorktreeRetirementDrainEvidence,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementCleanupAuthorization {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .cleanupDraining(record)? = state.recordsByWorktreeID[preparation.target.worktreeID],
              record.tokenDigest == preparation.tokenDigest,
              record.generation == preparation.generation,
              record.target.matchesIdentityAndHead(target),
              record.cleanupManifestDigest == preparation.cleanupManifestDigest,
              target.generation == preparation.generation,
              drain.isFullyDrained,
              !activeLeases.values.contains(where: {
                  Self.resource($0.resource, matches: target.candidate, includeRepository: true)
              })
        else { throw GitWorktreeRetirementError.invalidCleanupAuthorization }
        let authorization = CleanupAuthorizationRecord(
            tokenDigest: record.tokenDigest,
            target: target,
            cleanupManifestDigest: record.cleanupManifestDigest,
            drain: drain,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(Self.cleanupAuthorizationTTL)
        )
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[target.worktreeID] = .cleanupAuthorized(authorization)
        }
        return GitWorktreeRetirementCleanupAuthorization(
            token: preparation.token,
            tokenDigest: authorization.tokenDigest,
            target: target,
            cleanupManifestDigest: authorization.cleanupManifestDigest,
            drain: drain,
            issuedAt: authorization.issuedAt,
            expiresAt: authorization.expiresAt
        )
    }

    func cleanupAuthorization(
        token: String,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementCleanupAuthorization {
        let digest = Self.digest(token)
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        for (worktreeID, record) in state.recordsByWorktreeID {
            if case let .cleanupAuthorized(authorization) = record,
               authorization.tokenDigest == digest
            {
                guard now <= authorization.expiresAt else {
                    let evidence = Self.blockedEvidence(
                        cleanupAuthorization: authorization,
                        reason: GitWorktreeRetirementError.cleanupAuthorizationExpired.localizedDescription,
                        now: now
                    )
                    try transitionAndPersistLocked {
                        $0.recordsByWorktreeID[worktreeID] = .blockedResidue(evidence)
                    }
                    operationLeasesByWorktreeID.removeValue(forKey: worktreeID)?.release()
                    throw GitWorktreeRetirementError.cleanupAuthorizationExpired
                }
                return GitWorktreeRetirementCleanupAuthorization(
                    token: token,
                    tokenDigest: digest,
                    target: authorization.target,
                    cleanupManifestDigest: authorization.cleanupManifestDigest,
                    drain: authorization.drain,
                    issuedAt: authorization.issuedAt,
                    expiresAt: authorization.expiresAt
                )
            }
            if case let .authorized(authorization) = record,
               authorization.cleanupAuthorizationDigest == digest
            {
                throw GitWorktreeRetirementError.cleanupAuthorizationAlreadyConsumed
            }
        }
        if evidenceLocked(tokenDigest: digest) != nil {
            throw GitWorktreeRetirementError.cleanupAuthorizationAlreadyConsumed
        }
        throw GitWorktreeRetirementError.invalidCleanupAuthorization
    }

    func permit(
        for authorization: GitWorktreeRetirementCleanupAuthorization
    ) throws -> GitWorktreeRetirementPermit {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .cleanupAuthorized(record)? = state.recordsByWorktreeID[authorization.target.worktreeID],
              record.tokenDigest == authorization.tokenDigest,
              record.target == authorization.target
        else { throw GitWorktreeRetirementError.invalidCleanupAuthorization }
        return GitWorktreeRetirementPermit(
            authorizationDigest: record.tokenDigest,
            candidate: record.target.candidate,
            generation: record.target.generation,
            phase: .cleanupAuthorized
        )
    }

    func completeCleanup(
        _ authorization: GitWorktreeRetirementCleanupAuthorization,
        target: GitWorktreeRetirementTarget,
        cleanupManifestDigest: String,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementAuthorization {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .cleanupAuthorized(record)? = state.recordsByWorktreeID[authorization.target.worktreeID],
              record.tokenDigest == authorization.tokenDigest,
              record.target == authorization.target,
              record.cleanupManifestDigest == authorization.cleanupManifestDigest,
              record.cleanupManifestDigest == cleanupManifestDigest,
              record.target.matches(target),
              !activeLeases.values.contains(where: {
                  Self.resource($0.resource, matches: target.candidate, includeRepository: true)
              })
        else { throw GitWorktreeRetirementError.invalidCleanupAuthorization }
        guard now <= record.expiresAt else {
            let evidence = Self.blockedEvidence(
                cleanupAuthorization: record,
                reason: GitWorktreeRetirementError.cleanupAuthorizationExpired.localizedDescription,
                now: now
            )
            try transitionAndPersistLocked {
                $0.recordsByWorktreeID[target.worktreeID] = .blockedResidue(evidence)
            }
            operationLeasesByWorktreeID.removeValue(forKey: target.worktreeID)?.release()
            throw GitWorktreeRetirementError.cleanupAuthorizationExpired
        }
        let retirement = AuthorizationRecord(
            tokenDigest: record.tokenDigest,
            cleanupAuthorizationDigest: record.tokenDigest,
            cleanupManifestDigest: record.cleanupManifestDigest,
            target: target,
            drain: record.drain,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(Self.authorizationTTL)
        )
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[target.worktreeID] = .authorized(retirement)
        }
        return GitWorktreeRetirementAuthorization(
            token: authorization.token,
            tokenDigest: retirement.tokenDigest,
            cleanupAuthorizationDigest: retirement.cleanupAuthorizationDigest,
            cleanupManifestDigest: retirement.cleanupManifestDigest,
            target: retirement.target,
            drain: retirement.drain,
            issuedAt: retirement.issuedAt,
            expiresAt: retirement.expiresAt
        )
    }

    /// Reopens admission after a pre-authorization drain was cancelled or timed out.
    /// No destructive operation can have started while the record is still in `draining`.
    /// Persisting the removal keeps retries clean without weakening authorized/applying tombstones.
    func cancelPreparationForRetry(_ preparation: GitWorktreeRetirementPreparation) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .draining(record)? = state.recordsByWorktreeID[preparation.candidate.worktreeID],
              record.tokenDigest == preparation.tokenDigest,
              record.generation == preparation.generation,
              record.candidate == preparation.candidate
        else { throw GitWorktreeRetirementError.invalidAuthorization }
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID.removeValue(forKey: preparation.candidate.worktreeID)
        }
        operationLeasesByWorktreeID.removeValue(forKey: preparation.candidate.worktreeID)?.release()
    }

    func permit(for preparation: GitWorktreeRetirementPreparation) throws -> GitWorktreeRetirementPermit {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .draining(record)? = state.recordsByWorktreeID[preparation.candidate.worktreeID],
              record.tokenDigest == preparation.tokenDigest,
              record.generation == preparation.generation,
              record.candidate == preparation.candidate
        else { throw GitWorktreeRetirementError.invalidAuthorization }
        return GitWorktreeRetirementPermit(
            authorizationDigest: record.tokenDigest,
            candidate: record.candidate,
            generation: record.generation,
            phase: .draining
        )
    }

    func activeAdmissionCount(for preparation: GitWorktreeRetirementPreparation) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        return activeLeases.values.count { Self.resource($0.resource, matches: preparation.candidate, includeRepository: true) }
    }

    func awaitZeroAdmissions(
        for preparation: GitWorktreeRetirementPreparation,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let count = try activeAdmissionCount(for: preparation)
            if count == 0 { return }
            guard clock.now < deadline else { throw GitWorktreeRetirementError.drainTimedOut(count) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func authorizeAfterDrain(
        _ preparation: GitWorktreeRetirementPreparation,
        target: GitWorktreeRetirementTarget,
        drain: GitWorktreeRetirementDrainEvidence,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementAuthorization {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard now <= preparation.expiresAt else {
            try blockPreparationLocked(preparation, reason: GitWorktreeRetirementError.authorizationExpired.localizedDescription, now: now)
            throw GitWorktreeRetirementError.authorizationExpired
        }
        guard case let .draining(record)? = state.recordsByWorktreeID[preparation.candidate.worktreeID],
              record.tokenDigest == preparation.tokenDigest,
              record.generation == preparation.generation,
              target.candidate == preparation.candidate,
              target.generation == preparation.generation,
              target.activeOperationCount == 0,
              drain.isFullyDrained,
              !activeLeases.values.contains(where: {
                  Self.resource($0.resource, matches: preparation.candidate, includeRepository: true)
              })
        else { throw GitWorktreeRetirementError.invalidAuthorization }
        let authorizationRecord = AuthorizationRecord(
            tokenDigest: record.tokenDigest,
            cleanupAuthorizationDigest: nil,
            cleanupManifestDigest: nil,
            target: target,
            drain: drain,
            issuedAt: record.issuedAt,
            expiresAt: record.expiresAt
        )
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[target.worktreeID] = .authorized(authorizationRecord)
        }
        return GitWorktreeRetirementAuthorization(
            token: preparation.token,
            tokenDigest: record.tokenDigest,
            cleanupAuthorizationDigest: nil,
            cleanupManifestDigest: nil,
            target: target,
            drain: drain,
            issuedAt: record.issuedAt,
            expiresAt: record.expiresAt
        )
    }

    func authorization(token: String, now: Date = Date()) throws -> GitWorktreeRetirementAuthorization {
        let digest = Self.digest(token)
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        for (worktreeID, record) in state.recordsByWorktreeID {
            guard case let .authorized(authorization) = record,
                  authorization.tokenDigest == digest
            else { continue }
            guard now <= authorization.expiresAt else {
                let evidence = Self.blockedEvidence(
                    authorization: authorization,
                    reason: GitWorktreeRetirementError.authorizationExpired.localizedDescription,
                    now: now
                )
                try transitionAndPersistLocked {
                    $0.recordsByWorktreeID[worktreeID] = .blockedResidue(evidence)
                }
                operationLeasesByWorktreeID.removeValue(forKey: worktreeID)?.release()
                throw GitWorktreeRetirementError.authorizationExpired
            }
            return GitWorktreeRetirementAuthorization(
                token: token,
                tokenDigest: digest,
                cleanupAuthorizationDigest: authorization.cleanupAuthorizationDigest,
                cleanupManifestDigest: authorization.cleanupManifestDigest,
                target: authorization.target,
                drain: authorization.drain,
                issuedAt: authorization.issuedAt,
                expiresAt: authorization.expiresAt
            )
        }
        if evidenceLocked(tokenDigest: digest) != nil {
            throw GitWorktreeRetirementError.authorizationAlreadyConsumed
        }
        throw GitWorktreeRetirementError.invalidAuthorization
    }

    func permit(for authorization: GitWorktreeRetirementAuthorization) throws -> GitWorktreeRetirementPermit {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .authorized(record)? = state.recordsByWorktreeID[authorization.target.worktreeID],
              record.tokenDigest == authorization.tokenDigest,
              record.target == authorization.target
        else { throw GitWorktreeRetirementError.invalidAuthorization }
        return GitWorktreeRetirementPermit(
            authorizationDigest: record.tokenDigest,
            candidate: record.target.candidate,
            generation: record.target.generation,
            phase: .authorized
        )
    }

    @discardableResult
    func blockAuthorization(
        _ authorization: GitWorktreeRetirementAuthorization,
        reason: String,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementEvidence {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .authorized(record)? = state.recordsByWorktreeID[authorization.target.worktreeID],
              record.tokenDigest == authorization.tokenDigest,
              record.target == authorization.target
        else { throw GitWorktreeRetirementError.invalidAuthorization }
        let evidence = Self.blockedEvidence(authorization: record, reason: reason, now: now)
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[authorization.target.worktreeID] = .blockedResidue(evidence)
        }
        operationLeasesByWorktreeID.removeValue(forKey: authorization.target.worktreeID)?.release()
        return evidence
    }

    @discardableResult
    func blockCleanupAuthorization(
        _ authorization: GitWorktreeRetirementCleanupAuthorization,
        reason: String,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementEvidence {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .cleanupAuthorized(record)? = state.recordsByWorktreeID[authorization.target.worktreeID],
              record.tokenDigest == authorization.tokenDigest,
              record.target == authorization.target
        else { throw GitWorktreeRetirementError.invalidCleanupAuthorization }
        let evidence = Self.blockedEvidence(
            cleanupAuthorization: record,
            reason: reason,
            now: now
        )
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[authorization.target.worktreeID] = .blockedResidue(evidence)
        }
        operationLeasesByWorktreeID.removeValue(forKey: authorization.target.worktreeID)?.release()
        return evidence
    }

    /// Called synchronously after final re-attestation and immediately before the destructive
    /// process is admitted. The consumed state is durably synchronized before returning.
    func consume(
        _ authorization: GitWorktreeRetirementAuthorization,
        reattestedTarget: GitWorktreeRetirementTarget,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementPermit {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .authorized(record)? = state.recordsByWorktreeID[authorization.target.worktreeID],
              record.tokenDigest == authorization.tokenDigest,
              record.target == authorization.target,
              record.target == reattestedTarget
        else { throw GitWorktreeRetirementError.invalidAuthorization }
        guard now <= record.expiresAt else {
            let evidence = Self.blockedEvidence(
                authorization: record,
                reason: GitWorktreeRetirementError.authorizationExpired.localizedDescription,
                now: now
            )
            try transitionAndPersistLocked {
                $0.recordsByWorktreeID[record.target.worktreeID] = .blockedResidue(evidence)
            }
            operationLeasesByWorktreeID.removeValue(forKey: record.target.worktreeID)?.release()
            throw GitWorktreeRetirementError.authorizationExpired
        }
        let conflicting = activeLeases.values.count {
            Self.resource($0.resource, matches: record.target.candidate, includeRepository: true)
        }
        guard conflicting == 0 else { throw GitWorktreeRetirementError.activeOperations(conflicting) }
        let applying = ApplyingRecord(authorization: record, consumedAt: now)
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[record.target.worktreeID] = .applying(applying)
        }
        return GitWorktreeRetirementPermit(
            authorizationDigest: record.tokenDigest,
            candidate: record.target.candidate,
            generation: record.target.generation,
            phase: .applying
        )
    }

    func complete(
        _ permit: GitWorktreeRetirementPermit,
        gitRemoveExitCode: Int32,
        postconditions: GitWorktreeRetirementPostconditions,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementEvidence {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .applying(record)? = state.recordsByWorktreeID[permit.candidate.worktreeID],
              record.authorization.tokenDigest == permit.authorizationDigest,
              record.authorization.target.generation == permit.generation,
              permit.phase == .applying
        else { throw GitWorktreeRetirementError.invalidAuthorization }
        guard gitRemoveExitCode == 0, postconditions.provesRetirement else {
            throw GitWorktreeRetirementError.postconditionFailed(
                "retired completion requires exit code 0 and every exact postcondition"
            )
        }
        let evidence = Self.makeEvidence(
            state: .retired,
            reason: nil,
            authorization: record.authorization,
            consumedAt: record.consumedAt,
            gitRemoveExitCode: gitRemoveExitCode,
            postconditions: postconditions,
            now: now
        )
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[permit.candidate.worktreeID] = .retired(evidence)
        }
        operationLeasesByWorktreeID.removeValue(forKey: permit.candidate.worktreeID)?.release()
        return evidence
    }

    @discardableResult
    func blockResidue(
        _ permit: GitWorktreeRetirementPermit,
        reason: String,
        gitRemoveExitCode: Int32? = nil,
        postconditions: GitWorktreeRetirementPostconditions = .unknown,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementEvidence {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .applying(record)? = state.recordsByWorktreeID[permit.candidate.worktreeID],
              record.authorization.tokenDigest == permit.authorizationDigest
        else { throw GitWorktreeRetirementError.invalidAuthorization }
        let evidence = Self.makeEvidence(
            state: .blockedResidue,
            reason: reason,
            authorization: record.authorization,
            consumedAt: record.consumedAt,
            gitRemoveExitCode: gitRemoveExitCode,
            postconditions: postconditions,
            now: now
        )
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[permit.candidate.worktreeID] = .blockedResidue(evidence)
        }
        operationLeasesByWorktreeID.removeValue(forKey: permit.candidate.worktreeID)?.release()
        return evidence
    }

    @discardableResult
    func blockPreparation(
        _ preparation: GitWorktreeRetirementPreparation,
        target: GitWorktreeRetirementTarget? = nil,
        drain: GitWorktreeRetirementDrainEvidence? = nil,
        reason: String,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementEvidence {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .draining(record)? = state.recordsByWorktreeID[preparation.candidate.worktreeID],
              record.tokenDigest == preparation.tokenDigest
        else { throw GitWorktreeRetirementError.invalidAuthorization }
        let evidence = Self.blockedEvidence(
            preparation: record,
            target: target,
            drain: drain,
            reason: reason,
            now: now
        )
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[preparation.candidate.worktreeID] = .blockedResidue(evidence)
        }
        operationLeasesByWorktreeID.removeValue(forKey: preparation.candidate.worktreeID)?.release()
        return evidence
    }

    @discardableResult
    func blockCleanupPreparation(
        _ preparation: GitWorktreeRetirementCleanupPreparation,
        target: GitWorktreeRetirementCleanupTarget? = nil,
        drain: GitWorktreeRetirementDrainEvidence? = nil,
        reason: String,
        now: Date = Date()
    ) throws -> GitWorktreeRetirementEvidence {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard case let .cleanupDraining(record)? = state.recordsByWorktreeID[preparation.target.worktreeID],
              record.tokenDigest == preparation.tokenDigest
        else { throw GitWorktreeRetirementError.invalidCleanupAuthorization }
        let authorization = CleanupAuthorizationRecord(
            tokenDigest: record.tokenDigest,
            target: target ?? record.target,
            cleanupManifestDigest: record.cleanupManifestDigest,
            drain: drain ?? .init(
                drainedSessionIDs: [],
                activeAdmissionsBefore: 0,
                activeAdmissionsAfter: 0,
                liveBindingsRemaining: 0,
                workspaceClaimsRemaining: 0,
                watchersRemaining: 0,
                pendingPublicationsRemaining: 0
            ),
            issuedAt: record.startedAt,
            expiresAt: record.startedAt
        )
        let evidence = Self.blockedEvidence(
            cleanupAuthorization: authorization,
            reason: reason,
            now: now
        )
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[preparation.target.worktreeID] = .blockedResidue(evidence)
        }
        operationLeasesByWorktreeID.removeValue(forKey: preparation.target.worktreeID)?.release()
        return evidence
    }

    func evidence(token: String) throws -> GitWorktreeRetirementEvidence? {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        return evidenceLocked(tokenDigest: Self.digest(token))
    }

    func evidence(worktreeID: String) throws -> GitWorktreeRetirementEvidence? {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard let record = state.recordsByWorktreeID[worktreeID] else { return nil }
        switch record {
        case let .retired(evidence), let .blockedResidue(evidence):
            return evidence
        case .draining, .cleanupDraining, .cleanupAuthorized, .authorized, .applying:
            return nil
        }
    }

    func progress(token: String) throws -> GitWorktreeRetirementProgress? {
        let digest = Self.digest(token)
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        for record in state.recordsByWorktreeID.values {
            guard let progress = Self.progress(of: record) else { continue }
            if progress.tokenDigest == digest
                || progress.cleanupAuthorizationDigest == digest
            {
                return progress
            }
        }
        return nil
    }

    func progress(worktreeID: String) throws -> GitWorktreeRetirementProgress? {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        guard let record = state.recordsByWorktreeID[worktreeID] else { return nil }
        return Self.progress(of: record)
    }

    func isRetiring(worktreeID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do { try refreshPersistentStateLocked() } catch { return true }
        guard loadFailure == nil, let record = state.recordsByWorktreeID[worktreeID] else { return loadFailure != nil }
        switch record {
        case .draining, .cleanupDraining, .cleanupAuthorized, .authorized, .applying, .blockedResidue, .retired:
            return true
        }
    }

    #if DEBUG
        func resetForTesting(removePersistentState: Bool = true) {
            precondition(self !== Self.shared, "Tests must never reset shared retirement authority state")
            lock.lock()
            activeLeases.removeAll()
            state = PersistedState(
                schemaLineage: Self.schemaLineage,
                schemaVersion: Self.schemaVersion,
                stateGeneration: 0,
                recordsByWorktreeID: [:]
            )
            lastPersistedGeneration = 0
            operationLeasesByWorktreeID.removeAll()
            loadFailure = nil
            if removePersistentState, FileManager.default.fileExists(atPath: persistenceURL.path) {
                do {
                    try FileManager.default.removeItem(at: persistenceURL)
                } catch {
                    // Concurrent test cleanup may win the existence race. ENOENT is success.
                    if FileManager.default.fileExists(atPath: persistenceURL.path) {
                        loadFailure = GitWorktreeRetirementError.persistenceFailed(error.localizedDescription)
                    }
                }
            }
            lock.unlock()
        }

        func debugStateGeneration() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return state.stateGeneration
        }

        static var defaultPersistenceURLForTesting: URL {
            defaultPersistenceURL()
        }
    #endif

    fileprivate func releaseAdmissionLease(id: UUID, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard activeLeases[id]?.generation == generation else { return }
        activeLeases.removeValue(forKey: id)
    }

    private func acquire(
        resource: Resource,
        permit: GitWorktreeRetirementPermit?
    ) throws -> GitWorktreeRetirementAdmissionLease {
        lock.lock()
        defer { lock.unlock() }
        try requireHealthyLocked()
        try refreshPersistentStateLocked()
        for record in state.recordsByWorktreeID.values {
            let candidate: GitWorktreeRetirementCandidate
            let active: Bool
            let expectedDigest: String?
            let expectedGeneration: UInt64
            let expectedPhase: GitWorktreeRetirementPermit.Phase?
            switch record {
            case let .draining(value):
                candidate = value.candidate
                active = true
                expectedDigest = value.tokenDigest
                expectedGeneration = value.generation
                expectedPhase = .draining
            case let .cleanupDraining(value):
                candidate = value.target.candidate
                active = true
                expectedDigest = value.tokenDigest
                expectedGeneration = value.generation
                expectedPhase = .cleanupDraining
            case let .cleanupAuthorized(value):
                candidate = value.target.candidate
                active = true
                expectedDigest = value.tokenDigest
                expectedGeneration = value.target.generation
                expectedPhase = .cleanupAuthorized
            case let .authorized(value):
                candidate = value.target.candidate
                active = true
                expectedDigest = value.tokenDigest
                expectedGeneration = value.target.generation
                expectedPhase = .authorized
            case let .applying(value):
                candidate = value.authorization.target.candidate
                active = true
                expectedDigest = value.authorization.tokenDigest
                expectedGeneration = value.authorization.target.generation
                expectedPhase = .applying
            case let .retired(evidence), let .blockedResidue(evidence):
                guard Self.resource(resource, matchesPathOrID: evidence) else { continue }
                switch resource {
                case let .binding(_, worktreeID, _): throw GitWorktreeRetirementError.bindingRejected(worktreeID)
                case let .mutation(paths): throw GitWorktreeRetirementError.mutationRejected(paths.first ?? evidence.registeredPath)
                case let .workspace(paths): throw GitWorktreeRetirementError.mutationRejected(paths.first ?? evidence.registeredPath)
                case .git:
                    // Permanent tombstones reject target identity/path reuse but do not freeze
                    // unrelated repository-wide Git commands forever.
                    throw GitWorktreeRetirementError.gitAccessRejected(evidence.registeredPath)
                }
            }
            guard active, Self.resource(resource, matches: candidate, includeRepository: true) else { continue }
            if let permit,
               permit.authorizationDigest == expectedDigest,
               permit.generation == expectedGeneration,
               permit.candidate == candidate,
               permit.phase == expectedPhase
            {
                continue
            }
            switch resource {
            case let .binding(_, worktreeID, _): throw GitWorktreeRetirementError.bindingRejected(worktreeID)
            case let .mutation(paths): throw GitWorktreeRetirementError.mutationRejected(paths.first ?? candidate.registeredPath)
            case let .workspace(paths): throw GitWorktreeRetirementError.mutationRejected(paths.first ?? candidate.registeredPath)
            case .git: throw GitWorktreeRetirementError.gitAccessRejected(candidate.registeredPath)
            }
        }
        let id = UUID()
        let generation = state.stateGeneration
        activeLeases[id] = ActiveLease(id: id, generation: generation, resource: resource)
        return GitWorktreeRetirementAdmissionLease(id: id, generation: generation, authority: self)
    }

    private func requireHealthyLocked() throws {
        if let loadFailure { throw loadFailure }
    }

    private func refreshPersistentStateLocked() throws {
        try requireHealthyLocked()
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
            guard lastPersistedGeneration == 0 else {
                throw GitWorktreeRetirementError.corruptPersistentState(
                    "durable state disappeared after generation \(lastPersistedGeneration)"
                )
            }
            return
        }
        let fileLease = try GitWorktreeRetirementFileLease.acquire(at: persistenceLockURL, nonBlocking: false)
        defer { fileLease.release() }
        let data = try Data(contentsOf: persistenceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: PersistedState
        do {
            decoded = try decoder.decode(PersistedState.self, from: data)
        } catch {
            throw GitWorktreeRetirementError.corruptPersistentState(error.localizedDescription)
        }
        guard decoded.schemaLineage == Self.schemaLineage,
              decoded.schemaVersion == Self.schemaVersion,
              decoded.stateGeneration >= lastPersistedGeneration
        else {
            throw GitWorktreeRetirementError.corruptPersistentState(
                "durable state lineage/version/generation regressed"
            )
        }
        if decoded.stateGeneration > lastPersistedGeneration {
            state = decoded
            lastPersistedGeneration = decoded.stateGeneration
        }
    }

    private func evidenceLocked(tokenDigest: String) -> GitWorktreeRetirementEvidence? {
        for record in state.recordsByWorktreeID.values {
            switch record {
            case let .retired(evidence), let .blockedResidue(evidence):
                if evidence.consumedAuthorizationDigest == tokenDigest
                    || evidence.cleanupAuthorizationDigest == tokenDigest
                {
                    return evidence
                }
            case .draining, .cleanupDraining, .cleanupAuthorized, .authorized, .applying:
                continue
            }
        }
        return nil
    }

    private func blockPreparationLocked(
        _ preparation: GitWorktreeRetirementPreparation,
        reason: String,
        now: Date
    ) throws {
        guard case let .draining(record)? = state.recordsByWorktreeID[preparation.candidate.worktreeID] else { return }
        let evidence = Self.blockedEvidence(
            preparation: record,
            target: nil,
            drain: nil,
            reason: reason,
            now: now
        )
        try transitionAndPersistLocked {
            $0.recordsByWorktreeID[preparation.candidate.worktreeID] = .blockedResidue(evidence)
        }
        operationLeasesByWorktreeID.removeValue(forKey: preparation.candidate.worktreeID)?.release()
    }

    private func loadPersistentState() throws {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        let data: Data
        do { data = try Data(contentsOf: persistenceURL, options: .mappedIfSafe) } catch {
            throw GitWorktreeRetirementError.corruptPersistentState(error.localizedDescription)
        }
        let decoded: PersistedState
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoded = try decoder.decode(PersistedState.self, from: data)
        } catch {
            throw GitWorktreeRetirementError.corruptPersistentState(error.localizedDescription)
        }
        guard decoded.schemaLineage == Self.schemaLineage,
              decoded.schemaVersion == Self.schemaVersion
        else {
            throw GitWorktreeRetirementError.corruptPersistentState(
                "unsupported lineage/version \(decoded.schemaLineage)/\(decoded.schemaVersion)"
            )
        }
        state = decoded
    }

    private func recoverInterruptedState(now: Date = Date()) throws {
        var changed = false
        for (worktreeID, record) in state.recordsByWorktreeID {
            switch record {
            case let .draining(preparation):
                state.recordsByWorktreeID[worktreeID] = .blockedResidue(
                    Self.blockedEvidence(
                        preparation: preparation,
                        target: nil,
                        drain: nil,
                        reason: "App restarted while retirement drain was in progress.",
                        now: now
                    )
                )
                changed = true
            case .cleanupDraining:
                state.recordsByWorktreeID.removeValue(forKey: worktreeID)
                changed = true
            case let .cleanupAuthorized(authorization) where now > authorization.expiresAt:
                state.recordsByWorktreeID[worktreeID] = .blockedResidue(
                    Self.blockedEvidence(
                        cleanupAuthorization: authorization,
                        reason: GitWorktreeRetirementError.cleanupAuthorizationExpired.localizedDescription,
                        now: now
                    )
                )
                changed = true
            case let .applying(applying):
                state.recordsByWorktreeID[worktreeID] = .blockedResidue(
                    Self.makeEvidence(
                        state: .blockedResidue,
                        reason: "App restarted after durable authorization consumption; physical outcome requires external inspection.",
                        authorization: applying.authorization,
                        consumedAt: applying.consumedAt,
                        gitRemoveExitCode: nil,
                        postconditions: .unknown,
                        now: now
                    )
                )
                changed = true
            case let .authorized(authorization) where now > authorization.expiresAt:
                state.recordsByWorktreeID[worktreeID] = .blockedResidue(
                    Self.blockedEvidence(
                        authorization: authorization,
                        reason: GitWorktreeRetirementError.authorizationExpired.localizedDescription,
                        now: now
                    )
                )
                changed = true
            case .cleanupAuthorized, .authorized, .retired, .blockedResidue:
                continue
            }
        }
        if changed {
            state.stateGeneration &+= 1
            do {
                try persistLocked(expectedOnDiskGeneration: lastPersistedGeneration)
                lastPersistedGeneration = state.stateGeneration
            } catch {
                markPersistenceAmbiguousLocked(error)
                throw error
            }
        }
    }

    private func persistLocked(expectedOnDiskGeneration: UInt64) throws {
        let directory = persistenceURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let fileLease = try GitWorktreeRetirementFileLease.acquire(at: persistenceLockURL, nonBlocking: false)
            defer { fileLease.release() }
            let onDiskGeneration: UInt64
            if FileManager.default.fileExists(atPath: persistenceURL.path) {
                let diskData = try Data(contentsOf: persistenceURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let diskState = try decoder.decode(PersistedState.self, from: diskData)
                guard diskState.schemaLineage == Self.schemaLineage,
                      diskState.schemaVersion == Self.schemaVersion
                else {
                    throw GitWorktreeRetirementError.corruptPersistentState(
                        "unsupported state encountered while persisting"
                    )
                }
                onDiskGeneration = diskState.stateGeneration
            } else {
                onDiskGeneration = 0
            }
            guard onDiskGeneration == expectedOnDiskGeneration else {
                throw GitWorktreeRetirementError.corruptPersistentState(
                    "concurrent state generation changed from \(expectedOnDiskGeneration) to \(onDiskGeneration)"
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            let temporary = directory.appendingPathComponent(".\(persistenceURL.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else { throw GitWorktreeRetirementError.persistenceFailed("could not create temporary state file") }
            let file = try FileHandle(forWritingTo: temporary)
            try file.synchronize()
            try file.close()
            guard rename(temporary.path, persistenceURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { _ = close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch let error as GitWorktreeRetirementError {
            throw error
        } catch {
            throw GitWorktreeRetirementError.persistenceFailed(error.localizedDescription)
        }
    }

    private func transitionAndPersistLocked(
        _ transition: (inout PersistedState) -> Void
    ) throws {
        let expectedGeneration = lastPersistedGeneration
        transition(&state)
        state.stateGeneration &+= 1
        do {
            try persistLocked(expectedOnDiskGeneration: expectedGeneration)
            lastPersistedGeneration = state.stateGeneration
        } catch {
            markPersistenceAmbiguousLocked(error)
            throw error
        }
    }

    private func markPersistenceAmbiguousLocked(_ error: Error) {
        loadFailure = .persistenceFailed(
            "ambiguous durable outcome; authority is permanently fail-closed until restart: \(error.localizedDescription)"
        )
    }

    private static func defaultPersistenceURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("git-worktree-retirement-v3.json", isDirectory: false)
    }

    private static func canonicalPath(_ path: String) -> String {
        var components: [String] = []
        for component in (path as NSString).pathComponents where component != "/" && component != "." {
            if component == ".." {
                _ = components.popLast()
            } else {
                components.append(component)
            }
        }
        var probe = "/" + components.joined(separator: "/")
        for alias in ["/var", "/tmp", "/etc"] where probe == alias || probe.hasPrefix(alias + "/") {
            probe = "/private" + probe
            break
        }
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: probe), probe != "/" {
            suffix.insert(URL(fileURLWithPath: probe).lastPathComponent, at: 0)
            probe = URL(fileURLWithPath: probe).deletingLastPathComponent().path
        }
        guard let resolved = realpath(probe, nil) else { return probe }
        defer { free(resolved) }
        var canonical = String(cString: resolved)
        for component in suffix {
            canonical += "/" + component
        }
        return canonical
    }

    /// Shared workspace/resource canonicalizer. Retirement admission and every drain caller must
    /// use this exact symlink-resolving implementation so lexical aliases cannot evade the fence.
    static func canonicalWorkspacePath(_ path: String) -> String {
        canonicalPath(path)
    }

    static func workspacePathsIntersect(_ lhs: String, _ rhs: String) -> Bool {
        pathsIntersect(canonicalPath(lhs), canonicalPath(rhs))
    }

    static func workspacePath(_ candidate: String, isEqualOrDescendantOf root: String) -> Bool {
        isEqualOrDescendant(canonicalPath(candidate), of: canonicalPath(root))
    }

    private static func digest(_ value: String) -> String {
        GitWorktreeRetirementTarget.digest(value)
    }

    private static func identity(of record: Record) -> (repositoryID: String, canonicalPath: String) {
        switch record {
        case let .draining(value):
            (value.candidate.repositoryID, value.candidate.canonicalPath)
        case let .cleanupDraining(value):
            (value.target.repositoryID, value.target.canonicalPath)
        case let .cleanupAuthorized(value):
            (value.target.repositoryID, value.target.canonicalPath)
        case let .authorized(value):
            (value.target.repositoryID, value.target.canonicalPath)
        case let .applying(value):
            (value.authorization.target.repositoryID, value.authorization.target.canonicalPath)
        case let .blockedResidue(evidence), let .retired(evidence):
            (evidence.repositoryID, evidence.canonicalPath)
        }
    }

    private static func resource(
        _ resource: Resource,
        matches candidate: GitWorktreeRetirementCandidate,
        includeRepository: Bool
    ) -> Bool {
        switch resource {
        case let .binding(repositoryID, worktreeID, canonicalPath):
            let identityMatches = worktreeID == candidate.worktreeID
                || canonicalPath.map { isEqualOrDescendant($0, of: candidate.canonicalPath) } == true
            guard identityMatches else { return false }
            return repositoryID == nil || repositoryID == candidate.repositoryID
        case let .mutation(paths):
            return paths.contains { isEqualOrDescendant($0, of: candidate.canonicalPath) }
        case let .workspace(paths):
            return paths.contains { pathsIntersect($0, candidate.canonicalPath) }
        case let .git(path, commonGitDirectory, affectedWorktreeID, affectedPaths):
            if affectedWorktreeID == candidate.worktreeID { return true }
            if affectedPaths.contains(where: { isEqualOrDescendant($0, of: candidate.canonicalPath) }) { return true }
            if isEqualOrDescendant(path, of: candidate.canonicalPath) { return true }
            return includeRepository && commonGitDirectory == candidate.commonGitDirectory.canonicalPath
        }
    }

    private static func resource(_ resource: Resource, matchesPathOrID evidence: GitWorktreeRetirementEvidence) -> Bool {
        switch resource {
        case let .binding(repositoryID, worktreeID, canonicalPath):
            (
                worktreeID == evidence.worktreeID
                    || canonicalPath.map { isEqualOrDescendant($0, of: evidence.canonicalPath) } == true
            )
                && (repositoryID == nil || repositoryID == evidence.repositoryID)
        case let .mutation(paths):
            paths.contains { isEqualOrDescendant($0, of: evidence.canonicalPath) }
        case let .workspace(paths):
            paths.contains { pathsIntersect($0, evidence.canonicalPath) }
        case let .git(path, _, affectedWorktreeID, affectedPaths):
            affectedWorktreeID == evidence.worktreeID
                || affectedPaths.contains(where: { isEqualOrDescendant($0, of: evidence.canonicalPath) })
                || isEqualOrDescendant(path, of: evidence.canonicalPath)
        }
    }

    private static func isEqualOrDescendant(_ candidate: String, of root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func pathsIntersect(_ lhs: String, _ rhs: String) -> Bool {
        isEqualOrDescendant(lhs, of: rhs) || isEqualOrDescendant(rhs, of: lhs)
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
            ?? "development"
    }

    private static func evidenceID(tokenDigest: String, generation: UInt64) -> String {
        "retirement_\(digest("\(tokenDigest):\(generation)").prefix(24))"
    }

    private static func progress(of record: Record) -> GitWorktreeRetirementProgress? {
        switch record {
        case let .cleanupAuthorized(value):
            GitWorktreeRetirementProgress(
                phase: .cleanupAuthorized,
                tokenDigest: value.tokenDigest,
                cleanupAuthorizationDigest: value.tokenDigest,
                candidate: value.target.candidate,
                generation: value.target.generation,
                drain: value.drain,
                targetDigest: value.target.targetDigest,
                manifestDigest: nil,
                cleanupManifestDigest: value.cleanupManifestDigest,
                issuedAt: value.issuedAt,
                expiresAt: value.expiresAt
            )
        case let .authorized(value):
            GitWorktreeRetirementProgress(
                phase: .authorized,
                tokenDigest: value.tokenDigest,
                cleanupAuthorizationDigest: value.cleanupAuthorizationDigest,
                candidate: value.target.candidate,
                generation: value.target.generation,
                drain: value.drain,
                targetDigest: value.target.targetDigest,
                manifestDigest: value.target.contentManifestDigest,
                cleanupManifestDigest: value.cleanupManifestDigest,
                issuedAt: value.issuedAt,
                expiresAt: value.expiresAt
            )
        case let .applying(value):
            GitWorktreeRetirementProgress(
                phase: .applying,
                tokenDigest: value.authorization.tokenDigest,
                cleanupAuthorizationDigest: value.authorization.cleanupAuthorizationDigest,
                candidate: value.authorization.target.candidate,
                generation: value.authorization.target.generation,
                drain: value.authorization.drain,
                targetDigest: value.authorization.target.targetDigest,
                manifestDigest: value.authorization.target.contentManifestDigest,
                cleanupManifestDigest: value.authorization.cleanupManifestDigest,
                issuedAt: value.authorization.issuedAt,
                expiresAt: value.authorization.expiresAt
            )
        case .draining, .cleanupDraining, .retired, .blockedResidue:
            nil
        }
    }

    private static func blockedEvidence(
        preparation: PreparationRecord,
        target: GitWorktreeRetirementTarget?,
        drain: GitWorktreeRetirementDrainEvidence?,
        reason: String,
        now: Date
    ) -> GitWorktreeRetirementEvidence {
        GitWorktreeRetirementEvidence(
            evidenceID: evidenceID(tokenDigest: preparation.tokenDigest, generation: preparation.generation),
            state: .blockedResidue,
            reason: reason,
            authorityScope: authorityScope,
            appVersion: appVersion(),
            operationVersion: operationVersion,
            generation: preparation.generation,
            repositoryID: preparation.candidate.repositoryID,
            repositoryRoot: preparation.candidate.repositoryRoot.registeredPath,
            attestedIdentity: .init(
                repositoryRoot: preparation.candidate.repositoryRoot,
                commonGitDirectory: preparation.candidate.commonGitDirectory,
                worktreeParentDirectory: preparation.candidate.worktreeParentDirectory,
                worktreeDirectory: preparation.candidate.worktreeDirectory,
                gitDirectoryParent: preparation.candidate.gitDirectoryParent,
                gitDirectory: preparation.candidate.gitDirectory
            ),
            worktreeID: preparation.candidate.worktreeID,
            registeredPath: preparation.candidate.registeredPath,
            canonicalPath: preparation.candidate.canonicalPath,
            targetDigest: target?.targetDigest,
            manifestDigest: target?.contentManifestDigest,
            cleanupManifestDigest: nil,
            cleanupAuthorizationDigest: nil,
            consumedAuthorizationDigest: preparation.tokenDigest,
            drain: drain,
            mutation: .init(serializedExecutor: false, authorizationConsumedAt: nil, gitRemoveExitCode: nil),
            postconditions: .unknown,
            recordedAt: now
        )
    }

    private static func blockedEvidence(
        cleanupAuthorization: CleanupAuthorizationRecord,
        reason: String,
        now: Date
    ) -> GitWorktreeRetirementEvidence {
        let target = cleanupAuthorization.target
        return GitWorktreeRetirementEvidence(
            evidenceID: evidenceID(tokenDigest: cleanupAuthorization.tokenDigest, generation: target.generation),
            state: .blockedResidue,
            reason: reason,
            authorityScope: authorityScope,
            appVersion: appVersion(),
            operationVersion: operationVersion,
            generation: target.generation,
            repositoryID: target.repositoryID,
            repositoryRoot: target.repositoryRoot,
            attestedIdentity: .init(
                repositoryRoot: target.candidate.repositoryRoot,
                commonGitDirectory: target.candidate.commonGitDirectory,
                worktreeParentDirectory: target.candidate.worktreeParentDirectory,
                worktreeDirectory: target.candidate.worktreeDirectory,
                gitDirectoryParent: target.candidate.gitDirectoryParent,
                gitDirectory: target.candidate.gitDirectory
            ),
            worktreeID: target.worktreeID,
            registeredPath: target.path,
            canonicalPath: target.canonicalPath,
            targetDigest: target.targetDigest,
            manifestDigest: nil,
            cleanupManifestDigest: cleanupAuthorization.cleanupManifestDigest,
            cleanupAuthorizationDigest: cleanupAuthorization.tokenDigest,
            consumedAuthorizationDigest: cleanupAuthorization.tokenDigest,
            drain: cleanupAuthorization.drain,
            mutation: .init(serializedExecutor: false, authorizationConsumedAt: nil, gitRemoveExitCode: nil),
            postconditions: .unknown,
            recordedAt: now
        )
    }

    private static func blockedEvidence(
        authorization: AuthorizationRecord,
        reason: String,
        now: Date
    ) -> GitWorktreeRetirementEvidence {
        makeEvidence(
            state: .blockedResidue,
            reason: reason,
            authorization: authorization,
            consumedAt: nil,
            gitRemoveExitCode: nil,
            postconditions: .unknown,
            now: now
        )
    }

    private static func makeEvidence(
        state: GitWorktreeRetirementEvidence.State,
        reason: String?,
        authorization: AuthorizationRecord,
        consumedAt: Date?,
        gitRemoveExitCode: Int32?,
        postconditions: GitWorktreeRetirementPostconditions,
        now: Date
    ) -> GitWorktreeRetirementEvidence {
        let target = authorization.target
        return GitWorktreeRetirementEvidence(
            evidenceID: evidenceID(tokenDigest: authorization.tokenDigest, generation: target.generation),
            state: state,
            reason: reason,
            authorityScope: authorityScope,
            appVersion: appVersion(),
            operationVersion: operationVersion,
            generation: target.generation,
            repositoryID: target.repositoryID,
            repositoryRoot: target.repositoryRoot,
            attestedIdentity: .init(
                repositoryRoot: target.candidate.repositoryRoot,
                commonGitDirectory: target.candidate.commonGitDirectory,
                worktreeParentDirectory: target.candidate.worktreeParentDirectory,
                worktreeDirectory: target.candidate.worktreeDirectory,
                gitDirectoryParent: target.candidate.gitDirectoryParent,
                gitDirectory: target.candidate.gitDirectory
            ),
            worktreeID: target.worktreeID,
            registeredPath: target.path,
            canonicalPath: target.canonicalPath,
            targetDigest: target.targetDigest,
            manifestDigest: target.contentManifestDigest,
            cleanupManifestDigest: authorization.cleanupManifestDigest,
            cleanupAuthorizationDigest: authorization.cleanupAuthorizationDigest,
            consumedAuthorizationDigest: authorization.tokenDigest,
            drain: authorization.drain,
            mutation: .init(
                serializedExecutor: consumedAt != nil,
                authorizationConsumedAt: consumedAt,
                gitRemoveExitCode: gitRemoveExitCode
            ),
            postconditions: postconditions,
            recordedAt: now
        )
    }
}

enum GitWorktreeRetirementStatusInspector {
    static func requireClean(_ data: Data) throws {
        guard data.last == 0 || data.isEmpty else {
            throw GitWorktreeRetirementError.dirtyWorktree
        }
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard record.count >= 3, record[record.startIndex.advanced(by: 2)] == 0x20 else {
                throw GitWorktreeRetirementError.dirtyWorktree
            }
            let x = record[record.startIndex]
            let y = record[record.startIndex.advanced(by: 1)]
            if x == 0x21, y == 0x21 {
                throw GitWorktreeRetirementError.ignoredContent
            }
            throw GitWorktreeRetirementError.dirtyWorktree
        }
    }
}

enum GitWorktreeRetirementPathInspector {
    static func requireAbsentNoFollow(_ path: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return false }
        if errno == ENOENT || errno == ENOTDIR { return true }
        throw GitWorktreeRetirementError.postconditionFailed(
            "lstat failed for \(path): \(String(cString: strerror(errno)))"
        )
    }
}

enum GitWorktreeRetirementManifest {
    static func digestDirectory(at root: URL) throws -> String {
        let rootIdentity = try GitWorktreeRetirementDirectoryIdentity(path: root.path)
        let rootURL = URL(fileURLWithPath: rootIdentity.registeredPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var entries: [URL] = []
        var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw GitWorktreeRetirementError.missingIdentityEvidence(root.path) }
        for case let url as URL in enumerator {
            entries.append(url)
        }
        if let enumerationError { throw enumerationError }
        entries.sort { $0.path < $1.path }

        var hasher = SHA256()
        for url in entries {
            let relative = String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let values = try url.resourceValues(forKeys: Set(keys))
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw GitWorktreeRetirementError.missingIdentityEvidence(url.path)
            }
            if values.isSymbolicLink == true || info.st_mode & S_IFMT == S_IFLNK {
                throw GitWorktreeRetirementError.symlinkIdentityEvidence(url.path)
            }
            let mode = UInt32(info.st_mode)
            if values.isDirectory == true {
                hasher.update(data: Data("D\u{0}\(relative)\u{0}\(mode)\u{0}".utf8))
                continue
            }
            guard values.isRegularFile == true else {
                throw GitWorktreeRetirementError.missingIdentityEvidence(url.path)
            }
            hasher.update(data: Data("F\u{0}\(relative)\u{0}\(mode)\u{0}\(values.fileSize ?? -1)\u{0}".utf8))
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum GitWorktreeRetirementOperationInspector {
    private static let operationMarkers = [
        "MERGE_HEAD",
        "rebase-merge",
        "rebase-apply",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "BISECT_LOG",
        "BISECT_START",
        "sequencer"
    ]

    static func activeOperationCount(gitDirectory: URL, commonGitDirectory: URL) throws -> Int {
        let directories = Set([gitDirectory.standardizedFileURL, commonGitDirectory.standardizedFileURL])
        var activePaths = Set<String>()
        for directory in directories {
            _ = try GitWorktreeRetirementDirectoryIdentity(path: directory.path)
            for marker in operationMarkers {
                let path = directory.appendingPathComponent(marker).standardizedFileURL.path
                if FileManager.default.fileExists(atPath: path) { activePaths.insert(path) }
            }
            var enumerationError: (any Error)?
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw GitWorktreeRetirementError.missingIdentityEvidence(directory.path)
            }
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".lock") {
                // RepoPrompt's own long-lived serialization lock is evidence of the
                // retirement transaction, not an independently active Git operation.
                if url.lastPathComponent != "repoprompt-retirement.lock" {
                    activePaths.insert(url.standardizedFileURL.path)
                }
            }
            if let enumerationError { throw enumerationError }
        }
        return activePaths.count
    }
}
