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
            device: UInt64(value.st_dev),
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

struct WorkspaceCodemapSourceAuthorityToken: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let repositoryRelativeLoadedRootPrefix: String
    let standardizedRepositoryRelativePath: String
    let acceptedPrePathFingerprint: GitBlobLStatFingerprint
    let acceptedPostPathFingerprint: GitBlobLStatFingerprint
    let candidateAttributeGeneration: String
    let pathGeneration: UInt64
    let ingressGeneration: UInt64

    var isFactoryValidated: Bool {
        acceptedPrePathFingerprint == acceptedPostPathFingerprint &&
            acceptedPostPathFingerprint.isRegularFile &&
            !candidateAttributeGeneration.isEmpty
    }

    private init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        repositoryRelativeLoadedRootPrefix: String,
        standardizedRepositoryRelativePath: String,
        acceptedPrePathFingerprint: GitBlobLStatFingerprint,
        acceptedPostPathFingerprint: GitBlobLStatFingerprint,
        candidateAttributeGeneration: String,
        pathGeneration: UInt64,
        ingressGeneration: UInt64
    ) {
        self.rootEpoch = rootEpoch
        self.repositoryAuthority = repositoryAuthority
        self.repositoryRelativeLoadedRootPrefix = repositoryRelativeLoadedRootPrefix
        self.standardizedRepositoryRelativePath = standardizedRepositoryRelativePath
        self.acceptedPrePathFingerprint = acceptedPrePathFingerprint
        self.acceptedPostPathFingerprint = acceptedPostPathFingerprint
        self.candidateAttributeGeneration = candidateAttributeGeneration
        self.pathGeneration = pathGeneration
        self.ingressGeneration = ingressGeneration
    }

    fileprivate static func issue(
        capability: GitCodemapRootCapability,
        observedRootEpoch: WorkspaceCodemapRootEpoch,
        observedRepositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        candidateRepositoryRelativePath: String,
        acceptedPrePathFingerprint: GitBlobLStatFingerprint,
        acceptedPostPathFingerprint: GitBlobLStatFingerprint,
        candidateAttributeGeneration: String,
        observedPathGeneration: UInt64,
        currentPathGeneration: UInt64,
        observedIngressGeneration: UInt64,
        currentIngressGeneration: UInt64
    ) -> WorkspaceCodemapSourceAuthorityToken? {
        guard capability.rootEpoch == observedRootEpoch,
              capability.repositoryAuthority == observedRepositoryAuthority,
              capability.repositoryNamespace == capability.repositoryAuthority.repositoryNamespace,
              capability.objectFormat == capability.repositoryAuthority.objectFormat,
              acceptedPrePathFingerprint == acceptedPostPathFingerprint,
              acceptedPostPathFingerprint.isRegularFile,
              observedPathGeneration == currentPathGeneration,
              observedIngressGeneration == currentIngressGeneration,
              !candidateAttributeGeneration.isEmpty,
              let path = standardizedSafeRelativePath(candidateRepositoryRelativePath),
              let prefix = standardizedPrefix(capability.repositoryRelativeLoadedRootPrefix),
              isCandidate(path, insideLoadedRootPrefix: prefix)
        else { return nil }

        return WorkspaceCodemapSourceAuthorityToken(
            rootEpoch: observedRootEpoch,
            repositoryAuthority: observedRepositoryAuthority,
            repositoryRelativeLoadedRootPrefix: prefix,
            standardizedRepositoryRelativePath: path,
            acceptedPrePathFingerprint: acceptedPrePathFingerprint,
            acceptedPostPathFingerprint: acceptedPostPathFingerprint,
            candidateAttributeGeneration: candidateAttributeGeneration,
            pathGeneration: observedPathGeneration,
            ingressGeneration: observedIngressGeneration
        )
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

    private static func isCandidate(_ path: String, insideLoadedRootPrefix prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        return path.hasPrefix(prefix + "/")
    }
}

struct WorkspaceCodemapGitCapabilityServiceHooks {
    var beforeResolution: @Sendable () async -> Void
    var afterFirstAuthorityCapture: @Sendable () async -> Void
    var afterSourcePathFingerprintCapture: @Sendable () async -> Void
    var afterAuthorityEvidenceOpen: @Sendable (URL) -> Void

    init(
        beforeResolution: @escaping @Sendable () async -> Void = {},
        afterFirstAuthorityCapture: @escaping @Sendable () async -> Void = {},
        afterSourcePathFingerprintCapture: @escaping @Sendable () async -> Void = {},
        afterAuthorityEvidenceOpen: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.beforeResolution = beforeResolution
        self.afterFirstAuthorityCapture = afterFirstAuthorityCapture
        self.afterSourcePathFingerprintCapture = afterSourcePathFingerprintCapture
        self.afterAuthorityEvidenceOpen = afterAuthorityEvidenceOpen
    }

    static let none = WorkspaceCodemapGitCapabilityServiceHooks()
}

actor WorkspaceCodemapGitCapabilityService {
    #if DEBUG
        struct Snapshot: Equatable {
            let activeRecordCount: Int
            let historicalRecordCount: Int
            let activeFlightCount: Int
            let waiterCount: Int
            let resolutionObserverCount: Int
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
    }

    private struct AuthorityCapture: Equatable {
        let layout: GitRepositoryLayout
        let objectFormat: GitObjectFormat
        let stableAuthority: StableAuthority
    }

    private struct RootBinding: Hashable {
        let standardizedLoadedRootPath: String
        var repositoryID: String?
        var worktreeID: String?
    }

    private struct RootRecord {
        var state: WorkspaceCodemapGitCapabilityState = .unresolved
        var resolutionGeneration: UInt64 = 0
        var authorityGeneration: UInt64 = 0
        var stableAuthority: StableAuthority?
        var binding: RootBinding
        var retainedWorkTreeRoot: URL?
        var retainedGitDirectory: URL?
    }

    private struct RootFlight {
        let id: UUID
        let resolutionGeneration: UInt64
        let priorState: WorkspaceCodemapGitCapabilityState
        let task: Task<Resolution, Never>
        var waiters: [UUID: CheckedContinuation<WorkspaceCodemapGitCapabilityState, Never>]
    }

    private struct HistoricalRecord {
        let binding: RootBinding
        let finalState: WorkspaceCodemapGitCapabilityState
        let releaseOrdinal: UInt64
    }

    private enum Resolution {
        case eligible(
            layout: GitRepositoryLayout,
            prefix: String,
            repositoryIdentity: GitWorktreeRepositoryIdentity,
            worktreeID: String,
            authority: StableAuthority
        )
        case terminal(WorkspaceCodemapGitTerminalUnavailableReason)
        case transient(WorkspaceCodemapGitTransientUnavailableReason)
    }

    private let gitService: GitService
    private let namespaceSalt: Data
    private let hooks: WorkspaceCodemapGitCapabilityServiceHooks
    private let pathFingerprintClient: WorkspaceCodemapPathFingerprintClient
    private let historicalRecordLimit: Int
    private var records: [WorkspaceCodemapRootEpoch: RootRecord] = [:]
    private var flights: [WorkspaceCodemapRootEpoch: RootFlight] = [:]
    private var resolutionObservers: [UUID: Task<Void, Never>] = [:]
    private var rootEpochByWaiterID: [UUID: WorkspaceCodemapRootEpoch] = [:]
    private var historicalRecords: [WorkspaceCodemapRootEpoch: HistoricalRecord] = [:]
    private var releaseOrdinal: UInt64 = 0

    init(
        gitService: GitService = GitService(),
        namespaceSalt: Data,
        hooks: WorkspaceCodemapGitCapabilityServiceHooks = .none,
        pathFingerprintClient: WorkspaceCodemapPathFingerprintClient = .noFollow,
        historicalRecordLimit: Int = 64
    ) {
        precondition(historicalRecordLimit > 0)
        self.gitService = gitService
        self.namespaceSalt = namespaceSalt
        self.hooks = hooks
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

    func state(for rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapGitCapabilityState {
        if let state = records[rootEpoch]?.state { return state }
        if historicalRecords[rootEpoch] != nil { return .terminalUnavailable(.releasedRootEpoch) }
        return .unresolved
    }

    @discardableResult
    func resolve(
        root request: WorkspaceCodemapGitCapabilityRequest
    ) async -> WorkspaceCodemapGitCapabilityState {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(waiterID: waiterID, request: request, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    @discardableResult
    func reload(
        root request: WorkspaceCodemapGitCapabilityRequest
    ) async -> WorkspaceCodemapGitCapabilityState {
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
        return await resolve(root: request)
    }

    @discardableResult
    func retarget(
        from oldRootEpoch: WorkspaceCodemapRootEpoch,
        to request: WorkspaceCodemapGitCapabilityRequest
    ) async -> WorkspaceCodemapGitCapabilityState {
        await release(rootEpoch: oldRootEpoch)
        return await resolve(root: request)
    }

    func invalidateForAuthorityReplacement(rootEpoch: WorkspaceCodemapRootEpoch) async {
        cancelFlight(for: rootEpoch, restoring: .unresolved)
        guard let record = records.removeValue(forKey: rootEpoch) else { return }
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
        guard let record = records.removeValue(forKey: rootEpoch) else { return }
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
                resolutionObserverCount: resolutionObservers.count
            )
        }
    #endif

    private func enqueue(
        waiterID: UUID,
        request: WorkspaceCodemapGitCapabilityRequest,
        continuation: CheckedContinuation<WorkspaceCodemapGitCapabilityState, Never>
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
            return await resolveCandidate(loadedRootURL: loadedRootURL)
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

        if case let .eligible(layout, _, _, _, _) = resolution,
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
        case let .eligible(layout, prefix, repositoryIdentity, worktreeID, authority):
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
                    record.authorityGeneration &+= 1
                    if record.authorityGeneration == 0 { record.authorityGeneration = 1 }
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
                    GitCodemapRootCapability(
                        rootEpoch: rootEpoch,
                        repositoryLayout: layout,
                        repositoryIdentity: repositoryIdentity,
                        worktreeID: worktreeID,
                        repositoryNamespace: authority.repositoryNamespace,
                        objectFormat: authority.objectFormat,
                        repositoryRelativeLoadedRootPrefix: prefix,
                        repositoryAuthority: token
                    )
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
        restoring state: WorkspaceCodemapGitCapabilityState
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
        }
    }

    private static func restorableState(
        _ state: WorkspaceCodemapGitCapabilityState
    ) -> WorkspaceCodemapGitCapabilityState {
        if case .resolving = state { return .unresolved }
        return state
    }

    func makeSourceAuthority(
        capability: GitCodemapRootCapability,
        observedRootEpoch: WorkspaceCodemapRootEpoch,
        observedRepositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        candidateRepositoryRelativePath: String,
        observedPathGeneration: UInt64,
        currentPathGeneration: UInt64,
        observedIngressGeneration: UInt64,
        currentIngressGeneration: UInt64
    ) async -> WorkspaceCodemapSourceAuthorityToken? {
        guard let record = records[capability.rootEpoch],
              case let .eligible(activeCapability) = record.state,
              activeCapability == capability,
              let stableAuthority = record.stableAuthority,
              let candidatePath = Self.safeRepositoryRelativePath(candidateRepositoryRelativePath),
              Self.isCandidate(
                  candidatePath,
                  insideLoadedRootPrefix: capability.repositoryRelativeLoadedRootPrefix
              )
        else { return nil }
        let loadedRoot = URL(fileURLWithPath: record.binding.standardizedLoadedRootPath)

        do {
            let prePathFingerprint = try pathFingerprintClient.fingerprint(
                capability.repositoryLayout.workTreeRoot,
                candidatePath
            )
            guard prePathFingerprint.isRegularFile else { return nil }
            await hooks.afterSourcePathFingerprintCapture()
            try Task.checkCancellation()
            let preRepository = try await captureAuthority(
                loadedRoot: loadedRoot,
                expectedLayout: capability.repositoryLayout,
                prefix: capability.repositoryRelativeLoadedRootPrefix
            )
            guard preRepository.stableAuthority == stableAuthority else { return nil }
            let preAttributes = try digestEvidence(
                urls: Self.candidateAttributeURLs(
                    layout: capability.repositoryLayout,
                    candidateRepositoryRelativePath: candidatePath
                ),
                includeBoundedContents: true
            )
            try Task.checkCancellation()
            let postAttributes = try digestEvidence(
                urls: Self.candidateAttributeURLs(
                    layout: capability.repositoryLayout,
                    candidateRepositoryRelativePath: candidatePath
                ),
                includeBoundedContents: true
            )
            let postRepository = try await captureAuthority(
                loadedRoot: loadedRoot,
                expectedLayout: capability.repositoryLayout,
                prefix: capability.repositoryRelativeLoadedRootPrefix
            )
            let postPathFingerprint = try pathFingerprintClient.fingerprint(
                capability.repositoryLayout.workTreeRoot,
                candidatePath
            )
            guard preAttributes == postAttributes,
                  preRepository == postRepository,
                  postRepository.stableAuthority == stableAuthority,
                  prePathFingerprint == postPathFingerprint,
                  postPathFingerprint.isRegularFile,
                  case let .eligible(currentCapability) = records[capability.rootEpoch]?.state,
                  currentCapability == capability
            else { return nil }

            return WorkspaceCodemapSourceAuthorityToken.issue(
                capability: capability,
                observedRootEpoch: observedRootEpoch,
                observedRepositoryAuthority: observedRepositoryAuthority,
                candidateRepositoryRelativePath: candidatePath,
                acceptedPrePathFingerprint: prePathFingerprint,
                acceptedPostPathFingerprint: postPathFingerprint,
                candidateAttributeGeneration: postAttributes,
                observedPathGeneration: observedPathGeneration,
                currentPathGeneration: currentPathGeneration,
                observedIngressGeneration: observedIngressGeneration,
                currentIngressGeneration: currentIngressGeneration
            )
        } catch {
            return nil
        }
    }

    /// Revalidates previously issued source-authority tokens against one stable repository/path window.
    /// This reads Git metadata and no-follow path fingerprints only; it never reads source bytes.
    func revalidateSourceAuthorities(
        capability: GitCodemapRootCapability,
        tokens: [WorkspaceCodemapSourceAuthorityToken]
    ) async -> Bool {
        guard let record = records[capability.rootEpoch],
              case let .eligible(activeCapability) = record.state,
              activeCapability == capability,
              let stableAuthority = record.stableAuthority
        else { return false }
        if tokens.isEmpty { return true }

        var candidatePaths = Set<String>()
        for token in tokens {
            guard token.isFactoryValidated,
                  token.rootEpoch == capability.rootEpoch,
                  token.repositoryAuthority == capability.repositoryAuthority,
                  token.repositoryRelativeLoadedRootPrefix == capability.repositoryRelativeLoadedRootPrefix,
                  let candidatePath = Self.safeRepositoryRelativePath(token.standardizedRepositoryRelativePath),
                  candidatePath == token.standardizedRepositoryRelativePath,
                  Self.isCandidate(
                      candidatePath,
                      insideLoadedRootPrefix: capability.repositoryRelativeLoadedRootPrefix
                  ),
                  candidatePaths.insert(candidatePath).inserted
            else { return false }
        }

        let loadedRoot = URL(fileURLWithPath: record.binding.standardizedLoadedRootPath)
        do {
            var prePathFingerprints: [String: GitBlobLStatFingerprint] = [:]
            var preAttributeGenerations: [String: String] = [:]
            for token in tokens {
                let path = token.standardizedRepositoryRelativePath
                let fingerprint = try pathFingerprintClient.fingerprint(
                    capability.repositoryLayout.workTreeRoot,
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
                expectedLayout: capability.repositoryLayout,
                prefix: capability.repositoryRelativeLoadedRootPrefix
            )
            guard preRepository.stableAuthority == stableAuthority else { return false }

            for token in tokens {
                let path = token.standardizedRepositoryRelativePath
                let generation = try digestEvidence(
                    urls: Self.candidateAttributeURLs(
                        layout: capability.repositoryLayout,
                        candidateRepositoryRelativePath: path
                    ),
                    includeBoundedContents: true
                )
                guard generation == token.candidateAttributeGeneration else { return false }
                preAttributeGenerations[path] = generation
            }
            try Task.checkCancellation()

            for token in tokens {
                let path = token.standardizedRepositoryRelativePath
                let generation = try digestEvidence(
                    urls: Self.candidateAttributeURLs(
                        layout: capability.repositoryLayout,
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
                expectedLayout: capability.repositoryLayout,
                prefix: capability.repositoryRelativeLoadedRootPrefix
            )
            guard preRepository == postRepository,
                  postRepository.stableAuthority == stableAuthority
            else { return false }

            for token in tokens {
                let path = token.standardizedRepositoryRelativePath
                let fingerprint = try pathFingerprintClient.fingerprint(
                    capability.repositoryLayout.workTreeRoot,
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

    private func resolveCandidate(loadedRootURL: URL) async -> Resolution {
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

        let repositoryRoot: URL
        do {
            guard let resolved = try await gitService.findGitRoot(from: loadedRoot) else {
                return switch try await gitService.gitRepositoryKind(at: loadedRoot) {
                case .nonGit: .terminal(.nonGit)
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
                return .eligible(
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

    private func captureAuthority(
        loadedRoot: URL,
        expectedLayout: GitRepositoryLayout,
        prefix: String
    ) async throws -> AuthorityCapture {
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
            )
        )
    }

    private enum CapabilityCaptureError: Error {
        case layoutChanged
        case permissionDenied
        case authorityFileTooLarge
    }

    private static func transientReason(for error: Error) -> WorkspaceCodemapGitTransientUnavailableReason {
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

    private static func attributeURLs(
        layout: GitRepositoryLayout,
        loadedRoot: URL,
        configuredAttributesFile: String?
    ) -> [URL] {
        var urls = [
            layout.gitDir.appendingPathComponent("info/attributes"),
            layout.commonDir.appendingPathComponent("info/attributes")
        ]
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
        if let configuredAttributesFile {
            let configuredURL = URL(fileURLWithPath: configuredAttributesFile, relativeTo: layout.commonDir)
                .standardizedFileURL
            urls.append(configuredURL)
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
