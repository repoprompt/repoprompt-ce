import Foundation

actor WorkspaceRootReusableSnapshotCoordinator {
    enum CurrentnessValidation: Equatable {
        case current
        case stale(ObservationFailureCause)
    }

    typealias CurrentnessValidator = @Sendable () async -> CurrentnessValidation
    typealias CatalogEvidenceProvider = @Sendable (WorkspaceRootByteExactPathSet) async -> WorkspaceRootCatalogProjectionEvidence?

    enum CatalogBatchEvidenceResult {
        case evidence(WorkspaceRootCatalogProjectionEvidence)
        case catalogMismatch
        case stale(ObservationFailureCause)
    }

    typealias CatalogBatchEvidenceProvider = @Sendable ([String]) async -> CatalogBatchEvidenceResult

    enum ObservationFailureStage: String, Equatable {
        case loadedRootValidation = "loaded_root_validation"
        case initialCurrentness = "initial_currentness"
        case discoveryObservation = "discovery_observation"
        case discoveryAuthorityCapture = "discovery_authority_capture"
        case replacementObservation = "replacement_observation"
        case collection
        case capturedAuthority = "captured_authority"
        case treeInventory = "tree_inventory"
        case catalogClassification = "catalog_classification"
        case admissionPreparation = "admission_preparation"
        case preparedAdmissionCurrentness = "prepared_admission_currentness"
        case admissionCommit = "admission_commit"
        case committedAdmissionCurrentness = "committed_admission_currentness"
        case finalLoadedRootCurrentness = "final_loaded_root_currentness"
    }

    enum ObservationFailureCause: Equatable {
        case cancelled
        case staleCurrentness
        case loadedRootOwnerStale
        case loadedRootCatalogStale
        case loadedRootWatcherStale
        case authorityEvidenceResourceUnavailable
        case authorityEvidenceIOFailure
        case authorityEvidenceCorrupt
        case boundedGitFailure(GitWorktreeInitializationFailureReason)
        case admissionRejected
        case unexpectedFailure

        var code: String {
            switch self {
            case .cancelled: "cancelled"
            case .staleCurrentness: "stale_currentness"
            case .loadedRootOwnerStale: "loaded_root_owner_stale"
            case .loadedRootCatalogStale: "loaded_root_catalog_stale"
            case .loadedRootWatcherStale: "loaded_root_watcher_stale"
            case .authorityEvidenceResourceUnavailable: "authority_evidence_resource_unavailable"
            case .authorityEvidenceIOFailure: "authority_evidence_io_failure"
            case .authorityEvidenceCorrupt: "authority_evidence_corrupt"
            case .boundedGitFailure(.timeout): "git_timeout"
            case .boundedGitFailure(.gitError): "git_error"
            case .boundedGitFailure(.malformedOutput): "git_malformed_output"
            case .boundedGitFailure(.cappedOutput): "git_capped_output"
            case .boundedGitFailure(.recordLimitExceeded): "git_record_limit_exceeded"
            case .boundedGitFailure(.pathLimitExceeded): "git_path_limit_exceeded"
            case .boundedGitFailure(.invalidRootPrefix): "git_invalid_root_prefix"
            case .boundedGitFailure(.cancelled): "git_cancelled"
            case .admissionRejected: "admission_rejected"
            case .unexpectedFailure: "unexpected_failure"
            }
        }
    }

    struct ObservationFailure: Equatable {
        let stage: ObservationFailureStage
        let cause: ObservationFailureCause
    }

    enum ObservationResult: Equatable {
        case admitted(WorkspaceRootReusableSnapshotIdentity)
        case nonGit
        case unsupportedRoot
        case authorityUnavailable(
            stage: ObservationFailureStage,
            reason: GitWorkspaceAuthorityUnavailableReason
        )
        case catalogMismatch
        case failed(ObservationFailure)
    }

    static let shared = WorkspaceRootReusableSnapshotCoordinator()

    private let gitService: GitService
    private let authority: GitWorkspaceStateAuthority
    #if DEBUG
        private var preparedAdmissionHandlerForTesting: (@Sendable () async -> Void)?
    #endif

    init(
        gitService: GitService = GitService(),
        authority: GitWorkspaceStateAuthority = .shared
    ) {
        self.gitService = gitService
        self.authority = authority
    }

    func observeAuthoritativeFullLoad(
        rootURL: URL,
        authoritativeRelativeFilePaths: some Sequence<String>,
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity = .canonicalDefaults,
        catalogEvidenceProvider: CatalogEvidenceProvider? = nil,
        currentnessValidator: @escaping CurrentnessValidator = { .current }
    ) async -> ObservationResult {
        guard let authoritativeExactPaths = WorkspaceRootByteExactPathSet(authoritativeRelativeFilePaths) else {
            return .catalogMismatch
        }
        let batchProvider: CatalogBatchEvidenceProvider = { paths in
            guard let batch = WorkspaceRootByteExactPathSet(paths, rejectExactDuplicates: true) else {
                return .catalogMismatch
            }
            let missing = batch.subtracting(authoritativeExactPaths)
            var dispositions: [WorkspaceRootByteExactPathKey: WorkspaceRootCommittedRegularProjectionDisposition] = [:]
            dispositions.reserveCapacity(batch.count)
            for path in batch.sortedKeys where authoritativeExactPaths.contains(path) {
                dispositions[path] = .searchableRegularFile
            }
            var revision: UInt64 = 0
            if !missing.isEmpty {
                guard let catalogEvidenceProvider,
                      let evidence = await catalogEvidenceProvider(missing),
                      evidence.policyIdentity == catalogPolicyIdentity,
                      Set(evidence.dispositionsByRelativePath.keys) == missing.keys
                else { return .catalogMismatch }
                revision = evidence.ignoreRulesRevision
                for (path, disposition) in evidence.dispositionsByRelativePath {
                    guard disposition == .policyIgnoredRegularFile else { return .catalogMismatch }
                    dispositions[path] = disposition
                }
            }
            return .evidence(WorkspaceRootCatalogProjectionEvidence(
                policyIdentity: catalogPolicyIdentity,
                dispositionsByRelativePath: dispositions,
                ignoreRulesRevision: revision
            ))
        }
        return await observeStreamedAuthoritativeFullLoad(
            rootURL: rootURL,
            catalogPolicyIdentity: catalogPolicyIdentity,
            catalogBatchEvidenceProvider: batchProvider,
            currentnessValidator: currentnessValidator
        )
    }

    func observeStreamedAuthoritativeFullLoad(
        rootURL: URL,
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity = .canonicalDefaults,
        prefixControlEvidenceCacheMode: GitPrefixControlEvidenceCacheMode = .bypassReadAndAdmission,
        catalogBatchEvidenceProvider: @escaping CatalogBatchEvidenceProvider,
        currentnessValidator: @escaping CurrentnessValidator = { .current }
    ) async -> ObservationResult {
        if let failure = await Self.currentnessFailure(
            stage: .initialCurrentness,
            validator: currentnessValidator
        ) {
            return failure
        }
        guard let layout = Self.gitLayoutContaining(rootURL) else { return .nonGit }
        guard let prefix = try? Self.rootPrefix(rootURL: rootURL, layout: layout) else {
            return .unsupportedRoot
        }

        var discoveryObservation: GitWorkspaceMetadataMonitor.RetainToken?
        var replacementObservation: GitWorkspaceMetadataMonitor.RetainToken?
        var activeStage = ObservationFailureStage.discoveryObservation
        do {
            // The base observation stays live until replacement coverage has been
            // installed. A policy-path change during either collection advances
            // the shared watermark and prevents conditional admission.
            let discoveryToken = try await {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.discoveryObservation)
                    defer { span?.end() }
                #endif
                return try await authority.retainMetadataObservation(for: layout)
            }()
            discoveryObservation = discoveryToken
            if let failure = await Self.currentnessFailure(
                stage: .discoveryObservation,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(discoveryToken)
                return failure
            }
            activeStage = .discoveryAuthorityCapture
            let discovery = try await {
                #if DEBUG
                    let recorder = WorktreeStartupPreparationInstrumentation.currentRecorder
                    recorder?.increment(.authorityCaptures)
                    let span = recorder?.begin(.discoveryAuthorityCapture)
                    defer { span?.end() }
                #endif
                return try await gitService.workspaceAuthoritySnapshot(
                    in: layout,
                    prefix: prefix,
                    cacheMode: prefixControlEvidenceCacheMode
                )
            }()
            if let failure = await Self.currentnessFailure(
                stage: .discoveryAuthorityCapture,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(discoveryToken)
                return failure
            }
            let discoveredExternalPaths = Self.canonicalPathSet(
                discovery.metadata.resolvedExternalAuthorityPaths
            )

            activeStage = .replacementObservation
            let observation = try await {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.replacementObservation)
                    defer { span?.end() }
                #endif
                return try await authority.retainMetadataObservation(
                    for: layout,
                    additionalAuthorityPaths: discovery.metadata.resolvedExternalAuthorityPaths
                )
            }()
            replacementObservation = observation
            if let failure = await Self.currentnessFailure(
                stage: .replacementObservation,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                await authority.releaseMetadataObservation(discoveryToken)
                return failure
            }
            await authority.releaseMetadataObservation(discoveryToken)
            discoveryObservation = nil
            if let failure = await Self.currentnessFailure(
                stage: .collection,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }

            let scope = GitWorkspaceAuthorityScopeKey(
                repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
                repositoryRelativeRootPrefix: prefix
            )
            let captureToken: GitWorkspaceAuthorityCaptureToken
            activeStage = .collection
            let collectionResult = await {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.collectionFence)
                    defer { span?.end() }
                #endif
                return await authority.beginCollection(scopeKey: scope)
            }()
            switch collectionResult {
            case let .success(token):
                captureToken = token
            case let .failure(reason):
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(stage: .collection, reason: reason)
            }
            if let failure = await Self.currentnessFailure(
                stage: .collection,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }

            activeStage = .capturedAuthority
            let captured = try await {
                #if DEBUG
                    let recorder = WorktreeStartupPreparationInstrumentation.currentRecorder
                    recorder?.increment(.authorityCaptures)
                    let span = recorder?.begin(.capturedAuthorityCapture)
                    defer { span?.end() }
                #endif
                return try await gitService.workspaceAuthoritySnapshot(
                    in: layout,
                    prefix: prefix,
                    cacheMode: prefixControlEvidenceCacheMode
                )
            }()
            if let failure = await Self.currentnessFailure(
                stage: .capturedAuthority,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }
            guard Self.canonicalPathSet(captured.metadata.resolvedExternalAuthorityPaths) == discoveredExternalPaths else {
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(
                    stage: .capturedAuthority,
                    reason: .invalidatedDuringCollection
                )
            }
            let observationIsCurrent = await {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.capturedObservationValidation)
                    defer { span?.end() }
                #endif
                return await authority.metadataObservationIsCurrent(
                    observation,
                    for: layout,
                    additionalAuthorityPaths: captured.metadata.resolvedExternalAuthorityPaths,
                    expectedAcceptedWatermark: captureToken.acceptedMetadataWatermark
                )
            }()
            guard observationIsCurrent else {
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(
                    stage: .capturedAuthority,
                    reason: .invalidatedDuringCollection
                )
            }
            if let failure = await Self.currentnessFailure(
                stage: .capturedAuthority,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }
            activeStage = .treeInventory
            let treeSpool = try await {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.treeInventorySpool)
                    defer { span?.end() }
                #endif
                return try await gitService.spoolLoadedRootTreeInventory(
                    captured.snapshot.treeOID,
                    in: layout,
                    prefix: prefix
                )
            }()
            if let failure = await Self.currentnessFailure(
                stage: .treeInventory,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }
            activeStage = .catalogClassification
            let inventoryManifest: WorkspaceRootReusableInventoryManifestLease
            do {
                inventoryManifest = try await {
                    #if DEBUG
                        let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                            .begin(.catalogManifestBuild)
                        defer { span?.end() }
                    #endif
                    return try await Self.buildInventoryManifest(
                        spool: treeSpool,
                        authority: captured.snapshot,
                        catalogPolicyIdentity: catalogPolicyIdentity,
                        catalogBatchEvidenceProvider: catalogBatchEvidenceProvider,
                        currentnessValidator: currentnessValidator
                    )
                }()
            } catch let error as WorkspaceRootReusableInventoryProjectionError {
                await authority.releaseMetadataObservation(observation)
                switch error {
                case .catalogMismatch:
                    return .catalogMismatch
                case let .stale(cause):
                    return .failed(.init(stage: .catalogClassification, cause: cause))
                }
            }
            let lease: GitWorkspaceAuthorityLease
            let installResult = await {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.authorityInstall)
                    defer { span?.end() }
                #endif
                return await authority.install(captured.snapshot, capturedUsing: captureToken)
            }()
            switch installResult {
            case let .success(installed):
                lease = installed
            case let .failure(reason):
                await authority.releaseMetadataObservation(observation)
                return .authorityUnavailable(stage: .treeInventory, reason: reason)
            }
            if let failure = await Self.currentnessFailure(
                stage: .admissionPreparation,
                validator: currentnessValidator
            ) {
                await authority.releaseMetadataObservation(observation)
                return failure
            }
            let snapshot = {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.snapshotMaterialization)
                    defer { span?.end() }
                #endif
                return WorkspaceRootReusableSnapshot.make(
                    authority: captured.snapshot,
                    inventoryManifest: inventoryManifest,
                    catalogPolicyIdentity: catalogPolicyIdentity
                )
            }()
            guard let snapshot else {
                await authority.releaseMetadataObservation(observation)
                return .catalogMismatch
            }
            activeStage = .admissionPreparation
            let preparedAdmission = await {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.admissionPrepare)
                    defer { span?.end() }
                #endif
                return await authority.prepareReusableSnapshotAdmission(
                    snapshot,
                    capturedUsing: lease,
                    observationToken: observation
                )
            }()
            replacementObservation = nil
            if Task.isCancelled {
                if let preparedAdmission {
                    await authority.cancelPreparedReusableSnapshotAdmission(preparedAdmission)
                }
                return .failed(.init(stage: .admissionPreparation, cause: .cancelled))
            }
            guard let prepared = preparedAdmission else {
                return .failed(.init(stage: .admissionPreparation, cause: .admissionRejected))
            }
            #if DEBUG
                if let preparedAdmissionHandlerForTesting {
                    await preparedAdmissionHandlerForTesting()
                }
            #endif
            if let failure = await Self.currentnessFailure(
                stage: .preparedAdmissionCurrentness,
                validator: currentnessValidator
            ) {
                await authority.cancelPreparedReusableSnapshotAdmission(prepared)
                return failure
            }
            let preparedAdmissionIsCurrent = await {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.preparedAdmissionCurrentness)
                    defer { span?.end() }
                #endif
                return await authority.preparedReusableSnapshotAdmissionIsCurrent(prepared)
            }()
            guard preparedAdmissionIsCurrent else {
                await authority.cancelPreparedReusableSnapshotAdmission(prepared)
                return .authorityUnavailable(
                    stage: .preparedAdmissionCurrentness,
                    reason: .invalidatedDuringCollection
                )
            }
            if let failure = await Self.currentnessFailure(
                stage: .preparedAdmissionCurrentness,
                validator: currentnessValidator
            ) {
                await authority.cancelPreparedReusableSnapshotAdmission(prepared)
                return failure
            }
            activeStage = .admissionCommit
            let committedAdmission = await {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.admissionCommit)
                    defer { span?.end() }
                #endif
                return await authority.admitPreparedReusableSnapshot(prepared)
            }()
            if Task.isCancelled {
                if let committedAdmission {
                    await authority.revokeReusableSnapshotAdmission(committedAdmission)
                }
                return .failed(.init(stage: .admissionCommit, cause: .cancelled))
            }
            guard let receipt = committedAdmission else {
                return .failed(.init(stage: .admissionCommit, cause: .admissionRejected))
            }
            if let failure = await Self.currentnessFailure(
                stage: .committedAdmissionCurrentness,
                validator: currentnessValidator
            ) {
                await authority.revokeReusableSnapshotAdmission(receipt)
                return failure
            }
            let committedAdmissionIsCurrent = await {
                #if DEBUG
                    let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                        .begin(.committedAdmissionCurrentness)
                    defer { span?.end() }
                #endif
                return await authority.reusableSnapshotAdmissionIsCurrent(receipt)
            }()
            guard committedAdmissionIsCurrent else {
                await authority.revokeReusableSnapshotAdmission(receipt)
                return .authorityUnavailable(
                    stage: .committedAdmissionCurrentness,
                    reason: .invalidatedDuringCollection
                )
            }
            if let failure = await Self.currentnessFailure(
                stage: .committedAdmissionCurrentness,
                validator: currentnessValidator
            ) {
                await authority.revokeReusableSnapshotAdmission(receipt)
                return failure
            }
            return .admitted(receipt.snapshotIdentity)
        } catch {
            if let discoveryObservation {
                await authority.releaseMetadataObservation(discoveryObservation)
            }
            if let replacementObservation {
                await authority.releaseMetadataObservation(replacementObservation)
            }
            let cause: ObservationFailureCause = if Task.isCancelled || error is CancellationError {
                .cancelled
            } else if let gitError = error as? GitWorktreeInitializationError {
                .boundedGitFailure(gitError.reason)
            } else if let manifestError = error as? WorkspaceRootReusableInventoryManifestError {
                switch manifestError {
                case .resourceAdmission: .authorityEvidenceResourceUnavailable
                case .io: .authorityEvidenceIOFailure
                case .invalidConfiguration, .invalidRecord, .duplicateRecord,
                     .canonicalPathCollision, .outOfOrder, .closed, .corrupt:
                    .authorityEvidenceCorrupt
                }
            } else if let spoolError = error as? GitRawOutputSpoolError {
                switch spoolError {
                case .resourceAdmission: .authorityEvidenceResourceUnavailable
                case .io: .authorityEvidenceIOFailure
                case .invalidConfiguration, .closed, .corrupt: .authorityEvidenceCorrupt
                }
            } else if let prefixError = error as? GitPrefixControlEvidenceManifestError {
                switch prefixError {
                case .resourceAdmission: .authorityEvidenceResourceUnavailable
                case .io: .authorityEvidenceIOFailure
                case .invalidConfiguration, .invalidRecord, .duplicateRecord,
                     .outOfOrder, .closed, .corrupt:
                    .authorityEvidenceCorrupt
                }
            } else if let collectionError = error as? GitTargetEvidenceCollectionError {
                Self.observationCause(for: collectionError)
            } else if let prefixError = error as? GitPrefixControlEvidenceCacheError {
                Self.observationCause(for: prefixError)
            } else if Self.isAuthorityEvidenceIOError(error) {
                .authorityEvidenceIOFailure
            } else {
                .unexpectedFailure
            }
            return .failed(.init(stage: activeStage, cause: cause))
        }
    }

    #if DEBUG
        func setPreparedAdmissionHandlerForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) {
            preparedAdmissionHandlerForTesting = handler
        }
    #endif

    private nonisolated static func buildInventoryManifest(
        spool: GitLoadedRootTreeInventorySpool,
        authority: GitWorkspaceAuthoritySnapshot,
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity,
        catalogBatchEvidenceProvider: @escaping CatalogBatchEvidenceProvider,
        currentnessValidator: @escaping CurrentnessValidator
    ) async throws -> WorkspaceRootReusableInventoryManifestLease {
        let compatibilityKey = WorkspaceRootSeedCompatibilityKey(authority: authority)
        let header = WorkspaceRootReusableInventoryManifestHeader(
            compatibilityDomain: WorkspaceRootReusableSnapshot.manifestCompatibilityDomain,
            compatibilityDigest: WorkspaceRootReusableSnapshot.compatibilityDigest(compatibilityKey),
            treeOID: authority.treeOID,
            objectFormat: authority.objectFormat,
            repositoryRelativeRootPrefix: authority.repositoryRelativeRootPrefix,
            commandFormat: GitLoadedRootTreeInventorySpool.commandFormat,
            rawStandardOutputDigest: spool.stdoutSHA256,
            catalogPolicyDigest: WorkspaceRootReusableSnapshot.catalogPolicyDigest(catalogPolicyIdentity)
        )
        let store = try WorkspaceRootReusableInventoryManifestStore()
        let resourcePolicy = WorkspaceRootReusableInventoryResourcePolicy.default
        let writer = try store.makeWriter(header: header, resourcePolicy: resourcePolicy)
        let builder = WorkspaceRootReusableInventoryProjectionBuilder(
            writer: writer,
            prefix: authority.repositoryRelativeRootPrefix,
            objectFormat: authority.objectFormat,
            catalogPolicyIdentity: catalogPolicyIdentity,
            resourcePolicy: resourcePolicy,
            catalogBatchEvidenceProvider: catalogBatchEvidenceProvider,
            currentnessValidator: currentnessValidator
        )
        do {
            var parser = GitLoadedRootTreeInventoryStreamingParser(
                objectFormat: authority.objectFormat,
                rootPrefix: authority.repositoryRelativeRootPrefix
            ) { record in
                try await builder.consume(record)
            }
            let reader = try spool.rawOutput.makeReader()
            while let chunk = try reader.nextChunk() {
                try await parser.consume(chunk)
            }
            try await parser.finish()
            return try await builder.finish()
        } catch {
            await builder.cancel()
            throw error
        }
    }

    private nonisolated static func canonicalPathSet(_ paths: [URL]) -> Set<String> {
        Set(paths.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
    }

    private nonisolated static func observationCause(
        for error: GitTargetEvidenceCollectionError
    ) -> ObservationFailureCause {
        switch error {
        case .activityTimeout:
            .boundedGitFailure(.timeout)
        case .malformedGitOutput:
            .boundedGitFailure(.malformedOutput)
        case let .gitInitialization(error):
            .boundedGitFailure(error.reason)
        case .gitFailure, .gitSignal, .processLaunch:
            .boundedGitFailure(.gitError)
        case .admission, .processCapture, .resourceAdmission:
            .authorityEvidenceResourceUnavailable
        case let .spool(spool):
            switch spool {
            case .resourceAdmission: .authorityEvidenceResourceUnavailable
            case .io: .authorityEvidenceIOFailure
            case .invalidConfiguration, .closed, .corrupt: .authorityEvidenceCorrupt
            }
        case .io:
            .authorityEvidenceIOFailure
        case .artifact, .authorityChanged:
            .authorityEvidenceCorrupt
        }
    }

    private nonisolated static func observationCause(
        for error: GitPrefixControlEvidenceCacheError
    ) -> ObservationFailureCause {
        switch error {
        case .invalidatedDuringCollection, .rootIdentityChanged:
            .staleCurrentness
        case .corruptFooter:
            .authorityEvidenceCorrupt
        case .resourceAdmission:
            .authorityEvidenceResourceUnavailable
        }
    }

    private nonisolated static func isAuthorityEvidenceIOError(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == NSPOSIXErrorDomain || value.domain == NSCocoaErrorDomain
    }

    private nonisolated static func currentnessFailure(
        stage: ObservationFailureStage,
        validator: CurrentnessValidator
    ) async -> ObservationResult? {
        guard !Task.isCancelled else {
            return .failed(.init(stage: stage, cause: .cancelled))
        }
        let validation = await validator()
        guard !Task.isCancelled else {
            return .failed(.init(stage: stage, cause: .cancelled))
        }
        switch validation {
        case .current:
            return nil
        case let .stale(cause):
            return .failed(.init(stage: stage, cause: cause))
        }
    }

    private nonisolated static func gitLayoutContaining(_ rootURL: URL) -> GitRepositoryLayout? {
        var candidate = rootURL.standardizedFileURL
        while true {
            if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: candidate) {
                return layout
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    private nonisolated static func rootPrefix(
        rootURL: URL,
        layout: GitRepositoryLayout
    ) throws -> GitRepositoryRelativeRootPrefix {
        let rootPath = rootURL.standardizedFileURL.path
        let worktreePath = layout.workTreeRoot.standardizedFileURL.path
        let rootBytes = Array(rootPath.utf8)
        let worktreeBytes = Array(worktreePath.utf8)
        if rootBytes == worktreeBytes {
            return try GitRepositoryRelativeRootPrefix("")
        }
        let requiredPrefix = worktreeBytes + [UInt8(ascii: "/")]
        guard rootBytes.starts(with: requiredPrefix), rootBytes.count > requiredPrefix.count else {
            throw GitWorktreeInitializationError.invalidRootPrefix
        }
        return try GitRepositoryRelativeRootPrefix(
            String(decoding: rootBytes.dropFirst(requiredPrefix.count), as: UTF8.self)
        )
    }
}

private enum WorkspaceRootReusableInventoryProjectionError: Error {
    case catalogMismatch
    case stale(WorkspaceRootReusableSnapshotCoordinator.ObservationFailureCause)
}

private actor WorkspaceRootReusableInventoryProjectionBuilder {
    private struct PendingRecord {
        let source: GitLoadedRootTreeInventoryRecord
        let rootRelativePathBytes: Data
    }

    private let writer: WorkspaceRootReusableInventoryManifestWriter
    private let prefix: GitRepositoryRelativeRootPrefix
    private let objectFormat: GitObjectFormat
    private let catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity
    private let resourcePolicy: WorkspaceRootReusableInventoryResourcePolicy
    private let catalogBatchEvidenceProvider: WorkspaceRootReusableSnapshotCoordinator.CatalogBatchEvidenceProvider
    private let currentnessValidator: WorkspaceRootReusableSnapshotCoordinator.CurrentnessValidator
    private var pending: [PendingRecord] = []
    private var pendingBytes = 0
    private var ignoreRulesRevision: UInt64?
    private var closed = false

    init(
        writer: WorkspaceRootReusableInventoryManifestWriter,
        prefix: GitRepositoryRelativeRootPrefix,
        objectFormat: GitObjectFormat,
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity,
        resourcePolicy: WorkspaceRootReusableInventoryResourcePolicy,
        catalogBatchEvidenceProvider: @escaping WorkspaceRootReusableSnapshotCoordinator.CatalogBatchEvidenceProvider,
        currentnessValidator: @escaping WorkspaceRootReusableSnapshotCoordinator.CurrentnessValidator
    ) {
        self.writer = writer
        self.prefix = prefix
        self.objectFormat = objectFormat
        self.catalogPolicyIdentity = catalogPolicyIdentity
        self.resourcePolicy = resourcePolicy
        self.catalogBatchEvidenceProvider = catalogBatchEvidenceProvider
        self.currentnessValidator = currentnessValidator
        pending.reserveCapacity(min(resourcePolicy.maximumRecordsPerBatch, 1024))
    }

    func consume(_ record: GitLoadedRootTreeInventoryRecord) async throws {
        guard !closed else { throw WorkspaceRootReusableInventoryManifestError.closed }
        guard let rootRelative = rootRelativePath(record.repositoryRelativePathBytes) else {
            if record.repositoryRelativePathBytes == Data(prefix.value.utf8), record.kind == .tree {
                return
            }
            throw WorkspaceRootReusableInventoryProjectionError.catalogMismatch
        }
        let estimated = rootRelative.count + record.modeBytes.count + record.objectIDBytes.count + 64
        guard estimated <= resourcePolicy.maximumRecordByteCount else {
            throw WorkspaceRootReusableInventoryManifestError.resourceAdmission
        }
        if !pending.isEmpty,
           pending.count >= resourcePolicy.maximumRecordsPerBatch
           || pendingBytes + estimated > resourcePolicy.maximumBufferedRecordBytes
        {
            try await flush()
        }
        pending.append(PendingRecord(source: record, rootRelativePathBytes: rootRelative))
        pendingBytes += estimated
        if pending.count >= resourcePolicy.maximumRecordsPerBatch
            || pendingBytes >= resourcePolicy.maximumBufferedRecordBytes
        {
            try await flush()
        }
    }

    func finish() async throws -> WorkspaceRootReusableInventoryManifestLease {
        guard !closed else { throw WorkspaceRootReusableInventoryManifestError.closed }
        do {
            try await flush()
            try await requireCurrent()
            let lease = try await writer.finish()
            try await requireCurrent()
            closed = true
            return lease
        } catch {
            closed = true
            await writer.cancel()
            throw error
        }
    }

    func cancel() async {
        guard !closed else { return }
        closed = true
        pending.removeAll(keepingCapacity: false)
        await writer.cancel()
    }

    private func flush() async throws {
        guard !pending.isEmpty else { return }
        try await requireCurrent()
        let regular = pending.filter { value in
            value.source.kind == .blob
                && (
                    value.source.modeBytes == Data("100644".utf8)
                        || value.source.modeBytes == Data("100755".utf8)
                )
        }
        var dispositions: [WorkspaceRootByteExactPathKey: WorkspaceRootCommittedRegularProjectionDisposition] = [:]
        if !regular.isEmpty {
            let paths = try regular.map { value -> String in
                guard let path = String(data: value.rootRelativePathBytes, encoding: .utf8) else {
                    throw WorkspaceRootReusableInventoryManifestError.invalidRecord("path is not UTF-8")
                }
                return path
            }
            switch await catalogBatchEvidenceProvider(paths) {
            case let .evidence(evidence):
                try await requireCurrent()
                guard evidence.policyIdentity == catalogPolicyIdentity,
                      let exact = WorkspaceRootByteExactPathSet(paths, rejectExactDuplicates: true),
                      Set(evidence.dispositionsByRelativePath.keys) == exact.keys
                else { throw WorkspaceRootReusableInventoryProjectionError.catalogMismatch }
                if let ignoreRulesRevision, ignoreRulesRevision != evidence.ignoreRulesRevision {
                    throw WorkspaceRootReusableInventoryProjectionError.stale(.loadedRootCatalogStale)
                }
                ignoreRulesRevision = evidence.ignoreRulesRevision
                dispositions = evidence.dispositionsByRelativePath
            case .catalogMismatch:
                throw WorkspaceRootReusableInventoryProjectionError.catalogMismatch
            case let .stale(cause):
                throw WorkspaceRootReusableInventoryProjectionError.stale(cause)
            }
        }
        var projected: [WorkspaceRootReusableInventoryManifestRecord] = []
        projected.reserveCapacity(pending.count)
        for value in pending {
            guard let mode = String(data: value.source.modeBytes, encoding: .utf8),
                  let objectIDValue = String(data: value.source.objectIDBytes, encoding: .utf8)
            else { throw WorkspaceRootReusableInventoryManifestError.invalidRecord("metadata is not UTF-8") }
            let regular = value.source.kind == .blob && (mode == "100644" || mode == "100755")
            let projection: RootNeutralTreeInventoryEntry.CatalogProjection
            if regular {
                guard let path = String(data: value.rootRelativePathBytes, encoding: .utf8),
                      let disposition = dispositions[WorkspaceRootByteExactPathKey(path)]
                else { throw WorkspaceRootReusableInventoryProjectionError.catalogMismatch }
                switch disposition {
                case .searchableRegularFile:
                    projection = .searchableRegularFile
                case .policyIgnoredRegularFile:
                    projection = .policyIgnoredRegularFile
                case .ineligible:
                    throw WorkspaceRootReusableInventoryProjectionError.catalogMismatch
                }
            } else {
                projection = .nonRegularTopology
            }
            try projected.append(WorkspaceRootReusableInventoryManifestRecord(
                rootRelativePathBytes: value.rootRelativePathBytes,
                mode: mode,
                kind: value.source.kind,
                objectID: GitObjectID(
                    objectFormat: objectFormat,
                    lowercaseHex: objectIDValue
                ),
                catalogProjection: projection
            ))
        }
        try await requireCurrent()
        try await writer.append(contentsOf: projected)
        try await requireCurrent()
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
    }

    private func requireCurrent() async throws {
        try Task.checkCancellation()
        switch await currentnessValidator() {
        case .current:
            try Task.checkCancellation()
        case let .stale(cause):
            throw WorkspaceRootReusableInventoryProjectionError.stale(cause)
        }
    }

    private func rootRelativePath(_ repositoryRelative: Data) -> Data? {
        let prefixBytes = Data(prefix.value.utf8)
        guard !prefixBytes.isEmpty else { return repositoryRelative }
        var required = prefixBytes
        required.append(UInt8(ascii: "/"))
        guard repositoryRelative.starts(with: required), repositoryRelative.count > required.count else {
            return nil
        }
        return Data(repositoryRelative.dropFirst(required.count))
    }
}
