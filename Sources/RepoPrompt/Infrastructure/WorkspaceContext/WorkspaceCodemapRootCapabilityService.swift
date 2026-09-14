import CryptoKit
import Darwin
import Foundation

struct WorkspaceCodemapPathFingerprintClient {
    let fingerprint: @Sendable (_ repositoryRoot: URL, _ repositoryRelativePath: String) throws
        -> GitBlobLStatFingerprint

    static let noFollow = WorkspaceCodemapPathFingerprintClient { repositoryRoot, relativePath in
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") })
        else {
            throw POSIXError(.EINVAL)
        }

        let rootDescriptor = open(
            repositoryRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var directoryDescriptor = rootDescriptor
        defer { close(directoryDescriptor) }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString { name in
                openat(
                    directoryDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        var value = stat()
        let status = components.last!.withCString { name in
            fstatat(directoryDescriptor, name, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return GitBlobLStatFingerprint(
            device: safeDeviceID(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt16(value.st_mode),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }
}

/// Mode-specific source evidence retained by an issued source-authority token.
///
/// Git keeps the repository coordinates and per-candidate attribute proof its locator, manifest and
/// materialization paths already depend on. Filesystem sources have no Git fields and no attribute
/// sentinel, so an accidental Git obligation cannot silently pass on a filesystem token.
enum WorkspaceCodemapSourceAuthorityEvidence: Hashable {
    case git(
        repositoryRelativeLoadedRootPrefix: String,
        standardizedRepositoryRelativePath: String,
        candidateAttributeGeneration: String
    )
    case filesystem
}

struct WorkspaceCodemapSourceAuthorityToken: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let rootAuthority: WorkspaceCodemapRootAuthorityToken
    let standardizedLoadedRootPath: String
    let candidateRootRelativePath: String
    let acceptedPrePathFingerprint: GitBlobLStatFingerprint
    let acceptedPostPathFingerprint: GitBlobLStatFingerprint
    let evidence: WorkspaceCodemapSourceAuthorityEvidence
    let pathGeneration: UInt64
    let ingressGeneration: UInt64

    var gitAuthority: WorkspaceCodemapRepositoryAuthorityToken? {
        rootAuthority.gitAuthority
    }

    var repositoryRelativeLoadedRootPrefix: String? {
        guard case let .git(prefix, _, _) = evidence else { return nil }
        return prefix
    }

    var standardizedRepositoryRelativePath: String? {
        guard case let .git(_, path, _) = evidence else { return nil }
        return path
    }

    var candidateAttributeGeneration: String? {
        guard case let .git(_, _, generation) = evidence else { return nil }
        return generation
    }

    var isFactoryValidated: Bool {
        guard acceptedPrePathFingerprint == acceptedPostPathFingerprint,
              acceptedPostPathFingerprint.isRegularFile,
              Self.standardizedAbsoluteRootPath(standardizedLoadedRootPath) == standardizedLoadedRootPath,
              Self.standardizedSafeRelativePath(candidateRootRelativePath) == candidateRootRelativePath
        else { return false }
        switch (rootAuthority, evidence) {
        case let (.git, .git(prefix, repositoryRelativePath, attributeGeneration)):
            return !attributeGeneration.isEmpty &&
                Self.standardizedPrefix(prefix) == prefix &&
                Self.repositoryRelativePath(
                    rootRelativePath: candidateRootRelativePath,
                    prefix: prefix
                ) == repositoryRelativePath
        case (.filesystem, .filesystem):
            return true
        case (.git, .filesystem), (.filesystem, .git):
            return false
        }
    }

    private init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        rootAuthority: WorkspaceCodemapRootAuthorityToken,
        standardizedLoadedRootPath: String,
        candidateRootRelativePath: String,
        acceptedPrePathFingerprint: GitBlobLStatFingerprint,
        acceptedPostPathFingerprint: GitBlobLStatFingerprint,
        evidence: WorkspaceCodemapSourceAuthorityEvidence,
        pathGeneration: UInt64,
        ingressGeneration: UInt64
    ) {
        self.rootEpoch = rootEpoch
        self.rootAuthority = rootAuthority
        self.standardizedLoadedRootPath = standardizedLoadedRootPath
        self.candidateRootRelativePath = candidateRootRelativePath
        self.acceptedPrePathFingerprint = acceptedPrePathFingerprint
        self.acceptedPostPathFingerprint = acceptedPostPathFingerprint
        self.evidence = evidence
        self.pathGeneration = pathGeneration
        self.ingressGeneration = ingressGeneration
    }

    fileprivate static func issue(
        capability: WorkspaceCodemapRootCapability,
        observedRootEpoch: WorkspaceCodemapRootEpoch,
        observedRootAuthority: WorkspaceCodemapRootAuthorityToken,
        standardizedLoadedRootPath: String,
        candidateRootRelativePath: String,
        acceptedPrePathFingerprint: GitBlobLStatFingerprint,
        acceptedPostPathFingerprint: GitBlobLStatFingerprint,
        candidateAttributeGeneration: String?,
        observedPathGeneration: UInt64,
        currentPathGeneration: UInt64,
        observedIngressGeneration: UInt64,
        currentIngressGeneration: UInt64
    ) -> WorkspaceCodemapSourceAuthorityToken? {
        guard capability.rootEpoch == observedRootEpoch,
              capability.rootAuthority == observedRootAuthority,
              acceptedPrePathFingerprint == acceptedPostPathFingerprint,
              acceptedPostPathFingerprint.isRegularFile,
              observedPathGeneration == currentPathGeneration,
              observedIngressGeneration == currentIngressGeneration,
              let rootPath = standardizedAbsoluteRootPath(standardizedLoadedRootPath),
              rootPath == capability.loadedRootURL.path,
              let rootRelativePath = standardizedSafeRelativePath(candidateRootRelativePath)
        else { return nil }

        let evidence: WorkspaceCodemapSourceAuthorityEvidence
        switch capability {
        case let .git(gitCapability):
            guard gitCapability.repositoryNamespace == gitCapability.repositoryAuthority.repositoryNamespace,
                  gitCapability.objectFormat == gitCapability.repositoryAuthority.objectFormat,
                  let attributeGeneration = candidateAttributeGeneration,
                  !attributeGeneration.isEmpty,
                  let prefix = standardizedPrefix(gitCapability.repositoryRelativeLoadedRootPrefix),
                  let repositoryRelativePath = repositoryRelativePath(
                      rootRelativePath: rootRelativePath,
                      prefix: prefix
                  )
            else { return nil }
            evidence = .git(
                repositoryRelativeLoadedRootPrefix: prefix,
                standardizedRepositoryRelativePath: repositoryRelativePath,
                candidateAttributeGeneration: attributeGeneration
            )
        case .filesystem:
            guard candidateAttributeGeneration == nil else { return nil }
            evidence = .filesystem
        }

        return WorkspaceCodemapSourceAuthorityToken(
            rootEpoch: observedRootEpoch,
            rootAuthority: observedRootAuthority,
            standardizedLoadedRootPath: rootPath,
            candidateRootRelativePath: rootRelativePath,
            acceptedPrePathFingerprint: acceptedPrePathFingerprint,
            acceptedPostPathFingerprint: acceptedPostPathFingerprint,
            evidence: evidence,
            pathGeneration: observedPathGeneration,
            ingressGeneration: observedIngressGeneration
        )
    }

    private static func standardizedAbsoluteRootPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !StandardizedPath.containsNUL(path) else { return nil }
        return StandardizedPath.absolute(path)
    }

    private static func standardizedSafeRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !StandardizedPath.containsNUL(path) else { return nil }
        let standardized = StandardizedPath.relative(path)
        guard standardized != ".", standardized != "..", !standardized.hasPrefix("../") else { return nil }
        return standardized
    }

    private static func standardizedPrefix(_ prefix: String) -> String? {
        if prefix.isEmpty { return "" }
        return standardizedSafeRelativePath(prefix)
    }

    /// Git is the only mode with repository coordinates, so translation stays confined here.
    fileprivate static func repositoryRelativePath(
        rootRelativePath: String,
        prefix: String
    ) -> String? {
        guard let path = standardizedSafeRelativePath(rootRelativePath) else { return nil }
        guard !prefix.isEmpty else { return path }
        guard let standardizedPrefix = standardizedPrefix(prefix) else { return nil }
        return standardizedSafeRelativePath(standardizedPrefix + "/" + path)
    }
}

/// Process-free classification evidence for one filesystem root.
///
/// Only `WorkspaceCodemapRootCapabilityService.filesystemClassificationEvidence(for:)` can build
/// this value: the initializer is file-private, so no caller outside the capability actor can
/// manufacture permission to classify without a Git process. The classifier re-observes the proof
/// before and after it works, and fails closed rather than falling back to Git discovery.
struct WorkspaceCodemapFilesystemClassificationEvidence {
    let capability: WorkspaceCodemapFilesystemRootCapability
    let proof: WorkspaceCodemapNonGitFilesystemProof
    private let classificationProbe: WorkspaceCodemapLocalGitClassificationProbe

    fileprivate init(
        capability: WorkspaceCodemapFilesystemRootCapability,
        proof: WorkspaceCodemapNonGitFilesystemProof,
        classificationProbe: WorkspaceCodemapLocalGitClassificationProbe
    ) {
        self.capability = capability
        self.proof = proof
        self.classificationProbe = classificationProbe
    }

    /// Re-observes the retained proof. Returns the fresh proof only while the same semantic
    /// binding still holds; a changed binding or lost proof yields nil.
    func currentProof() -> WorkspaceCodemapNonGitFilesystemProof? {
        classificationProbe.refresh(proof).currentProof
    }
}

struct WorkspaceCodemapSourceAuthorityRequest: Hashable {
    let candidateRootRelativePath: String
    let observedPathGeneration: UInt64
    let currentPathGeneration: UInt64
    let observedIngressGeneration: UInt64
    let currentIngressGeneration: UInt64
}

enum WorkspaceCodemapSourceAuthorityRejection: Equatable {
    enum CapturePhase: Equatable {
        case preRepository
        case postRepository
    }

    case requestUnavailable
    case candidateRequestRejected(index: Int)
    case candidateFingerprintUnavailable(index: Int)
    case candidateAttributesChanged(index: Int)
    case candidatePathChanged(index: Int)
    case registrationAuthorityChanged
    case repositoryAuthorityChangedDuringIssuance
    case capabilityChanged
    case tokenIssuanceRejected(index: Int)
    case cancelled
    case captureFailed(
        phase: CapturePhase,
        reason: WorkspaceCodemapRootTransientUnavailableReason
    )
}

struct WorkspaceCodemapRootCapabilityServiceHooks {
    var beforeResolution: @Sendable () async -> Void
    var afterFirstAuthorityCapture: @Sendable () async -> Void
    var afterSourcePathFingerprintCapture: @Sendable () async -> Void
    var afterAuthorityEvidenceOpen: @Sendable (URL) -> Void
    var sourceAuthorityRejected: @Sendable (WorkspaceCodemapSourceAuthorityRejection) -> Void

    init(
        beforeResolution: @escaping @Sendable () async -> Void = {},
        afterFirstAuthorityCapture: @escaping @Sendable () async -> Void = {},
        afterSourcePathFingerprintCapture: @escaping @Sendable () async -> Void = {},
        afterAuthorityEvidenceOpen: @escaping @Sendable (URL) -> Void = { _ in },
        sourceAuthorityRejected: @escaping @Sendable (WorkspaceCodemapSourceAuthorityRejection) -> Void = { _ in }
    ) {
        self.beforeResolution = beforeResolution
        self.afterFirstAuthorityCapture = afterFirstAuthorityCapture
        self.afterSourcePathFingerprintCapture = afterSourcePathFingerprintCapture
        self.afterAuthorityEvidenceOpen = afterAuthorityEvidenceOpen
        self.sourceAuthorityRejected = sourceAuthorityRejected
    }

    static let none = WorkspaceCodemapRootCapabilityServiceHooks()
}

actor WorkspaceCodemapRootCapabilityService {
    #if DEBUG
        struct Snapshot: Equatable {
            let activeRecordCount: Int
            let historicalRecordCount: Int
            let activeFlightCount: Int
            let waiterCount: Int
            let resolutionObserverCount: Int
            let authorityCaptureCount: UInt64
        }
    #endif

    private struct StableAuthority: Hashable {
        let repositoryNamespace: GitBlobRepositoryNamespace
        let objectFormat: GitObjectFormat
        let repositoryBindingEpoch: String
        let worktreeBindingEpoch: String
        let layoutGeneration: String
        let indexGeneration: String
        let checkoutConfigurationGeneration: String
        let attributeGeneration: String
        let sparseGeneration: String
        let metadataGeneration: String

        /// Per-file source-authority registration-to-demand windows prove the same repository/worktree
        /// binding, not the absence of root-wide Git cache or metadata churn since registration.
        /// Demand-window source and classification evidence is compared separately around issuance/revalidation.
        /// Full `StableAuthority` equality remains the root-authority advancement contract used by resolution.
        func matchesSourceAuthorityStability(of other: StableAuthority) -> Bool {
            repositoryNamespace == other.repositoryNamespace &&
                objectFormat == other.objectFormat &&
                repositoryBindingEpoch == other.repositoryBindingEpoch &&
                worktreeBindingEpoch == other.worktreeBindingEpoch
        }
    }

    private struct SourceClassificationEvidence: Equatable {
        let globalAttributeGeneration: String
        let checkoutConfigurationValuesGeneration: String
    }

    private struct AuthorityCapture: Equatable {
        let layout: GitRepositoryLayout
        let objectFormat: GitObjectFormat
        let stableAuthority: StableAuthority
        let sourceClassificationEvidence: SourceClassificationEvidence

        func matchesSourceAuthorityStability(of other: AuthorityCapture) -> Bool {
            layout == other.layout &&
                objectFormat == other.objectFormat &&
                stableAuthority.matchesSourceAuthorityStability(of: other.stableAuthority)
        }
    }

    private struct RootBinding: Hashable {
        let standardizedLoadedRootPath: String
        var repositoryID: String?
        var worktreeID: String?
    }

    private struct RootRecord {
        var state: WorkspaceCodemapRootCapabilityState = .unresolved
        var resolutionGeneration: UInt64 = 0
        var authorityGeneration: UInt64 = 0
        var stableAuthority: StableAuthority?
        /// Full filesystem proof behind a filesystem capability. It stays private to the actor and
        /// never enters capability or token equality; only the compact generation does.
        var filesystemProof: WorkspaceCodemapNonGitFilesystemProof?
        var binding: RootBinding
        var retainedWorkTreeRoot: URL?
        var retainedGitDirectory: URL?
    }

    private struct RootFlight {
        let id: UUID
        let resolutionGeneration: UInt64
        let priorState: WorkspaceCodemapRootCapabilityState
        let task: Task<Resolution, Never>
        var waiters: [UUID: CheckedContinuation<WorkspaceCodemapRootCapabilityState, Never>]
    }

    private struct HistoricalRecord {
        let binding: RootBinding
        let finalState: WorkspaceCodemapRootCapabilityState
        let releaseOrdinal: UInt64
    }

    private struct RetainedReplacementState {
        var authorityGeneration: UInt64
        var binding: RootBinding
    }

    private enum Resolution {
        case eligibleGit(
            layout: GitRepositoryLayout,
            prefix: String,
            repositoryIdentity: GitWorktreeRepositoryIdentity,
            worktreeID: String,
            authority: StableAuthority
        )
        case eligibleFilesystem(WorkspaceCodemapNonGitFilesystemProof)
        case terminal(WorkspaceCodemapRootTerminalUnavailableReason)
        case transient(WorkspaceCodemapRootTransientUnavailableReason)
    }

    private let gitService: GitService
    private let namespaceSalt: Data
    private let hooks: WorkspaceCodemapRootCapabilityServiceHooks
    private let localClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe
    private let pathFingerprintClient: WorkspaceCodemapPathFingerprintClient
    private let historicalRecordLimit: Int
    private var records: [WorkspaceCodemapRootEpoch: RootRecord] = [:]
    private var flights: [WorkspaceCodemapRootEpoch: RootFlight] = [:]
    private var resolutionObservers: [UUID: Task<Void, Never>] = [:]
    private var rootEpochByWaiterID: [UUID: WorkspaceCodemapRootEpoch] = [:]
    private var historicalRecords: [WorkspaceCodemapRootEpoch: HistoricalRecord] = [:]
    /// State preserved across non-tombstoning authority replacement, keyed by root epoch.
    ///
    /// `invalidateForAuthorityReplacement` deletes the root record, so the record-local counter
    /// alone would restart at 1 and let a replacement authority collide with a revoked one. This
    /// keeps generations strictly increasing for one root lifetime, including a filesystem → Git →
    /// filesystem sequence. It also retains the removed record's binding so a `release` arriving
    /// inside the replacement gap can still terminalize the epoch. Terminal `release` clears it,
    /// because that ends the lifetime.
    private var retainedReplacementStatesByRootEpoch: [WorkspaceCodemapRootEpoch: RetainedReplacementState] = [:]
    private var releaseOrdinal: UInt64 = 0
    #if DEBUG
        private var authorityCaptureCount: UInt64 = 0
    #endif

    init(
        gitService: GitService = GitService(),
        namespaceSalt: Data,
        hooks: WorkspaceCodemapRootCapabilityServiceHooks = .none,
        localClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .production,
        pathFingerprintClient: WorkspaceCodemapPathFingerprintClient = .noFollow,
        historicalRecordLimit: Int = 64
    ) {
        precondition(historicalRecordLimit > 0)
        self.gitService = gitService
        self.namespaceSalt = namespaceSalt
        self.hooks = hooks
        self.localClassificationProbe = localClassificationProbe
        self.pathFingerprintClient = pathFingerprintClient
        self.historicalRecordLimit = historicalRecordLimit
    }

    nonisolated static func eligibilityPreflight(
        gitService: GitService,
        loadedRootURL: URL
    ) async -> WorkspaceCodemapGitEligibilityPreflightResult {
        let loadedRoot = loadedRootURL.standardizedFileURL
        guard loadedRoot.isFileURL, loadedRoot.path.hasPrefix("/") else {
            return .terminalUnavailable(.invalidLoadedRootContainment)
        }
        switch directoryState(at: loadedRoot) {
        case .valid:
            break
        case .missing:
            return .transientUnavailable(.repositoryChanging)
        case .permissionDenied:
            return .transientUnavailable(.permissionFailure)
        case .invalid:
            return .terminalUnavailable(.invalidLoadedRootContainment)
        }

        do {
            if try await gitService.findGitRoot(from: loadedRoot) != nil {
                return .eligible
            }
            return switch try await gitService.gitRepositoryKind(at: loadedRoot) {
            case .nonGit:
                .terminalUnavailable(.nonGit)
            case .bare:
                .terminalUnavailable(.bareRepository)
            case .worktree:
                .terminalUnavailable(.invalidLayout)
            }
        } catch {
            return .transientUnavailable(transientReason(for: error))
        }
    }

    func state(for rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapRootCapabilityState {
        if let state = records[rootEpoch]?.state { return state }
        if historicalRecords[rootEpoch] != nil { return .terminalUnavailable(.releasedRootEpoch) }
        return .unresolved
    }

    @discardableResult
    func resolve(
        root request: WorkspaceCodemapRootCapabilityRequest,
        evidence: WorkspaceCodemapRootEligibilityEvidence? = nil
    ) async -> WorkspaceCodemapRootCapabilityState {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(
                    waiterID: waiterID,
                    request: request,
                    evidence: evidence,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    @discardableResult
    func reload(
        root request: WorkspaceCodemapRootCapabilityRequest,
        evidence: WorkspaceCodemapRootEligibilityEvidence? = nil
    ) async -> WorkspaceCodemapRootCapabilityState {
        guard historicalRecords[request.rootEpoch] == nil else {
            return .terminalUnavailable(.releasedRootEpoch)
        }
        if var record = records[request.rootEpoch] {
            guard record.binding.standardizedLoadedRootPath == request.loadedRootURL.path else {
                return .terminalUnavailable(.rootEpochBindingMismatch)
            }
            cancelFlight(for: request.rootEpoch, restoring: record.state)
            record = records[request.rootEpoch] ?? record
            if case .terminalUnavailable = record.state {
                record.state = .unresolved
                records[request.rootEpoch] = record
            }
        }
        return await resolve(root: request, evidence: evidence)
    }

    @discardableResult
    func retarget(
        from oldRootEpoch: WorkspaceCodemapRootEpoch,
        to request: WorkspaceCodemapRootCapabilityRequest,
        evidence: WorkspaceCodemapRootEligibilityEvidence? = nil
    ) async -> WorkspaceCodemapRootCapabilityState {
        await release(rootEpoch: oldRootEpoch)
        return await resolve(root: request, evidence: evidence)
    }

    func invalidateForAuthorityReplacement(rootEpoch: WorkspaceCodemapRootEpoch) async {
        cancelFlight(for: rootEpoch, restoring: .unresolved)
        guard let record = records.removeValue(forKey: rootEpoch) else { return }
        retainedReplacementStatesByRootEpoch[rootEpoch] = RetainedReplacementState(
            authorityGeneration: max(
                retainedReplacementStatesByRootEpoch[rootEpoch]?.authorityGeneration ?? 0,
                record.authorityGeneration
            ),
            binding: record.binding
        )
        if let workTreeRoot = record.retainedWorkTreeRoot,
           let gitDirectory = record.retainedGitDirectory
        {
            await gitService.releaseRepositoryLayout(
                workTreeRoot: workTreeRoot,
                expectedGitDirectory: gitDirectory
            )
        }
    }

    func release(rootEpoch: WorkspaceCodemapRootEpoch) async {
        cancelFlight(for: rootEpoch, restoring: .unresolved)
        // A root released after authority replacement may have no record left, but its retained
        // generation must still be dropped: the next lifetime uses a different root epoch.
        let retained = retainedReplacementStatesByRootEpoch.removeValue(forKey: rootEpoch)
        guard let record = records.removeValue(forKey: rootEpoch) else {
            // Released inside the replacement gap. Dropping the retained generation without
            // recording the release would leave this epoch with neither a tombstone nor a
            // high-water mark, so a delayed resolve could reissue an authority that was already
            // revoked in this same lifetime. Terminalize it here instead.
            guard let retained, historicalRecords[rootEpoch] == nil else { return }
            releaseOrdinal &+= 1
            historicalRecords[rootEpoch] = HistoricalRecord(
                binding: retained.binding,
                finalState: .unresolved,
                releaseOrdinal: releaseOrdinal
            )
            evictReleasedHistoryIfNeeded()
            return
        }
        releaseOrdinal &+= 1
        historicalRecords[rootEpoch] = HistoricalRecord(
            binding: record.binding,
            finalState: record.state,
            releaseOrdinal: releaseOrdinal
        )
        evictReleasedHistoryIfNeeded()
        if let workTreeRoot = record.retainedWorkTreeRoot,
           let gitDirectory = record.retainedGitDirectory
        {
            await gitService.releaseRepositoryLayout(
                workTreeRoot: workTreeRoot,
                expectedGitDirectory: gitDirectory
            )
        }
    }

    func drain() async {
        while !resolutionObservers.isEmpty {
            let observers = Array(resolutionObservers.values)
            for observer in observers {
                await observer.value
            }
        }
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            Snapshot(
                activeRecordCount: records.count,
                historicalRecordCount: historicalRecords.count,
                activeFlightCount: flights.count,
                waiterCount: flights.values.reduce(0) { $0 + $1.waiters.count },
                resolutionObserverCount: resolutionObservers.count,
                authorityCaptureCount: authorityCaptureCount
            )
        }
    #endif

    private func enqueue(
        waiterID: UUID,
        request: WorkspaceCodemapRootCapabilityRequest,
        evidence: WorkspaceCodemapRootEligibilityEvidence?,
        continuation: CheckedContinuation<WorkspaceCodemapRootCapabilityState, Never>
    ) {
        if Task.isCancelled {
            continuation.resume(returning: state(for: request.rootEpoch))
            return
        }
        if historicalRecords[request.rootEpoch] != nil {
            continuation.resume(returning: .terminalUnavailable(.releasedRootEpoch))
            return
        }

        let loadedRootPath = request.loadedRootURL.path
        var record = records[request.rootEpoch] ?? RootRecord(
            authorityGeneration: retainedReplacementStatesByRootEpoch[request.rootEpoch]?
                .authorityGeneration ?? 0,
            binding: RootBinding(
                standardizedLoadedRootPath: loadedRootPath,
                repositoryID: nil,
                worktreeID: nil
            )
        )
        guard record.binding.standardizedLoadedRootPath == loadedRootPath else {
            continuation.resume(returning: .terminalUnavailable(.rootEpochBindingMismatch))
            return
        }
        if case .terminalUnavailable = record.state {
            continuation.resume(returning: record.state)
            return
        }
        if var flight = flights[request.rootEpoch] {
            flight.waiters[waiterID] = continuation
            flights[request.rootEpoch] = flight
            rootEpochByWaiterID[waiterID] = request.rootEpoch
            return
        }

        let priorState = Self.restorableState(record.state)
        record.resolutionGeneration &+= 1
        let generation = record.resolutionGeneration
        record.state = .resolving(generation: generation)
        records[request.rootEpoch] = record

        let flightID = UUID()
        let loadedRootURL = request.loadedRootURL
        let task = Task(priority: Task.currentPriority) { [weak self] in
            guard let self else { return Resolution.transient(.runtimeUnavailable) }
            await hooks.beforeResolution()
            if Task.isCancelled { return .transient(.runtimeUnavailable) }
            return await resolveCandidate(loadedRootURL: loadedRootURL, evidence: evidence)
        }
        flights[request.rootEpoch] = RootFlight(
            id: flightID,
            resolutionGeneration: generation,
            priorState: priorState,
            task: task,
            waiters: [waiterID: continuation]
        )
        rootEpochByWaiterID[waiterID] = request.rootEpoch
        let observer = Task { [weak self] in
            let resolution = await task.value
            guard let self else { return }
            await complete(
                rootEpoch: request.rootEpoch,
                flightID: flightID,
                resolution: resolution
            )
            await finishResolutionObserver(flightID)
        }
        resolutionObservers[flightID] = observer
    }

    private func finishResolutionObserver(_ flightID: UUID) {
        resolutionObservers.removeValue(forKey: flightID)
    }

    private func cancelWaiter(id waiterID: UUID) {
        guard let rootEpoch = rootEpochByWaiterID.removeValue(forKey: waiterID),
              var flight = flights[rootEpoch],
              let continuation = flight.waiters.removeValue(forKey: waiterID)
        else { return }
        continuation.resume(returning: flight.priorState)
        if flight.waiters.isEmpty {
            flight.task.cancel()
            flights.removeValue(forKey: rootEpoch)
            if var record = records[rootEpoch],
               case .resolving(generation: flight.resolutionGeneration) = record.state
            {
                record.state = flight.priorState
                records[rootEpoch] = record
            }
        } else {
            flights[rootEpoch] = flight
        }
    }

    private func complete(
        rootEpoch: WorkspaceCodemapRootEpoch,
        flightID: UUID,
        resolution: Resolution
    ) async {
        guard let flight = flights[rootEpoch], flight.id == flightID,
              var record = records[rootEpoch],
              case .resolving(generation: flight.resolutionGeneration) = record.state
        else { return }

        if case let .eligibleGit(layout, _, _, _, _) = resolution,
           record.retainedWorkTreeRoot == nil
        {
            await gitService.retainRepositoryLayout(layout)
            guard let currentFlight = flights[rootEpoch], currentFlight.id == flightID,
                  let currentRecord = records[rootEpoch],
                  case .resolving(generation: flight.resolutionGeneration) = currentRecord.state
            else {
                await gitService.releaseRepositoryLayout(
                    workTreeRoot: layout.workTreeRoot,
                    expectedGitDirectory: layout.gitDir
                )
                return
            }
            record = currentRecord
            record.retainedWorkTreeRoot = layout.workTreeRoot
            record.retainedGitDirectory = layout.gitDir
        }
        flights.removeValue(forKey: rootEpoch)
        for waiterID in flight.waiters.keys {
            rootEpochByWaiterID.removeValue(forKey: waiterID)
        }

        switch resolution {
        case let .eligibleFilesystem(proof):
            // A filesystem root that previously bound to a Git repository, or to a different
            // filesystem object, is a binding change: revoke rather than silently continue.
            if record.binding.repositoryID != nil ||
                proof.requestedRootPath != record.binding.standardizedLoadedRootPath
            {
                record.state = .terminalUnavailable(.rootEpochBindingMismatch)
                break
            }
            let sameSemanticBinding = record.filesystemProof.map {
                WorkspaceCodemapLocalGitClassificationProbe.proofHasSameTopology($0, proof)
            } ?? false
            record.filesystemProof = proof
            record.stableAuthority = nil
            if !sameSemanticBinding {
                let (advanced, overflow) = record.authorityGeneration.addingReportingOverflow(1)
                guard !overflow else {
                    record.state = .transientUnavailable(
                        reason: .runtimeUnavailable,
                        retryGeneration: flight.resolutionGeneration &+ 1
                    )
                    records[rootEpoch] = record
                    for continuation in flight.waiters.values {
                        continuation.resume(returning: record.state)
                    }
                    return
                }
                record.authorityGeneration = advanced
            }
            record.state = .eligible(
                .filesystem(WorkspaceCodemapFilesystemRootCapability(
                    rootEpoch: rootEpoch,
                    loadedRootURL: URL(
                        fileURLWithPath: record.binding.standardizedLoadedRootPath,
                        isDirectory: true
                    ),
                    authorityGeneration: record.authorityGeneration
                ))
            )
        case let .eligibleGit(layout, prefix, repositoryIdentity, worktreeID, authority):
            record.filesystemProof = nil
            if let repositoryID = record.binding.repositoryID,
               repositoryID != repositoryIdentity.repositoryID ||
               record.binding.worktreeID != worktreeID ||
               record.stableAuthority?.repositoryBindingEpoch != authority.repositoryBindingEpoch ||
               record.stableAuthority?.worktreeBindingEpoch != authority.worktreeBindingEpoch
            {
                record.state = .terminalUnavailable(.rootEpochBindingMismatch)
            } else {
                record.binding.repositoryID = repositoryIdentity.repositoryID
                record.binding.worktreeID = worktreeID
                if record.stableAuthority != authority {
                    let (advanced, overflow) = record.authorityGeneration.addingReportingOverflow(1)
                    guard !overflow else {
                        // Generations must never repeat within one root lifetime; wrapping would
                        // let a revoked authority be mistaken for a current one.
                        record.state = .transientUnavailable(
                            reason: .runtimeUnavailable,
                            retryGeneration: flight.resolutionGeneration &+ 1
                        )
                        records[rootEpoch] = record
                        for continuation in flight.waiters.values {
                            continuation.resume(returning: record.state)
                        }
                        return
                    }
                    record.authorityGeneration = advanced
                    record.stableAuthority = authority
                }
                let token = WorkspaceCodemapRepositoryAuthorityToken(
                    authorityGeneration: record.authorityGeneration,
                    repositoryNamespace: authority.repositoryNamespace,
                    objectFormat: authority.objectFormat,
                    repositoryBindingEpoch: authority.repositoryBindingEpoch,
                    worktreeBindingEpoch: authority.worktreeBindingEpoch,
                    layoutGeneration: authority.layoutGeneration,
                    indexGeneration: authority.indexGeneration,
                    checkoutConfigurationGeneration: authority.checkoutConfigurationGeneration,
                    attributeGeneration: authority.attributeGeneration,
                    sparseGeneration: authority.sparseGeneration,
                    metadataGeneration: authority.metadataGeneration
                )
                record.state = .eligible(
                    .git(GitCodemapRootCapability(
                        rootEpoch: rootEpoch,
                        repositoryLayout: layout,
                        repositoryIdentity: repositoryIdentity,
                        worktreeID: worktreeID,
                        repositoryNamespace: authority.repositoryNamespace,
                        objectFormat: authority.objectFormat,
                        repositoryRelativeLoadedRootPrefix: prefix,
                        repositoryAuthority: token
                    ))
                )
            }
        case let .terminal(reason):
            if record.binding.repositoryID != nil,
               reason == .nonGit || reason == .invalidLayout
            {
                record.state = .transientUnavailable(
                    reason: .repositoryChanging,
                    retryGeneration: flight.resolutionGeneration &+ 1
                )
            } else {
                record.state = .terminalUnavailable(reason)
            }
        case let .transient(reason):
            record.state = .transientUnavailable(
                reason: reason,
                retryGeneration: flight.resolutionGeneration &+ 1
            )
        }
        records[rootEpoch] = record
        for continuation in flight.waiters.values {
            continuation.resume(returning: record.state)
        }
    }

    private func cancelFlight(
        for rootEpoch: WorkspaceCodemapRootEpoch,
        restoring state: WorkspaceCodemapRootCapabilityState
    ) {
        guard let flight = flights.removeValue(forKey: rootEpoch) else { return }
        flight.task.cancel()
        for (waiterID, continuation) in flight.waiters {
            rootEpochByWaiterID.removeValue(forKey: waiterID)
            continuation.resume(returning: state)
        }
    }

    private func evictReleasedHistoryIfNeeded() {
        while historicalRecords.count > historicalRecordLimit,
              let oldest = historicalRecords.min(by: { $0.value.releaseOrdinal < $1.value.releaseOrdinal })
        {
            historicalRecords.removeValue(forKey: oldest.key)
            retainedReplacementStatesByRootEpoch.removeValue(forKey: oldest.key)
        }
        // Replacement generations only matter while a root epoch can still be re-registered.
        retainedReplacementStatesByRootEpoch = retainedReplacementStatesByRootEpoch.filter {
            records[$0.key] != nil || historicalRecords[$0.key] == nil
        }
    }

    private static func restorableState(
        _ state: WorkspaceCodemapRootCapabilityState
    ) -> WorkspaceCodemapRootCapabilityState {
        if case .resolving = state { return .unresolved }
        return state
    }

    /// Re-checks that an issued capability still describes the current root, without reading any
    /// source bytes. Git keeps its existing per-demand checks and does no new Git discovery here.
    func revalidateRootAuthority(
        capability: WorkspaceCodemapRootCapability
    ) async -> WorkspaceCodemapRootAuthorityValidation {
        guard let record = records[capability.rootEpoch],
              case let .eligible(activeCapability) = record.state,
              activeCapability == capability
        else { return .changed }
        switch capability {
        case .git:
            return .current
        case .filesystem:
            guard let proof = record.filesystemProof else { return .changed }
            switch localClassificationProbe.refresh(proof) {
            case let .current(currentProof):
                guard Self.filesystemRootAccessProof(currentProof) == .valid else {
                    return .unavailable(.permissionFailure)
                }
                // Witness churn with the same semantic binding refreshes the proof only; the
                // capability, its generation and every graph contribution stay current.
                records[capability.rootEpoch]?.filesystemProof = currentProof
                return .current
            case .bindingChanged:
                return .changed
            case .requiresGitPreflight:
                // Fresh positive Git or bare evidence: leave filesystem mode through the normal
                // replacement path rather than continuing on the old proof.
                return .changed
            case .unavailable:
                // The proof could not be observed at all — typically a lost search permission on
                // the root or an ancestor. That is not evidence that the binding or source mode
                // changed, so serving stops transiently while the authority and its generation
                // stay put; restoring access refreshes the proof without advancing anything.
                return .unavailable(.permissionFailure)
            }
        }
    }

    /// Issues process-free classification evidence for an active filesystem root.
    func filesystemClassificationEvidence(
        for capability: WorkspaceCodemapRootCapability
    ) async -> WorkspaceCodemapFilesystemClassificationEvidence? {
        guard case let .filesystem(filesystemCapability) = capability,
              let record = records[capability.rootEpoch],
              case let .eligible(activeCapability) = record.state,
              activeCapability == capability,
              let proof = record.filesystemProof,
              case let .current(currentProof) = localClassificationProbe.refresh(proof),
              Self.filesystemRootAccessProof(currentProof) == .valid
        else { return nil }
        records[capability.rootEpoch]?.filesystemProof = currentProof
        return WorkspaceCodemapFilesystemClassificationEvidence(
            capability: filesystemCapability,
            proof: currentProof,
            classificationProbe: localClassificationProbe
        )
    }

    func makeSourceAuthority(
        capability: WorkspaceCodemapRootCapability,
        observedRootEpoch: WorkspaceCodemapRootEpoch,
        observedRootAuthority: WorkspaceCodemapRootAuthorityToken,
        candidateRootRelativePath: String,
        observedPathGeneration: UInt64,
        currentPathGeneration: UInt64,
        observedIngressGeneration: UInt64,
        currentIngressGeneration: UInt64
    ) async -> WorkspaceCodemapSourceAuthorityToken? {
        let authorities = await makeSourceAuthorities(
            capability: capability,
            observedRootEpoch: observedRootEpoch,
            observedRootAuthority: observedRootAuthority,
            candidates: [WorkspaceCodemapSourceAuthorityRequest(
                candidateRootRelativePath: candidateRootRelativePath,
                observedPathGeneration: observedPathGeneration,
                currentPathGeneration: currentPathGeneration,
                observedIngressGeneration: observedIngressGeneration,
                currentIngressGeneration: currentIngressGeneration
            )]
        )
        return authorities.first ?? nil
    }

    /// Issues source-authority tokens for one bounded candidate batch under a single stable
    /// repository-authority window. Root evidence is captured exactly twice; no-follow path
    /// fingerprints and nested attribute evidence remain candidate-local and fail closed.
    func makeSourceAuthorities(
        capability: WorkspaceCodemapRootCapability,
        observedRootEpoch: WorkspaceCodemapRootEpoch,
        observedRootAuthority: WorkspaceCodemapRootAuthorityToken,
        candidates: [WorkspaceCodemapSourceAuthorityRequest]
    ) async -> [WorkspaceCodemapSourceAuthorityToken?] {
        guard !candidates.isEmpty else { return [] }
        let unavailable = [WorkspaceCodemapSourceAuthorityToken?](
            repeating: nil,
            count: candidates.count
        )
        guard !Task.isCancelled,
              let record = records[capability.rootEpoch],
              case let .eligible(activeCapability) = record.state,
              activeCapability == capability,
              capability.rootEpoch == observedRootEpoch,
              capability.rootAuthority == observedRootAuthority
        else {
            hooks.sourceAuthorityRejected(Task.isCancelled ? .cancelled : .requestUnavailable)
            return unavailable
        }
        if case .filesystem = capability {
            return await makeFilesystemSourceAuthorities(
                capability: capability,
                record: record,
                observedRootEpoch: observedRootEpoch,
                observedRootAuthority: observedRootAuthority,
                candidates: candidates,
                unavailable: unavailable
            )
        }
        guard case let .git(gitCapability) = capability,
              let stableAuthority = record.stableAuthority
        else {
            hooks.sourceAuthorityRejected(.requestUnavailable)
            return unavailable
        }

        let standardizedLoadedRootPath = record.binding.standardizedLoadedRootPath
        let loadedRoot = URL(fileURLWithPath: standardizedLoadedRootPath)
        var candidateRootPaths = [String?](repeating: nil, count: candidates.count)
        var candidatePaths = [String?](repeating: nil, count: candidates.count)
        var prePathFingerprints = [GitBlobLStatFingerprint?](
            repeating: nil,
            count: candidates.count
        )
        var preAttributeGenerations = [String?](repeating: nil, count: candidates.count)
        var capturePhase = WorkspaceCodemapSourceAuthorityRejection.CapturePhase.preRepository

        do {
            for index in candidates.indices {
                let candidate = candidates[index]
                guard candidate.observedPathGeneration == candidate.currentPathGeneration,
                      candidate.observedIngressGeneration == candidate.currentIngressGeneration,
                      let rootRelativePath = Self.safeRepositoryRelativePath(
                          candidate.candidateRootRelativePath
                      ),
                      let path = WorkspaceCodemapSourceAuthorityToken.repositoryRelativePath(
                          rootRelativePath: rootRelativePath,
                          prefix: gitCapability.repositoryRelativeLoadedRootPrefix
                      ), Self.isCandidate(
                          path,
                          insideLoadedRootPrefix: gitCapability.repositoryRelativeLoadedRootPrefix
                      )
                else {
                    hooks.sourceAuthorityRejected(.candidateRequestRejected(index: index))
                    continue
                }
                do {
                    let fingerprint = try pathFingerprintClient.fingerprint(
                        gitCapability.repositoryLayout.workTreeRoot,
                        path
                    )
                    guard fingerprint.isRegularFile else {
                        hooks.sourceAuthorityRejected(.candidateFingerprintUnavailable(index: index))
                        continue
                    }
                    candidateRootPaths[index] = rootRelativePath
                    candidatePaths[index] = path
                    prePathFingerprints[index] = fingerprint
                    await hooks.afterSourcePathFingerprintCapture()
                } catch {
                    hooks.sourceAuthorityRejected(.candidateFingerprintUnavailable(index: index))
                    continue
                }
                try Task.checkCancellation()
            }

            let preRepository = try await captureAuthority(
                loadedRoot: loadedRoot,
                expectedLayout: gitCapability.repositoryLayout,
                prefix: gitCapability.repositoryRelativeLoadedRootPrefix
            )
            guard preRepository.stableAuthority.matchesSourceAuthorityStability(of: stableAuthority) else {
                hooks.sourceAuthorityRejected(.registrationAuthorityChanged)
                return unavailable
            }
            await hooks.afterFirstAuthorityCapture()
            try Task.checkCancellation()

            for index in candidates.indices {
                guard let path = candidatePaths[index] else { continue }
                do {
                    preAttributeGenerations[index] = try digestEvidence(
                        urls: Self.candidateAttributeURLs(
                            layout: gitCapability.repositoryLayout,
                            candidateRepositoryRelativePath: path
                        ),
                        includeBoundedContents: true
                    )
                } catch {
                    hooks.sourceAuthorityRejected(.candidateAttributesChanged(index: index))
                    candidateRootPaths[index] = nil
                    candidatePaths[index] = nil
                    prePathFingerprints[index] = nil
                }
                try Task.checkCancellation()
            }

            var postAttributeGenerations = [String?](repeating: nil, count: candidates.count)
            for index in candidates.indices {
                guard let path = candidatePaths[index],
                      let preAttributes = preAttributeGenerations[index]
                else { continue }
                do {
                    let postAttributes = try digestEvidence(
                        urls: Self.candidateAttributeURLs(
                            layout: gitCapability.repositoryLayout,
                            candidateRepositoryRelativePath: path
                        ),
                        includeBoundedContents: true
                    )
                    if postAttributes == preAttributes {
                        postAttributeGenerations[index] = postAttributes
                    } else {
                        hooks.sourceAuthorityRejected(.candidateAttributesChanged(index: index))
                    }
                } catch {
                    hooks.sourceAuthorityRejected(.candidateAttributesChanged(index: index))
                    postAttributeGenerations[index] = nil
                }
                try Task.checkCancellation()
            }

            var postPathFingerprints = [GitBlobLStatFingerprint?](
                repeating: nil,
                count: candidates.count
            )
            for index in candidates.indices {
                guard let path = candidatePaths[index],
                      let prePathFingerprint = prePathFingerprints[index]
                else { continue }
                do {
                    let postPathFingerprint = try pathFingerprintClient.fingerprint(
                        gitCapability.repositoryLayout.workTreeRoot,
                        path
                    )
                    #if DEBUG
                        await hooks.afterSourcePathFingerprintCapture()
                    #endif
                    guard postPathFingerprint == prePathFingerprint,
                          postPathFingerprint.isRegularFile
                    else {
                        hooks.sourceAuthorityRejected(.candidatePathChanged(index: index))
                        continue
                    }
                    postPathFingerprints[index] = postPathFingerprint
                } catch {
                    hooks.sourceAuthorityRejected(.candidateFingerprintUnavailable(index: index))
                    continue
                }
                try Task.checkCancellation()
            }

            capturePhase = .postRepository
            let postRepository = try await captureAuthority(
                loadedRoot: loadedRoot,
                expectedLayout: gitCapability.repositoryLayout,
                prefix: gitCapability.repositoryRelativeLoadedRootPrefix
            )
            // Candidate-local fingerprints and attributes establish source stability. Unrelated
            // index or metadata churn must not reject the entire batch.
            guard preRepository.sourceClassificationEvidence == postRepository.sourceClassificationEvidence,
                  preRepository.matchesSourceAuthorityStability(of: postRepository)
            else {
                hooks.sourceAuthorityRejected(.repositoryAuthorityChangedDuringIssuance)
                return unavailable
            }
            guard postRepository.stableAuthority.matchesSourceAuthorityStability(of: stableAuthority) else {
                hooks.sourceAuthorityRejected(.registrationAuthorityChanged)
                return unavailable
            }
            guard case let .eligible(currentCapability) = records[capability.rootEpoch]?.state,
                  currentCapability == capability
            else {
                hooks.sourceAuthorityRejected(.capabilityChanged)
                return unavailable
            }
            try Task.checkCancellation()

            // Recheck candidate-local evidence after the repository capture.
            for index in candidates.indices {
                guard let path = candidatePaths[index],
                      let expectedFingerprint = postPathFingerprints[index],
                      let expectedAttributes = postAttributeGenerations[index]
                else { continue }
                do {
                    let attributes = try digestEvidence(
                        urls: Self.candidateAttributeURLs(
                            layout: gitCapability.repositoryLayout,
                            candidateRepositoryRelativePath: path
                        ),
                        includeBoundedContents: true
                    )
                    guard attributes == expectedAttributes else {
                        hooks.sourceAuthorityRejected(.candidateAttributesChanged(index: index))
                        postAttributeGenerations[index] = nil
                        continue
                    }
                } catch {
                    hooks.sourceAuthorityRejected(.candidateAttributesChanged(index: index))
                    postAttributeGenerations[index] = nil
                    continue
                }
                do {
                    let fingerprint = try pathFingerprintClient.fingerprint(
                        gitCapability.repositoryLayout.workTreeRoot,
                        path
                    )
                    #if DEBUG
                        await hooks.afterSourcePathFingerprintCapture()
                    #endif
                    guard fingerprint == expectedFingerprint, fingerprint.isRegularFile else {
                        hooks.sourceAuthorityRejected(.candidatePathChanged(index: index))
                        postPathFingerprints[index] = nil
                        continue
                    }
                    postPathFingerprints[index] = fingerprint
                } catch {
                    hooks.sourceAuthorityRejected(.candidateFingerprintUnavailable(index: index))
                    postPathFingerprints[index] = nil
                }
                try Task.checkCancellation()
            }

            var authorities = unavailable
            for index in candidates.indices {
                guard let rootRelativePath = candidateRootPaths[index],
                      candidatePaths[index] != nil,
                      let prePathFingerprint = prePathFingerprints[index],
                      let postPathFingerprint = postPathFingerprints[index],
                      let attributeGeneration = postAttributeGenerations[index]
                else { continue }
                let candidate = candidates[index]
                authorities[index] = WorkspaceCodemapSourceAuthorityToken.issue(
                    capability: capability,
                    observedRootEpoch: observedRootEpoch,
                    observedRootAuthority: observedRootAuthority,
                    standardizedLoadedRootPath: standardizedLoadedRootPath,
                    candidateRootRelativePath: rootRelativePath,
                    acceptedPrePathFingerprint: prePathFingerprint,
                    acceptedPostPathFingerprint: postPathFingerprint,
                    candidateAttributeGeneration: attributeGeneration,
                    observedPathGeneration: candidate.observedPathGeneration,
                    currentPathGeneration: candidate.currentPathGeneration,
                    observedIngressGeneration: candidate.observedIngressGeneration,
                    currentIngressGeneration: candidate.currentIngressGeneration
                )
                if authorities[index] == nil {
                    hooks.sourceAuthorityRejected(.tokenIssuanceRejected(index: index))
                }
                try Task.checkCancellation()
            }
            guard !Task.isCancelled,
                  case let .eligible(finalCapability) = records[capability.rootEpoch]?.state,
                  finalCapability == capability
            else {
                hooks.sourceAuthorityRejected(Task.isCancelled ? .cancelled : .capabilityChanged)
                return unavailable
            }
            return authorities
        } catch {
            hooks.sourceAuthorityRejected(
                error is CancellationError
                    ? .cancelled
                    : .captureFailed(
                        phase: capturePhase,
                        reason: Self.transientReason(for: error)
                    )
            )
            return unavailable
        }
    }

    /// Issues filesystem source-authority tokens for one bounded candidate batch.
    ///
    /// Candidate no-follow fingerprints are bracketed by bounded root-proof checks, then rechecked
    /// once more, so a root rebind or a candidate change during issuance rejects rather than
    /// producing a token that outlives its evidence. No Git coordinates or attribute sentinel exist.
    private func makeFilesystemSourceAuthorities(
        capability: WorkspaceCodemapRootCapability,
        record: RootRecord,
        observedRootEpoch: WorkspaceCodemapRootEpoch,
        observedRootAuthority: WorkspaceCodemapRootAuthorityToken,
        candidates: [WorkspaceCodemapSourceAuthorityRequest],
        unavailable: [WorkspaceCodemapSourceAuthorityToken?]
    ) async -> [WorkspaceCodemapSourceAuthorityToken?] {
        guard let proof = record.filesystemProof else {
            hooks.sourceAuthorityRejected(.requestUnavailable)
            return unavailable
        }
        let standardizedLoadedRootPath = record.binding.standardizedLoadedRootPath
        let loadedRoot = URL(fileURLWithPath: standardizedLoadedRootPath, isDirectory: true)

        switch filesystemRootProofState(proof) {
        case .current:
            break
        case .changed:
            hooks.sourceAuthorityRejected(.registrationAuthorityChanged)
            return unavailable
        case let .unavailable(reason):
            hooks.sourceAuthorityRejected(.captureFailed(phase: .preRepository, reason: reason))
            return unavailable
        }

        var candidatePaths = [String?](repeating: nil, count: candidates.count)
        var prePathFingerprints = [GitBlobLStatFingerprint?](repeating: nil, count: candidates.count)
        do {
            for index in candidates.indices {
                let candidate = candidates[index]
                guard candidate.observedPathGeneration == candidate.currentPathGeneration,
                      candidate.observedIngressGeneration == candidate.currentIngressGeneration,
                      let rootRelativePath = Self.safeRepositoryRelativePath(
                          candidate.candidateRootRelativePath
                      )
                else {
                    hooks.sourceAuthorityRejected(.candidateRequestRejected(index: index))
                    continue
                }
                do {
                    let fingerprint = try pathFingerprintClient.fingerprint(loadedRoot, rootRelativePath)
                    guard fingerprint.isRegularFile else {
                        hooks.sourceAuthorityRejected(.candidateFingerprintUnavailable(index: index))
                        continue
                    }
                    candidatePaths[index] = rootRelativePath
                    prePathFingerprints[index] = fingerprint
                    await hooks.afterSourcePathFingerprintCapture()
                } catch {
                    hooks.sourceAuthorityRejected(.candidateFingerprintUnavailable(index: index))
                    continue
                }
                try Task.checkCancellation()
            }
            await hooks.afterFirstAuthorityCapture()
            try Task.checkCancellation()

            switch filesystemRootProofState(records[capability.rootEpoch]?.filesystemProof ?? proof) {
            case .current:
                break
            case .changed:
                hooks.sourceAuthorityRejected(.repositoryAuthorityChangedDuringIssuance)
                return unavailable
            case let .unavailable(reason):
                hooks.sourceAuthorityRejected(.captureFailed(phase: .postRepository, reason: reason))
                return unavailable
            }
            guard case let .eligible(currentCapability) = records[capability.rootEpoch]?.state,
                  currentCapability == capability
            else {
                hooks.sourceAuthorityRejected(.capabilityChanged)
                return unavailable
            }

            // Final candidate recheck after the root window closes.
            var postPathFingerprints = [GitBlobLStatFingerprint?](
                repeating: nil,
                count: candidates.count
            )
            for index in candidates.indices {
                guard let rootRelativePath = candidatePaths[index],
                      let prePathFingerprint = prePathFingerprints[index]
                else { continue }
                do {
                    let fingerprint = try pathFingerprintClient.fingerprint(loadedRoot, rootRelativePath)
                    #if DEBUG
                        await hooks.afterSourcePathFingerprintCapture()
                    #endif
                    guard fingerprint == prePathFingerprint, fingerprint.isRegularFile else {
                        hooks.sourceAuthorityRejected(.candidatePathChanged(index: index))
                        continue
                    }
                    postPathFingerprints[index] = fingerprint
                } catch {
                    hooks.sourceAuthorityRejected(.candidateFingerprintUnavailable(index: index))
                    continue
                }
                try Task.checkCancellation()
            }

            var authorities = unavailable
            for index in candidates.indices {
                guard let rootRelativePath = candidatePaths[index],
                      let prePathFingerprint = prePathFingerprints[index],
                      let postPathFingerprint = postPathFingerprints[index]
                else { continue }
                let candidate = candidates[index]
                authorities[index] = WorkspaceCodemapSourceAuthorityToken.issue(
                    capability: capability,
                    observedRootEpoch: observedRootEpoch,
                    observedRootAuthority: observedRootAuthority,
                    standardizedLoadedRootPath: standardizedLoadedRootPath,
                    candidateRootRelativePath: rootRelativePath,
                    acceptedPrePathFingerprint: prePathFingerprint,
                    acceptedPostPathFingerprint: postPathFingerprint,
                    candidateAttributeGeneration: nil,
                    observedPathGeneration: candidate.observedPathGeneration,
                    currentPathGeneration: candidate.currentPathGeneration,
                    observedIngressGeneration: candidate.observedIngressGeneration,
                    currentIngressGeneration: candidate.currentIngressGeneration
                )
                if authorities[index] == nil {
                    hooks.sourceAuthorityRejected(.tokenIssuanceRejected(index: index))
                }
                try Task.checkCancellation()
            }
            guard !Task.isCancelled,
                  case let .eligible(finalCapability) = records[capability.rootEpoch]?.state,
                  finalCapability == capability
            else {
                hooks.sourceAuthorityRejected(Task.isCancelled ? .cancelled : .capabilityChanged)
                return unavailable
            }
            return authorities
        } catch {
            hooks.sourceAuthorityRejected(
                error is CancellationError
                    ? .cancelled
                    : .captureFailed(
                        phase: .postRepository,
                        reason: Self.transientReason(for: error)
                    )
            )
            return unavailable
        }
    }

    /// Bounded root-proof check shared by filesystem issuance and revalidation. Witness metadata
    /// churn with the same semantic binding stays `.current`; a rebind or fresh positive Git
    /// evidence is `.changed`; evidence that cannot be observed at all is transiently unavailable
    /// rather than a claim that the binding moved.
    private func filesystemRootProofState(
        _ proof: WorkspaceCodemapNonGitFilesystemProof
    ) -> WorkspaceCodemapRootAuthorityValidation {
        switch localClassificationProbe.refresh(proof) {
        case let .current(currentProof):
            guard Self.filesystemRootAccessProof(currentProof) == .valid else {
                return .unavailable(.permissionFailure)
            }
            return .current
        case .bindingChanged, .requiresGitPreflight:
            return .changed
        case .unavailable:
            return .unavailable(.permissionFailure)
        }
    }

    /// Revalidates previously issued source-authority tokens against one stable repository/path window.
    /// This reads Git metadata and no-follow path fingerprints only; it never reads source bytes.
    func revalidateSourceAuthorities(
        capability: WorkspaceCodemapRootCapability,
        tokens: [WorkspaceCodemapSourceAuthorityToken]
    ) async -> Bool {
        guard let record = records[capability.rootEpoch],
              case let .eligible(activeCapability) = record.state,
              activeCapability == capability
        else { return false }
        if tokens.isEmpty {
            // Even an empty candidate list validates root currentness.
            guard case .filesystem = capability else { return true }
            guard let proof = record.filesystemProof else { return false }
            return filesystemRootProofState(proof) == .current
        }
        if case .filesystem = capability {
            return revalidateFilesystemSourceAuthorities(
                capability: capability,
                record: record,
                tokens: tokens
            )
        }
        guard case let .git(gitCapability) = capability,
              let stableAuthority = record.stableAuthority
        else { return false }

        var candidatePaths = Set<String>()
        var repositoryRelativePathsByToken: [String] = []
        repositoryRelativePathsByToken.reserveCapacity(tokens.count)
        for token in tokens {
            guard token.isFactoryValidated,
                  token.rootEpoch == capability.rootEpoch,
                  token.rootAuthority == capability.rootAuthority,
                  token.repositoryRelativeLoadedRootPrefix ==
                  gitCapability.repositoryRelativeLoadedRootPrefix,
                  let repositoryRelativePath = token.standardizedRepositoryRelativePath,
                  let candidatePath = Self.safeRepositoryRelativePath(repositoryRelativePath),
                  candidatePath == repositoryRelativePath,
                  Self.isCandidate(
                      candidatePath,
                      insideLoadedRootPrefix: gitCapability.repositoryRelativeLoadedRootPrefix
                  ),
                  candidatePaths.insert(candidatePath).inserted
            else { return false }
            repositoryRelativePathsByToken.append(candidatePath)
        }

        let loadedRoot = URL(fileURLWithPath: record.binding.standardizedLoadedRootPath)
        do {
            var prePathFingerprints: [String: GitBlobLStatFingerprint] = [:]
            var preAttributeGenerations: [String: String] = [:]
            for (token, path) in zip(tokens, repositoryRelativePathsByToken) {
                let fingerprint = try pathFingerprintClient.fingerprint(
                    gitCapability.repositoryLayout.workTreeRoot,
                    path
                )
                guard fingerprint == token.acceptedPostPathFingerprint,
                      fingerprint.isRegularFile
                else { return false }
                prePathFingerprints[path] = fingerprint
            }
            try Task.checkCancellation()

            let preRepository = try await captureAuthority(
                loadedRoot: loadedRoot,
                expectedLayout: gitCapability.repositoryLayout,
                prefix: gitCapability.repositoryRelativeLoadedRootPrefix
            )
            guard preRepository.stableAuthority.matchesSourceAuthorityStability(of: stableAuthority) else {
                return false
            }

            for (token, path) in zip(tokens, repositoryRelativePathsByToken) {
                let generation = try digestEvidence(
                    urls: Self.candidateAttributeURLs(
                        layout: gitCapability.repositoryLayout,
                        candidateRepositoryRelativePath: path
                    ),
                    includeBoundedContents: true
                )
                guard generation == token.candidateAttributeGeneration else { return false }
                preAttributeGenerations[path] = generation
            }
            try Task.checkCancellation()

            for (token, path) in zip(tokens, repositoryRelativePathsByToken) {
                let generation = try digestEvidence(
                    urls: Self.candidateAttributeURLs(
                        layout: gitCapability.repositoryLayout,
                        candidateRepositoryRelativePath: path
                    ),
                    includeBoundedContents: true
                )
                guard generation == preAttributeGenerations[path],
                      generation == token.candidateAttributeGeneration
                else { return false }
            }

            let postRepository = try await captureAuthority(
                loadedRoot: loadedRoot,
                expectedLayout: gitCapability.repositoryLayout,
                prefix: gitCapability.repositoryRelativeLoadedRootPrefix
            )
            // Demand-time classification owns current-state correctness. This pre/post window
            // only fences classification-input races while revalidating per-file source authority.
            guard preRepository.sourceClassificationEvidence == postRepository.sourceClassificationEvidence,
                  preRepository.matchesSourceAuthorityStability(of: postRepository),
                  postRepository.stableAuthority.matchesSourceAuthorityStability(of: stableAuthority)
            else { return false }

            for (token, path) in zip(tokens, repositoryRelativePathsByToken) {
                let fingerprint = try pathFingerprintClient.fingerprint(
                    gitCapability.repositoryLayout.workTreeRoot,
                    path
                )
                guard fingerprint == prePathFingerprints[path],
                      fingerprint == token.acceptedPostPathFingerprint,
                      fingerprint.isRegularFile
                else { return false }
            }
            guard case let .eligible(currentCapability) = records[capability.rootEpoch]?.state,
                  currentCapability == capability
            else { return false }
            return true
        } catch {
            return false
        }
    }

    /// Repeats the filesystem issuance obligations for already issued tokens: bounded root proof,
    /// no-follow candidate fingerprints matching the accepted ones, and a final capability check.
    private func revalidateFilesystemSourceAuthorities(
        capability: WorkspaceCodemapRootCapability,
        record: RootRecord,
        tokens: [WorkspaceCodemapSourceAuthorityToken]
    ) -> Bool {
        guard let proof = record.filesystemProof else { return false }
        let loadedRoot = URL(
            fileURLWithPath: record.binding.standardizedLoadedRootPath,
            isDirectory: true
        )
        var candidatePaths = Set<String>()
        var rootRelativePathsByToken: [String] = []
        rootRelativePathsByToken.reserveCapacity(tokens.count)
        for token in tokens {
            guard token.isFactoryValidated,
                  token.rootEpoch == capability.rootEpoch,
                  token.rootAuthority == capability.rootAuthority,
                  token.standardizedLoadedRootPath == record.binding.standardizedLoadedRootPath,
                  token.standardizedRepositoryRelativePath == nil,
                  token.candidateAttributeGeneration == nil,
                  let candidatePath = Self.safeRepositoryRelativePath(token.candidateRootRelativePath),
                  candidatePath == token.candidateRootRelativePath,
                  candidatePaths.insert(candidatePath).inserted
            else { return false }
            rootRelativePathsByToken.append(candidatePath)
        }

        guard filesystemRootProofState(proof) == .current else { return false }
        do {
            var prePathFingerprints: [String: GitBlobLStatFingerprint] = [:]
            for (token, path) in zip(tokens, rootRelativePathsByToken) {
                let fingerprint = try pathFingerprintClient.fingerprint(loadedRoot, path)
                guard fingerprint == token.acceptedPostPathFingerprint,
                      fingerprint.isRegularFile
                else { return false }
                prePathFingerprints[path] = fingerprint
            }
            try Task.checkCancellation()
            guard filesystemRootProofState(proof) == .current else { return false }
            for (token, path) in zip(tokens, rootRelativePathsByToken) {
                let fingerprint = try pathFingerprintClient.fingerprint(loadedRoot, path)
                guard fingerprint == prePathFingerprints[path],
                      fingerprint == token.acceptedPostPathFingerprint,
                      fingerprint.isRegularFile
                else { return false }
            }
            guard case let .eligible(currentCapability) = records[capability.rootEpoch]?.state,
                  currentCapability == capability
            else { return false }
            return true
        } catch {
            return false
        }
    }

    private func resolveCandidate(
        loadedRootURL: URL,
        evidence: WorkspaceCodemapRootEligibilityEvidence?
    ) async -> Resolution {
        let loadedRoot = loadedRootURL.standardizedFileURL
        guard loadedRoot.isFileURL, loadedRoot.path.hasPrefix("/") else {
            return .terminal(.invalidLoadedRootContainment)
        }
        switch Self.directoryState(at: loadedRoot) {
        case .valid:
            break
        case .missing:
            return .transient(.repositoryChanging)
        case .permissionDenied:
            return .transient(.permissionFailure)
        case .invalid:
            return .terminal(.invalidLoadedRootContainment)
        }

        // Store evidence only routes the attempt. The actor re-observes the proof and proves
        // readability itself, so a stale or wrong cache can never admit a root on its own.
        if case .filesystem = evidence,
           let resolution = await filesystemResolution(loadedRoot: loadedRoot)
        {
            return resolution
        }

        let repositoryRoot: URL
        do {
            guard let resolved = try await gitService.findGitRoot(from: loadedRoot) else {
                return switch try await gitService.gitRepositoryKind(at: loadedRoot) {
                case .nonGit:
                    // `nonGit` is a negative Git preflight result, never the final answer for a
                    // provably safe filesystem root. Without that proof this stays unavailable.
                    await filesystemResolution(loadedRoot: loadedRoot)
                        ?? .transient(.repositoryChanging)
                case .bare: .terminal(.bareRepository)
                case .worktree: .terminal(.invalidLayout)
                }
            }
            repositoryRoot = resolved.standardizedFileURL
        } catch {
            return .transient(Self.transientReason(for: error))
        }

        guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repositoryRoot) else {
            return FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(".git").path)
                ? .terminal(.invalidLayout)
                : .transient(.repositoryChanging)
        }
        switch Self.layoutState(layout) {
        case .valid:
            break
        case .missing:
            return .transient(.repositoryChanging)
        case .permissionDenied:
            return .transient(.permissionFailure)
        case .invalid:
            return .terminal(.invalidLayout)
        }
        guard let prefix = Self.repositoryRelativePrefix(
            loadedRoot: loadedRoot,
            worktreeRoot: layout.workTreeRoot
        ) else {
            return .terminal(.invalidLoadedRootContainment)
        }

        do {
            for attempt in 0 ..< 2 {
                let pre = try await captureAuthority(
                    loadedRoot: loadedRoot,
                    expectedLayout: layout,
                    prefix: prefix
                )
                await hooks.afterFirstAuthorityCapture()
                try Task.checkCancellation()
                let post = try await captureAuthority(
                    loadedRoot: loadedRoot,
                    expectedLayout: layout,
                    prefix: prefix
                )
                guard pre == post else {
                    if attempt == 0 { continue }
                    return .transient(.repositoryChanging)
                }

                let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
                    commonGitDir: layout.commonDir,
                    mainWorktreeRoot: layout.knownMainWorktreeRoot
                )
                let worktreeID = GitWorktreeIdentity.worktreeID(
                    repositoryID: repositoryIdentity.repositoryID,
                    gitDir: layout.gitDir,
                    isMain: !layout.isLinkedWorktree,
                    path: layout.workTreeRoot
                )
                return .eligibleGit(
                    layout: layout,
                    prefix: prefix,
                    repositoryIdentity: repositoryIdentity,
                    worktreeID: worktreeID,
                    authority: post.stableAuthority
                )
            }
            return .transient(.repositoryChanging)
        } catch let error as GitBlobIdentityError {
            switch error {
            case .invalidObjectFormat:
                return .terminal(.unsupportedObjectFormat)
            case .unsupportedGit:
                return .terminal(.unsupportedGit)
            default:
                return .transient(.runtimeUnavailable)
            }
        } catch let error as GitBlobCodeMapLocatorModelError {
            switch error {
            case .invalidNamespaceSalt, .invalidCommonDirectory, .invalidNamespace:
                return .terminal(.namespaceUnavailable)
            default:
                return .terminal(.unsupportedObjectFormat)
            }
        } catch {
            return .transient(Self.transientReason(for: error))
        }
    }

    /// Establishes a fresh definite non-Git proof plus a scoped readability proof for `loadedRoot`.
    /// Returns nil when no definite proof is available, so the caller falls through to Git.
    private func filesystemResolution(loadedRoot: URL) async -> Resolution? {
        guard case let .definitelyNonGit(proof) = await localClassificationProbe.resolve(loadedRoot),
              proof.requestedRootPath == loadedRoot.path,
              case let .current(currentProof) = localClassificationProbe.refresh(proof)
        else { return nil }
        switch Self.filesystemRootAccessProof(currentProof) {
        case .valid:
            return .eligibleFilesystem(currentProof)
        case .permissionDenied:
            return .transient(.permissionFailure)
        case .missing, .invalid:
            return .transient(.repositoryChanging)
        }
    }

    /// Proves the loaded root is a readable directory that still matches the captured identity.
    /// `lstat`/`realpath` alone is insufficient, so this opens a scoped no-follow directory
    /// descriptor and matches `fstat` against the proof's own root witness.
    private static func filesystemRootAccessProof(
        _ proof: WorkspaceCodemapNonGitFilesystemProof
    ) -> DirectoryState {
        guard let rootIdentity = proof.lexicalPathWitnesses.last?.identity,
              (rootIdentity.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR),
              !StandardizedPath.containsNUL(proof.requestedRootPath)
        else { return .invalid }
        let descriptor = open(
            proof.requestedRootPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            return switch errno {
            case ENOENT, ENOTDIR: .missing
            case EACCES, EPERM, ELOOP: .permissionDenied
            default: .invalid
            }
        }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { return .invalid }
        guard safeDeviceID(value.st_dev) == rootIdentity.device,
              UInt64(value.st_ino) == rootIdentity.inode,
              (value.st_mode & S_IFMT) == S_IFDIR
        else { return .invalid }
        return .valid
    }

    private func captureAuthority(
        loadedRoot: URL,
        expectedLayout: GitRepositoryLayout,
        prefix: String
    ) async throws -> AuthorityCapture {
        #if DEBUG
            authorityCaptureCount &+= 1
        #endif
        guard let currentLayout = try await gitService.resolveGitBlobRepository(containing: loadedRoot),
              Self.repositoryRelativePrefix(
                  loadedRoot: loadedRoot,
                  worktreeRoot: currentLayout.workTreeRoot
              ) == prefix,
              Self.layoutIdentity(currentLayout) == Self.layoutIdentity(expectedLayout)
        else {
            throw CapabilityCaptureError.layoutChanged
        }
        switch Self.layoutState(currentLayout) {
        case .valid:
            break
        case .missing:
            throw CapabilityCaptureError.layoutChanged
        case .permissionDenied:
            throw CapabilityCaptureError.permissionDenied
        case .invalid:
            throw CapabilityCaptureError.layoutChanged
        }

        let objectFormat = try await gitService.gitBlobObjectFormat(at: currentLayout.workTreeRoot)
        let configuration = try await gitService.gitCodemapAuthorityConfiguration(
            at: currentLayout.workTreeRoot
        )
        let namespace = try GitBlobRepositoryNamespace(
            repositoryLayout: currentLayout,
            salt: namespaceSalt
        )
        let sourceClassificationEvidence = try SourceClassificationEvidence(
            globalAttributeGeneration: digestEvidence(
                urls: Self.globalAttributeURLs(
                    layout: currentLayout,
                    configuredAttributesFile: configuration.attributesFilePath
                ),
                includeBoundedContents: true
            ),
            checkoutConfigurationValuesGeneration: Self.checkoutConfigurationValuesDigest(configuration)
        )

        let layoutGeneration = try digestEvidence(
            urls: [
                currentLayout.workTreeRoot,
                currentLayout.dotGitPath,
                currentLayout.gitDir,
                currentLayout.gitDir.appendingPathComponent("commondir"),
                currentLayout.commonDir
            ],
            includeBoundedContents: true
        )
        let indexGeneration = try digestEvidence(
            urls: [currentLayout.gitDir.appendingPathComponent("index")],
            includeBoundedContents: false
        )
        let metadataGeneration = try digestEvidence(
            urls: Self.metadataURLs(layout: currentLayout),
            includeBoundedContents: true
        )
        let checkoutConfigurationGeneration = try Self.checkoutConfigurationDigest(
            configuration,
            filesDigest: digestEvidence(
                urls: [
                    currentLayout.commonDir.appendingPathComponent("config"),
                    currentLayout.gitDir.appendingPathComponent("config"),
                    currentLayout.commonDir.appendingPathComponent("config.worktree"),
                    currentLayout.gitDir.appendingPathComponent("config.worktree")
                ],
                includeBoundedContents: true
            )
        )
        let attributeGeneration = try digestEvidence(
            urls: Self.attributeURLs(
                layout: currentLayout,
                loadedRoot: loadedRoot,
                configuredAttributesFile: configuration.attributesFilePath
            ),
            includeBoundedContents: true
        )
        let sparseGeneration = try Self.sparseDigest(
            configuration,
            filesDigest: digestEvidence(
                urls: [
                    currentLayout.gitDir.appendingPathComponent("info/sparse-checkout"),
                    currentLayout.commonDir.appendingPathComponent("info/sparse-checkout")
                ],
                includeBoundedContents: true
            )
        )
        let repositoryBindingEpoch = try Self.digestStrings([
            namespace.rawValue,
            objectFormat.rawValue,
            currentLayout.commonDir.resolvingSymlinksInPath().standardizedFileURL.path,
            bindingIdentityDigest(urls: [currentLayout.commonDir])
        ])
        let worktreeBindingEpoch = try Self.digestStrings([
            currentLayout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            currentLayout.gitDir.resolvingSymlinksInPath().standardizedFileURL.path,
            currentLayout.dotGitPath.resolvingSymlinksInPath().standardizedFileURL.path,
            bindingIdentityDigest(urls: [
                currentLayout.workTreeRoot,
                currentLayout.dotGitPath,
                currentLayout.gitDir
            ])
        ])

        return AuthorityCapture(
            layout: currentLayout,
            objectFormat: objectFormat,
            stableAuthority: StableAuthority(
                repositoryNamespace: namespace,
                objectFormat: objectFormat,
                repositoryBindingEpoch: repositoryBindingEpoch,
                worktreeBindingEpoch: worktreeBindingEpoch,
                layoutGeneration: layoutGeneration,
                indexGeneration: indexGeneration,
                checkoutConfigurationGeneration: checkoutConfigurationGeneration,
                attributeGeneration: attributeGeneration,
                sparseGeneration: sparseGeneration,
                metadataGeneration: metadataGeneration
            ),
            sourceClassificationEvidence: sourceClassificationEvidence
        )
    }

    private enum CapabilityCaptureError: Error {
        case layoutChanged
        case permissionDenied
        case authorityFileTooLarge
    }

    private static func transientReason(for error: Error) -> WorkspaceCodemapRootTransientUnavailableReason {
        if error is CancellationError { return .runtimeUnavailable }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        {
            return .permissionFailure
        }
        if error is GitService.GitError { return .gitProcessUnavailable }
        if let captureError = error as? CapabilityCaptureError {
            switch captureError {
            case .layoutChanged: return .repositoryChanging
            case .permissionDenied: return .permissionFailure
            case .authorityFileTooLarge: return .runtimeUnavailable
            }
        }
        return .runtimeUnavailable
    }

    private enum DirectoryState: Equatable {
        case valid
        case missing
        case permissionDenied
        case invalid
    }

    private static func directoryState(at url: URL) -> DirectoryState {
        guard url.isFileURL, url.path.hasPrefix("/") else { return .invalid }
        var statValue = stat()
        guard lstat(url.path, &statValue) == 0 else {
            return switch errno {
            case ENOENT, ENOTDIR: .missing
            case EACCES, EPERM: .permissionDenied
            default: .invalid
            }
        }
        guard (statValue.st_mode & S_IFMT) == S_IFDIR else { return .invalid }
        guard Darwin.access(url.path, R_OK | X_OK) == 0 else {
            return errno == EACCES || errno == EPERM ? .permissionDenied : .invalid
        }
        return .valid
    }

    private static func layoutState(_ layout: GitRepositoryLayout) -> DirectoryState {
        for directory in [layout.workTreeRoot, layout.gitDir, layout.commonDir] {
            let state = directoryState(at: directory)
            if state != .valid { return state }
        }
        return .valid
    }

    private static func repositoryRelativePrefix(loadedRoot: URL, worktreeRoot: URL) -> String? {
        let rootPath = worktreeRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let loadedPath = loadedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard loadedPath == rootPath || StandardizedPath.isDescendant(loadedPath, of: rootPath) else {
            return nil
        }
        if loadedPath == rootPath { return "" }
        return String(loadedPath.dropFirst(rootPath.count + 1))
    }

    private static func layoutIdentity(_ layout: GitRepositoryLayout) -> [String] {
        [layout.workTreeRoot, layout.dotGitPath, layout.gitDir, layout.commonDir].map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        }
    }

    private static func metadataURLs(layout: GitRepositoryLayout) -> [URL] {
        var urls = [
            layout.gitDir.appendingPathComponent("HEAD"),
            layout.commonDir.appendingPathComponent("HEAD"),
            layout.gitDir.appendingPathComponent("packed-refs"),
            layout.commonDir.appendingPathComponent("packed-refs")
        ]
        for headURL in [
            layout.gitDir.appendingPathComponent("HEAD"),
            layout.commonDir.appendingPathComponent("HEAD")
        ] {
            if let data = try? Data(contentsOf: headURL), data.count <= 4096,
               let value = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               value.hasPrefix("ref: ")
            {
                let relativeRef = String(value.dropFirst(5))
                if !relativeRef.hasPrefix("/"), !relativeRef.contains(".."), !relativeRef.contains("\0") {
                    urls.append(layout.gitDir.appendingPathComponent(relativeRef))
                    urls.append(layout.commonDir.appendingPathComponent(relativeRef))
                }
            }
        }
        return urls
    }

    private static func globalAttributeURLs(
        layout: GitRepositoryLayout,
        configuredAttributesFile: String?
    ) -> [URL] {
        var urls = [
            layout.gitDir.appendingPathComponent("info/attributes"),
            layout.commonDir.appendingPathComponent("info/attributes")
        ]
        if let configuredAttributesFile {
            // `git config --path --get core.attributesFile` expands `~` to an absolute path, while
            // relative values remain relative and `git check-attr` resolves them from the worktree root.
            let configuredURL = configuredAttributesFile.hasPrefix("/")
                ? URL(fileURLWithPath: configuredAttributesFile)
                : layout.workTreeRoot.appendingPathComponent(configuredAttributesFile)
            urls.append(configuredURL.standardizedFileURL)
        }
        return urls
    }

    private static func attributeURLs(
        layout: GitRepositoryLayout,
        loadedRoot: URL,
        configuredAttributesFile: String?
    ) -> [URL] {
        var urls = globalAttributeURLs(
            layout: layout,
            configuredAttributesFile: configuredAttributesFile
        )
        var directory = layout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL
        let target = loadedRoot.resolvingSymlinksInPath().standardizedFileURL
        while true {
            urls.append(directory.appendingPathComponent(".gitattributes"))
            if directory.path == target.path { break }
            let relative = String(target.path.dropFirst(directory.path.count))
                .split(separator: "/", omittingEmptySubsequences: true)
            guard let next = relative.first else { break }
            directory.appendPathComponent(String(next), isDirectory: true)
        }
        return urls
    }

    private static func candidateAttributeURLs(
        layout: GitRepositoryLayout,
        candidateRepositoryRelativePath: String
    ) throws -> [URL] {
        let components = candidateRepositoryRelativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, components.count <= 512 else {
            throw CapabilityCaptureError.authorityFileTooLarge
        }
        var urls: [URL] = []
        var directory = layout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL
        urls.append(directory.appendingPathComponent(".gitattributes"))
        for component in components.dropLast() {
            directory.appendPathComponent(String(component), isDirectory: true)
            urls.append(directory.appendingPathComponent(".gitattributes"))
        }
        return urls
    }

    private static func safeRepositoryRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !StandardizedPath.containsNUL(path) else { return nil }
        let standardized = StandardizedPath.relative(path)
        guard standardized != ".", standardized != "..", !standardized.hasPrefix("../") else { return nil }
        return standardized
    }

    private static func isCandidate(_ path: String, insideLoadedRootPrefix rawPrefix: String) -> Bool {
        guard let prefix = rawPrefix.isEmpty ? "" : safeRepositoryRelativePath(rawPrefix) else { return false }
        return prefix.isEmpty || path.hasPrefix(prefix + "/")
    }

    private struct DescriptorEvidence {
        let statValue: stat
        let contents: Data?
    }

    private struct DescriptorLink {
        let parentDescriptor: Int32
        let name: String
        let childStat: stat
    }

    private func digestEvidence(urls: [URL], includeBoundedContents: Bool) throws -> String {
        var data = Data()
        for path in Dictionary(grouping: urls, by: { $0.standardizedFileURL.path }).keys.sorted() {
            data.append(Data(path.utf8))
            data.append(0)
            guard let evidence = try descriptorEvidence(
                at: URL(fileURLWithPath: path),
                includeContents: includeBoundedContents,
                maximumContentByteCount: 1024 * 1024,
                missingAllowed: true
            ) else {
                data.append(0)
                continue
            }
            data.append(1)
            appendStatEvidence(evidence.statValue, to: &data)
            if let contents = evidence.contents {
                data.append(contents)
                data.append(0)
            }
        }
        return Self.hex(Data(SHA256.hash(data: data)))
    }

    private func bindingIdentityDigest(urls: [URL]) throws -> String {
        var data = Data()
        for path in Dictionary(grouping: urls, by: { $0.standardizedFileURL.path }).keys.sorted() {
            data.append(Data(path.utf8))
            data.append(0)
            guard let evidence = try descriptorEvidence(
                at: URL(fileURLWithPath: path),
                includeContents: true,
                maximumContentByteCount: 64 * 1024,
                missingAllowed: false
            ) else {
                throw POSIXError(.ENOENT)
            }
            data.append(Data([
                String(evidence.statValue.st_dev),
                String(evidence.statValue.st_ino),
                String(evidence.statValue.st_mode)
            ].joined(separator: ":").utf8))
            data.append(0)
            if let contents = evidence.contents {
                data.append(contents)
                data.append(0)
            }
        }
        return Self.hex(Data(SHA256.hash(data: data)))
    }

    private func descriptorEvidence(
        at url: URL,
        includeContents: Bool,
        maximumContentByteCount: Int64,
        missingAllowed: Bool
    ) throws -> DescriptorEvidence? {
        let path = Self.normalizedSystemAliasPath(url.standardizedFileURL.path)
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw POSIXError(.EINVAL)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, components.count <= 1024 else {
            throw POSIXError(.EINVAL)
        }
        let rootDescriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var descriptors = [rootDescriptor]
        var links: [DescriptorLink] = []
        defer {
            for descriptor in descriptors.reversed() {
                close(descriptor)
            }
        }

        for (index, component) in components.enumerated() {
            let parentDescriptor = descriptors[descriptors.count - 1]
            var linkStat = stat()
            let status = component.withCString { name in
                fstatat(parentDescriptor, name, &linkStat, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                if missingAllowed, errno == ENOENT || errno == ENOTDIR { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard (linkStat.st_mode & S_IFMT) != S_IFLNK else {
                throw CapabilityCaptureError.layoutChanged
            }
            let isLeaf = index == components.count - 1
            if !isLeaf, (linkStat.st_mode & S_IFMT) != S_IFDIR {
                if missingAllowed { return nil }
                throw POSIXError(.ENOTDIR)
            }
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK |
                (isLeaf ? 0 : O_DIRECTORY)
            let descriptor = component.withCString { name in
                openat(parentDescriptor, name, flags)
            }
            guard descriptor >= 0 else {
                if missingAllowed, errno == ENOENT || errno == ENOTDIR { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            descriptors.append(descriptor)
            var descriptorStat = stat()
            guard fstat(descriptor, &descriptorStat) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard sameStableStat(linkStat, descriptorStat) else {
                throw CapabilityCaptureError.layoutChanged
            }
            links.append(DescriptorLink(
                parentDescriptor: parentDescriptor,
                name: component,
                childStat: descriptorStat
            ))
        }

        let leafDescriptor = descriptors[descriptors.count - 1]
        let preStat = links[links.count - 1].childStat
        hooks.afterAuthorityEvidenceOpen(url)
        var contents: Data?
        if includeContents, (preStat.st_mode & S_IFMT) == S_IFREG {
            guard preStat.st_size >= 0, preStat.st_size <= maximumContentByteCount else {
                throw CapabilityCaptureError.authorityFileTooLarge
            }
            contents = try readBounded(
                descriptor: leafDescriptor,
                maximumByteCount: maximumContentByteCount
            )
        }
        var postStat = stat()
        guard fstat(leafDescriptor, &postStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard sameStableStat(preStat, postStat) else {
            throw CapabilityCaptureError.layoutChanged
        }
        for link in links {
            var current = stat()
            let status = link.name.withCString { name in
                fstatat(link.parentDescriptor, name, &current, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0,
                  sameDescriptorIdentity(link.childStat, current),
                  (current.st_mode & S_IFMT) != S_IFLNK
            else {
                throw CapabilityCaptureError.layoutChanged
            }
        }
        return DescriptorEvidence(statValue: postStat, contents: contents)
    }

    private func readBounded(descriptor: Int32, maximumByteCount: Int64) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Int64(data.count) <= maximumByteCount - Int64(count) else {
                throw CapabilityCaptureError.authorityFileTooLarge
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func appendStatEvidence(_ value: stat, to data: inout Data) {
        let evidence = [
            String(value.st_dev),
            String(value.st_ino),
            String(value.st_mode),
            String(value.st_size),
            String(value.st_mtimespec.tv_sec),
            String(value.st_mtimespec.tv_nsec),
            String(value.st_ctimespec.tv_sec),
            String(value.st_ctimespec.tv_nsec)
        ].joined(separator: ":")
        data.append(Data(evidence.utf8))
        data.append(0)
    }

    private func sameDescriptorIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
    }

    private func sameStableStat(_ lhs: stat, _ rhs: stat) -> Bool {
        sameDescriptorIdentity(lhs, rhs) &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// macOS exposes these immutable system aliases at the filesystem root. Normalize only
    /// those aliases; repository-controlled symlinks remain forbidden by descriptor traversal.
    private static func normalizedSystemAliasPath(_ path: String) -> String {
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")] {
            if path == alias { return target }
            if path.hasPrefix(alias + "/") { return target + path.dropFirst(alias.count) }
        }
        return path
    }

    private static func checkoutConfigurationValuesDigest(
        _ configuration: GitCodemapAuthorityConfiguration
    ) -> String {
        var values = [
            configuration.checkout.coreAutoCRLF ?? "<nil>",
            configuration.checkout.coreEOL ?? "<nil>",
            configuration.attributesFilePath ?? "<nil>"
        ]
        for key in configuration.checkout.filterDriverConfiguration.keys.sorted() {
            values.append(key)
            values.append(configuration.checkout.filterDriverConfiguration[key] ?? "")
        }
        return digestStrings(values)
    }

    private static func checkoutConfigurationDigest(
        _ configuration: GitCodemapAuthorityConfiguration,
        filesDigest: String
    ) throws -> String {
        var values = [
            filesDigest,
            configuration.checkout.coreAutoCRLF ?? "<nil>",
            configuration.checkout.coreEOL ?? "<nil>",
            configuration.attributesFilePath ?? "<nil>"
        ]
        for key in configuration.checkout.filterDriverConfiguration.keys.sorted() {
            values.append(key)
            values.append(configuration.checkout.filterDriverConfiguration[key] ?? "")
        }
        return digestStrings(values)
    }

    private static func sparseDigest(
        _ configuration: GitCodemapAuthorityConfiguration,
        filesDigest: String
    ) throws -> String {
        digestStrings([
            filesDigest,
            configuration.sparseCheckoutEnabled ? "1" : "0",
            configuration.sparseCheckoutConeEnabled ? "1" : "0"
        ])
    }

    private static func digestStrings(_ values: [String]) -> String {
        hex(Data(SHA256.hash(data: Data(values.joined(separator: "\0").utf8))))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
