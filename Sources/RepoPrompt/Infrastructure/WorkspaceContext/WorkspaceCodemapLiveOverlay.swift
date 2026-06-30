import Foundation

actor WorkspaceCodemapLiveOverlay {
    private struct Registration: Equatable {
        let capability: GitCodemapRootCapability
        let catalogGeneration: UInt64
    }

    private struct PipelineManifestState {
        let namespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority
        var manifest: CodeMapRootManifestSnapshot?
        var invalidationGeneration: UInt64
        var adoptedInvalidationGeneration: UInt64?
        var adoptionOperationID: UUID?
        var cleanRelativePaths: Set<String>
    }

    private struct StoredReady {
        let binding: WorkspaceCodemapArtifactBinding
        let leaseOwner: WorkspaceCodemapSharedArtifactLease
        let source: WorkspaceCodemapLiveOverlaySource
        let completionTicket: WorkspaceCodemapLiveDemandTicket?
        var accessOrdinal: UInt64

        var completion: WorkspaceCodemapArtifactCompletion {
            guard case let .resolved(completion) = binding.availability else {
                preconditionFailure("Stored ready bindings must remain resolved.")
            }
            return completion
        }
    }

    private struct Pending {
        var binding: WorkspaceCodemapArtifactBinding
        let ticket: WorkspaceCodemapLiveDemandTicket
        var owners: Set<WorkspaceCodemapLiveDemandOwner>
    }

    private enum LiveEntry {
        case pending(Pending)
        case ready(StoredReady)
        case unavailable(
            ticket: WorkspaceCodemapLiveDemandTicket,
            reason: WorkspaceCodemapLiveOverlayUnavailableReason,
            accessOrdinal: UInt64
        )

        var identity: WorkspaceCodemapArtifactBindingIdentity {
            switch self {
            case let .pending(pending): pending.binding.identity
            case let .ready(ready): ready.binding.identity
            case let .unavailable(ticket, _, _): ticket.token.identity
            }
        }

        var requestGeneration: UInt64 {
            switch self {
            case let .pending(pending): pending.ticket.token.requestGeneration
            case let .ready(ready): ready.completion.token.requestGeneration
            case let .unavailable(ticket, _, _): ticket.token.requestGeneration
            }
        }

        var pipelineIdentity: CodeMapPipelineIdentity {
            switch self {
            case let .pending(pending): pending.ticket.token.pipelineIdentity
            case let .ready(ready): ready.completion.token.pipelineIdentity
            case let .unavailable(ticket, _, _): ticket.token.pipelineIdentity
            }
        }
    }

    private struct ShadowKey: Hashable {
        let pipelineIdentity: CodeMapPipelineIdentity
        let relativePath: String
    }

    private struct Shadow {
        let reason: WorkspaceCodemapLiveOverlayInvalidationReason
        var accessOrdinal: UInt64
    }

    private struct RootState {
        var registration: Registration
        var authorityIsCurrent: Bool
        var pipelines: [CodeMapPipelineIdentity: PipelineManifestState]
        var cleanByRelativePath: [String: StoredReady]
        var cleanPipelineByRelativePath: [String: CodeMapPipelineIdentity]
        var liveByFileID: [UUID: LiveEntry]
        var liveFileIDByRelativePath: [String: UUID]
        var shadows: [ShadowKey: Shadow]
        var contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    }

    private enum AccessLocation {
        case clean(rootEpoch: WorkspaceCodemapRootEpoch, path: String)
        case live(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID)
        case unavailable(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID)
        case shadow(rootEpoch: WorkspaceCodemapRootEpoch, key: ShadowKey)
    }

    private struct AccessItem {
        let location: AccessLocation
        let ordinal: UInt64
        let rootEpoch: WorkspaceCodemapRootEpoch
        let path: String
        let fileID: UUID?
    }

    private struct DemandPreflight {
        let ticket: WorkspaceCodemapLiveDemandPreflightTicket
        let identity: WorkspaceCodemapArtifactBindingIdentity
        let pipelineIdentity: CodeMapPipelineIdentity
        let requestGeneration: UInt64
        let catalogGeneration: UInt64
    }

    private let policy: WorkspaceCodemapLiveOverlayPolicy
    private let manifestRecordEqualityTraversal: @Sendable () -> Void
    private let manifestAdoptionCommitHook: @Sendable () async -> Void
    private let initialManifestInvalidationGeneration: UInt64
    private let initialContributionGeneration: UInt64
    private var roots: [WorkspaceCodemapRootEpoch: RootState] = [:]
    private var admissionReservations: [WorkspaceCodemapLiveDemandReservation] = []
    private var demandPreflights: [UUID: DemandPreflight] = [:]
    private var activeAdmissionReservationID: UUID?
    private var nextAccessOrdinal: UInt64
    private var evictionCount: UInt64
    private var busyDropCount: UInt64
    private var staleCompletionDropCount: UInt64

    init(
        policy: WorkspaceCodemapLiveOverlayPolicy = .default,
        initialAccessOrdinal: UInt64 = 1,
        initialCounterValue: UInt64 = 0,
        initialManifestInvalidationGeneration: UInt64 = 1,
        initialContributionGeneration: UInt64 = 1,
        manifestRecordEqualityTraversal: @escaping @Sendable () -> Void = {},
        manifestAdoptionCommitHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.policy = policy
        self.manifestRecordEqualityTraversal = manifestRecordEqualityTraversal
        self.manifestAdoptionCommitHook = manifestAdoptionCommitHook
        self.initialManifestInvalidationGeneration = initialManifestInvalidationGeneration
        self.initialContributionGeneration = initialContributionGeneration
        nextAccessOrdinal = initialAccessOrdinal
        evictionCount = initialCounterValue
        busyDropCount = initialCounterValue
        staleCompletionDropCount = initialCounterValue
    }

    func register(
        capability state: WorkspaceCodemapGitCapabilityState,
        catalogGeneration: UInt64
    ) -> WorkspaceCodemapLiveOverlayRegistrationDisposition {
        guard case let .eligible(capability) = state else {
            return .rejected(.capabilityUnavailable)
        }
        guard catalogGeneration > 0 else {
            return .rejected(.catalogGenerationInvalid)
        }
        let registration = Registration(
            capability: capability,
            catalogGeneration: catalogGeneration
        )
        if let current = roots[capability.rootEpoch] {
            if current.authorityIsCurrent, current.registration == registration {
                return .exactDuplicate
            }
            guard !current.authorityIsCurrent else {
                return .rejected(.rootEpochAlreadyBound)
            }
        } else if roots.count >= policy.maximumRootCount {
            recordBusyDrop()
            return .busy(.rootLimit)
        }

        roots[capability.rootEpoch] = RootState(
            registration: registration,
            authorityIsCurrent: true,
            pipelines: [:],
            cleanByRelativePath: [:],
            cleanPipelineByRelativePath: [:],
            liveByFileID: [:],
            liveFileIDByRelativePath: [:],
            shadows: [:],
            contributionGeneration: .init(rawValue: initialContributionGeneration)
        )
        return .registered
    }

    @discardableResult
    func unregister(rootEpoch: WorkspaceCodemapRootEpoch) -> Bool {
        let removed = roots.removeValue(forKey: rootEpoch) != nil
        if removed { removeAdmissionReservations(rootEpoch: rootEpoch) }
        return removed
    }

    func beginManifestAdoption(
        rootEpoch: WorkspaceCodemapRootEpoch,
        namespace: CodeMapRootManifestNamespace
    ) -> WorkspaceCodemapLiveManifestAdoptionTicket? {
        guard var root = roots[rootEpoch], root.authorityIsCurrent, namespace.isCurrent else { return nil }
        let expectedNamespace = try? CodeMapRootManifestNamespace(
            capability: root.registration.capability,
            pipelineIdentity: namespace.pipelineIdentity
        )
        guard expectedNamespace == namespace else { return nil }
        if let current = root.pipelines[namespace.pipelineIdentity] {
            guard current.namespace == namespace else { return nil }
        } else {
            guard let authority = try? CodeMapRootManifestAuthority(
                namespace: namespace,
                token: root.registration.capability.repositoryAuthority
            ) else { return nil }
            root.pipelines[namespace.pipelineIdentity] = PipelineManifestState(
                namespace: namespace,
                authority: authority,
                manifest: nil,
                invalidationGeneration: initialManifestInvalidationGeneration,
                adoptedInvalidationGeneration: nil,
                adoptionOperationID: nil,
                cleanRelativePaths: []
            )
            roots[rootEpoch] = root
        }
        guard let pipeline = root.pipelines[namespace.pipelineIdentity] else { return nil }
        return WorkspaceCodemapLiveManifestAdoptionTicket(
            operationID: UUID(),
            rootEpoch: rootEpoch,
            pipelineIdentity: namespace.pipelineIdentity,
            catalogGeneration: root.registration.catalogGeneration,
            repositoryAuthority: root.registration.capability.repositoryAuthority,
            invalidationGeneration: pipeline.invalidationGeneration
        )
    }

    func isManifestAdoptionTicketCurrent(
        _ ticket: WorkspaceCodemapLiveManifestAdoptionTicket
    ) -> Bool {
        guard let root = roots[ticket.rootEpoch], root.authorityIsCurrent,
              let pipeline = root.pipelines[ticket.pipelineIdentity]
        else { return false }
        return ticket.catalogGeneration == root.registration.catalogGeneration &&
            ticket.repositoryAuthority == root.registration.capability.repositoryAuthority &&
            ticket.invalidationGeneration == pipeline.invalidationGeneration
    }

    func adoptManifest(
        ticket: WorkspaceCodemapLiveManifestAdoptionTicket,
        snapshot: CodeMapRootManifestSnapshot,
        readyEntries: [WorkspaceCodemapLiveManifestAdoptionEntry]
    ) async -> WorkspaceCodemapLiveManifestAdoptionDisposition {
        let rootEpoch = ticket.rootEpoch
        guard var root = roots[rootEpoch] else {
            return .rejected(.rootNotRegistered)
        }
        guard root.authorityIsCurrent else {
            return .rejected(.rootAuthorityInvalid)
        }
        guard var pipeline = root.pipelines[ticket.pipelineIdentity] else {
            return .rejected(.namespaceMismatch)
        }
        guard ticket.catalogGeneration == root.registration.catalogGeneration,
              ticket.repositoryAuthority == root.registration.capability.repositoryAuthority,
              ticket.invalidationGeneration == pipeline.invalidationGeneration
        else {
            return .rejected(.staleLoad)
        }
        guard snapshot.namespace == pipeline.namespace else {
            return .rejected(.namespaceMismatch)
        }
        guard snapshot.authority == pipeline.authority else {
            return .rejected(.authorityMismatch)
        }
        if let currentManifest = pipeline.manifest {
            guard snapshot.manifestGeneration >= currentManifest.manifestGeneration else {
                return .rejected(.staleManifestGeneration)
            }
        }
        guard snapshot.records.count <= policy.maximumManifestRecordCount,
              snapshot.records.count <= CodeMapRootManifestCodec.maximumRecordCount,
              estimatedManifestByteCount(snapshot, limit: policy.maximumManifestEstimatedByteCount) != nil
        else {
            recordBusyDrop()
            return .busy(.manifestLimit)
        }

        let replacedPaths = pipeline.cleanRelativePaths
        let replacedEntryCount = replacedPaths.count
        let retiredShadowCount = root.shadows.keys.count(where: {
            $0.pipelineIdentity == ticket.pipelineIdentity
        })
        let usage = usage(excludingCleanEntriesFor: rootEpoch, pipelineIdentity: ticket.pipelineIdentity)
        guard let projectedRootEntryCount = addingChecked(
            readyEntries.count,
            addingSaturating(
                addingSaturating(
                    subtractingFloor(root.cleanByRelativePath.count, replacedEntryCount),
                    root.liveByFileID.count
                ),
                subtractingFloor(root.shadows.count, retiredShadowCount)
            )
        ), let projectedProcessEntryCount = addingChecked(
            subtractingFloor(
                usage.entryCount,
                root.shadows.keys.count(where: { $0.pipelineIdentity == ticket.pipelineIdentity })
            ),
            readyEntries.count
        ), projectedRootEntryCount <= policy.maximumEntryCountPerRoot,
        projectedProcessEntryCount <= policy.maximumEntryCount
        else {
            recordBusyDrop()
            return .busy(.entryLimit)
        }
        guard let projectedRootLeaseCount = addingChecked(
            readyEntries.count,
            subtractingFloor(rootLeaseCount(root), replacedEntryCount)
        ), let projectedProcessLeaseCount = addingChecked(usage.leaseCount, readyEntries.count),
        projectedRootLeaseCount <= policy.maximumLeaseCountPerRoot,
        projectedProcessLeaseCount <= policy.maximumLeaseCount
        else {
            recordBusyDrop()
            return .busy(.leaseLimit)
        }
        var byteCount: UInt64 = 0
        for entry in readyEntries {
            guard let nextByteCount = addingChecked(
                byteCount,
                entry.lease.handle.estimatedResidentByteCount
            ), let projectedRootBytes = addingChecked(
                subtractingFloor(rootArtifactBytes(root), cleanArtifactBytes(root, paths: replacedPaths)),
                nextByteCount
            ),
                let projectedProcessBytes = addingChecked(usage.artifactByteCount, nextByteCount),
                projectedRootBytes <= policy.maximumArtifactByteCountPerRoot,
                projectedProcessBytes <= policy.maximumArtifactByteCount
            else {
                recordBusyDrop()
                return .busy(.artifactByteLimit)
            }
            byteCount = nextByteCount
        }

        if let currentManifest = pipeline.manifest,
           snapshot.manifestGeneration == currentManifest.manifestGeneration
        {
            guard manifestContentsEqual(snapshot, currentManifest) else {
                return .rejected(.manifestGenerationConflict)
            }
            if pipeline.adoptedInvalidationGeneration == pipeline.invalidationGeneration {
                return .exactDuplicate(readyEntryCount: pipeline.cleanRelativePaths.count)
            }
        }

        let records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.repositoryRelativePath, $0) })
        var validatedEntries: [(String, WorkspaceCodemapLiveManifestAdoptionEntry)] = []
        var fileIDs = Set<UUID>()
        var relativePaths = Set<String>()
        for entry in readyEntries {
            guard records[entry.record.repositoryRelativePath] == entry.record else {
                return .rejected(.recordMissing)
            }
            guard entry.record.outcome == .ready || entry.record.outcome == .readyNoSymbols else {
                return .rejected(.bindingMismatch)
            }
            guard let relativePath = loadedRootRelativePath(
                repositoryRelativePath: entry.record.repositoryRelativePath,
                prefix: root.registration.capability.repositoryRelativeLoadedRootPrefix
            ) else {
                return .rejected(.bindingMismatch)
            }
            guard fileIDs.insert(entry.binding.identity.fileID).inserted,
                  relativePaths.insert(relativePath).inserted
            else {
                return .rejected(.duplicateEntry)
            }
            guard let completion = resolvedCompletion(entry.binding),
                  completion.token.identity.standardizedRelativePath == relativePath,
                  completion.token.identity.rootID == rootEpoch.rootID,
                  completion.token.identity.rootLifetimeID == rootEpoch.rootLifetimeID,
                  completion.token.catalogGeneration == root.registration.catalogGeneration,
                  completion.sourceProof.sourceAuthority.rootEpoch == rootEpoch,
                  completion.sourceProof.sourceAuthority.repositoryAuthority ==
                  root.registration.capability.repositoryAuthority,
                  completion.sourceProof.sourceAuthority.standardizedRepositoryRelativePath ==
                  entry.record.repositoryRelativePath,
                  completion.verifiedCleanAssociation?.identity == entry.record.locatorIdentity,
                  completion.artifactKey == entry.record.artifactKey,
                  manifestOutcome(completion.outcome) == entry.record.outcome
            else {
                return .rejected(.bindingMismatch)
            }
            guard artifactMatches(entry.lease.handle, completion: completion) else {
                return .rejected(.artifactHandleMismatch)
            }
            let contribution = graphContribution(completion)
            guard contribution.map(CodeMapRootManifestContributionIdentity.init) == entry.record.contribution else {
                return .rejected(.contributionMismatch)
            }
            validatedEntries.append((relativePath, entry))
        }

        ensureAccessOrdinalCapacity(requiredCount: validatedEntries.count)
        for path in pipeline.cleanRelativePaths {
            root.cleanByRelativePath.removeValue(forKey: path)
            root.cleanPipelineByRelativePath.removeValue(forKey: path)
        }
        pipeline.manifest = snapshot
        pipeline.adoptedInvalidationGeneration = pipeline.invalidationGeneration
        pipeline.adoptionOperationID = ticket.operationID
        pipeline.cleanRelativePaths = Set(validatedEntries.map(\.0))
        for (relativePath, entry) in validatedEntries {
            guard root.cleanByRelativePath[relativePath] == nil else {
                return .rejected(.duplicateEntry)
            }
            root.cleanByRelativePath[relativePath] = StoredReady(
                binding: entry.binding,
                leaseOwner: WorkspaceCodemapSharedArtifactLease(entry.lease),
                source: .cleanManifest,
                completionTicket: nil,
                accessOrdinal: takeAccessOrdinal()
            )
            root.cleanPipelineByRelativePath[relativePath] = ticket.pipelineIdentity
        }
        root.pipelines[ticket.pipelineIdentity] = pipeline
        root.shadows = root.shadows.filter { $0.key.pipelineIdentity != ticket.pipelineIdentity }
        advanceContributionGeneration(&root, rootEpoch: rootEpoch)
        roots[rootEpoch] = root
        await manifestAdoptionCommitHook()
        return .adopted(readyEntryCount: validatedEntries.count)
    }

    @discardableResult
    func rollbackManifestAdoption(
        ticket: WorkspaceCodemapLiveManifestAdoptionTicket,
        manifestGeneration: UInt64
    ) -> Bool {
        guard var root = roots[ticket.rootEpoch],
              root.authorityIsCurrent,
              var pipeline = root.pipelines[ticket.pipelineIdentity],
              ticket.catalogGeneration == root.registration.catalogGeneration,
              ticket.repositoryAuthority == root.registration.capability.repositoryAuthority,
              ticket.invalidationGeneration == pipeline.invalidationGeneration,
              pipeline.adoptedInvalidationGeneration == ticket.invalidationGeneration,
              pipeline.adoptionOperationID == ticket.operationID,
              pipeline.manifest?.manifestGeneration == manifestGeneration
        else { return false }
        for path in pipeline.cleanRelativePaths {
            root.cleanByRelativePath.removeValue(forKey: path)
            root.cleanPipelineByRelativePath.removeValue(forKey: path)
        }
        pipeline.manifest = nil
        pipeline.adoptedInvalidationGeneration = nil
        pipeline.adoptionOperationID = nil
        pipeline.cleanRelativePaths.removeAll()
        guard advanceManifestInvalidationGeneration(
            &pipeline,
            root: &root,
            rootEpoch: ticket.rootEpoch
        ) else { return false }
        root.pipelines[ticket.pipelineIdentity] = pipeline
        if root.authorityIsCurrent {
            advanceContributionGeneration(&root, rootEpoch: ticket.rootEpoch)
        }
        roots[ticket.rootEpoch] = root
        return true
    }

    func preflightDemand(
        owner: WorkspaceCodemapLiveDemandOwner,
        identity: WorkspaceCodemapArtifactBindingIdentity,
        pipelineIdentity: CodeMapPipelineIdentity,
        requestGeneration: UInt64,
        catalogGeneration: UInt64
    ) -> WorkspaceCodemapLiveDemandPreflightDisposition {
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: identity.rootID,
            rootLifetimeID: identity.rootLifetimeID
        )
        guard let root = roots[rootEpoch] else {
            return .rejected(.rootNotRegistered)
        }
        guard root.authorityIsCurrent else {
            return .rejected(.rootAuthorityInvalid)
        }
        guard catalogGeneration == root.registration.catalogGeneration else {
            return .rejected(.catalogGenerationMismatch)
        }
        guard requestGeneration > 0,
              validatedRelativePath(identity.standardizedRelativePath) != nil
        else {
            return .rejected(.invalidToken)
        }
        if let existing = root.cleanByRelativePath[identity.standardizedRelativePath],
           existing.binding.identity == identity,
           existing.completion.token.pipelineIdentity == pipelineIdentity,
           existing.completion.token.requestGeneration == requestGeneration
        {
            return .ready(readySnapshot(rootEpoch: rootEpoch, ready: existing))
        }
        if let existing = root.liveByFileID[identity.fileID],
           existing.identity == identity,
           existing.pipelineIdentity == pipelineIdentity,
           existing.requestGeneration == requestGeneration,
           case let .ready(ready) = existing
        {
            return .ready(readySnapshot(rootEpoch: rootEpoch, ready: ready))
        }
        let rootPreflightCount = demandPreflights.values.count(where: {
            $0.ticket.rootEpoch == rootEpoch
        })
        let currentUsage = usage()
        guard admissionReservations.count + demandPreflights.count <
            policy.maximumAdmissionReservationCount,
            admissionReservationCount(rootEpoch: rootEpoch) <
            policy.maximumAdmissionReservationCountPerRoot,
            addingSaturating(currentUsage.entryCount, demandPreflights.count + 1) <=
            policy.maximumEntryCount,
            addingSaturating(entryCount(root), rootPreflightCount + 1) <=
            policy.maximumEntryCountPerRoot,
            addingSaturating(currentUsage.waiterCount, demandPreflights.count + 1) <=
            policy.maximumWaiterCount,
            addingSaturating(rootWaiterCount(root), rootPreflightCount + 1) <=
            policy.maximumWaiterCountPerRoot
        else {
            recordBusyDrop()
            return .busy(.admissionQueueLimit)
        }
        let ticket = WorkspaceCodemapLiveDemandPreflightTicket(
            rootEpoch: rootEpoch,
            owner: owner,
            reservationID: UUID()
        )
        demandPreflights[ticket.reservationID] = DemandPreflight(
            ticket: ticket,
            identity: identity,
            pipelineIdentity: pipelineIdentity,
            requestGeneration: requestGeneration,
            catalogGeneration: catalogGeneration
        )
        return .reserved(ticket)
    }

    @discardableResult
    func cancelDemandPreflight(_ ticket: WorkspaceCodemapLiveDemandPreflightTicket) -> Bool {
        guard let current = demandPreflights[ticket.reservationID], current.ticket == ticket else {
            return false
        }
        demandPreflights.removeValue(forKey: ticket.reservationID)
        return true
    }

    func beginDemand(
        owner: WorkspaceCodemapLiveDemandOwner,
        token: WorkspaceCodemapArtifactRequestToken,
        preflight: WorkspaceCodemapLiveDemandPreflightTicket? = nil
    ) -> WorkspaceCodemapLiveDemandDisposition {
        if let preflight {
            guard let reservation = demandPreflights.removeValue(forKey: preflight.reservationID),
                  reservation.ticket == preflight,
                  reservation.ticket.owner == owner,
                  reservation.identity == token.identity,
                  reservation.pipelineIdentity == token.pipelineIdentity,
                  reservation.requestGeneration == token.requestGeneration,
                  reservation.catalogGeneration == token.catalogGeneration
            else {
                return .rejected(.admissionReservationInvalid)
            }
        }
        ensureAccessOrdinalCapacity(requiredCount: 1)
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: token.identity.rootID,
            rootLifetimeID: token.identity.rootLifetimeID
        )
        guard var root = roots[rootEpoch] else {
            return .rejected(.rootNotRegistered)
        }
        guard root.authorityIsCurrent else {
            return .rejected(.rootAuthorityInvalid)
        }
        guard token.isFactoryValidated else {
            return .rejected(.invalidToken)
        }
        guard token.catalogGeneration == root.registration.catalogGeneration else {
            return .rejected(.catalogGenerationMismatch)
        }
        guard token.sourceExpectation.sourceAuthority.repositoryAuthority ==
            root.registration.capability.repositoryAuthority
        else {
            return .rejected(.repositoryAuthorityMismatch)
        }
        guard token.sourceExpectation.sourceAuthority.rootEpoch == rootEpoch else {
            return .rejected(.rootEpochMismatch)
        }
        guard repositoryRelativePath(
            loadedRootRelativePath: token.identity.standardizedRelativePath,
            prefix: root.registration.capability.repositoryRelativeLoadedRootPrefix
        ) == token.sourceExpectation.sourceAuthority.standardizedRepositoryRelativePath
        else {
            return .rejected(.pathOutsideRoot)
        }

        if let existing = root.liveByFileID[token.identity.fileID] {
            if case var .pending(pending) = existing,
               pending.ticket.token == token
            {
                if pending.owners.contains(owner) {
                    return .joined(pending.ticket)
                }
                if !admissionReservations.isEmpty,
                   !hasActiveAdmissionPriority(owner: owner, token: token)
                {
                    return queueDemand(owner: owner, token: token, rootEpoch: rootEpoch)
                }
                let currentUsage = usage()
                guard pending.owners.count < policy.maximumWaiterCountPerEntry,
                      rootWaiterCount(root) < policy.maximumWaiterCountPerRoot,
                      currentUsage.waiterCount < policy.maximumWaiterCount
                else {
                    return queueDemand(owner: owner, token: token, rootEpoch: rootEpoch)
                }
                pending.owners.insert(owner)
                root.liveByFileID[token.identity.fileID] = .pending(pending)
                roots[rootEpoch] = root
                return .joined(pending.ticket)
            }
            if case var .ready(ready) = existing,
               ready.completion.token == token
            {
                ready.accessOrdinal = takeAccessOrdinal()
                root.liveByFileID[token.identity.fileID] = .ready(ready)
                roots[rootEpoch] = root
                return .ready(readySnapshot(rootEpoch: rootEpoch, ready: ready))
            }
            guard token.requestGeneration >= existing.requestGeneration else {
                return .rejected(.staleRequestGeneration)
            }
            guard token.requestGeneration != existing.requestGeneration else {
                return .rejected(.requestGenerationConflict)
            }
        }
        guard let binding = WorkspaceCodemapArtifactBinding(pending: token) else {
            return .rejected(.invalidToken)
        }
        if !admissionReservations.isEmpty,
           !hasActiveAdmissionPriority(owner: owner, token: token)
        {
            return queueDemand(owner: owner, token: token, rootEpoch: rootEpoch)
        }

        let relativePath = token.identity.standardizedRelativePath
        var removalFileIDs: Set<UUID> = []
        if root.liveByFileID[token.identity.fileID] != nil {
            removalFileIDs.insert(token.identity.fileID)
        }
        if let displacedFileID = root.liveFileIDByRelativePath[relativePath],
           displacedFileID != token.identity.fileID
        {
            removalFileIDs.insert(displacedFileID)
        }
        let removedWaiters = removalFileIDs.reduce(0) { partial, fileID in
            guard case let .pending(pending)? = root.liveByFileID[fileID] else { return partial }
            return partial + pending.owners.count
        }
        let shadowKey = ShadowKey(
            pipelineIdentity: token.pipelineIdentity,
            relativePath: relativePath
        )
        let removesShadow = root.shadows[shadowKey] != nil
        let rootPreflightCount = demandPreflights.values.count(where: {
            $0.ticket.rootEpoch == rootEpoch
        })
        let rootProjectedWaiters = addingSaturating(
            addingSaturating(
                subtractingFloor(rootWaiterCount(root), removedWaiters),
                rootPreflightCount
            ),
            1
        )
        let processProjectedWaiters = addingSaturating(
            addingSaturating(
                subtractingFloor(usage().waiterCount, removedWaiters),
                demandPreflights.count
            ),
            1
        )
        guard rootProjectedWaiters <= policy.maximumWaiterCountPerRoot,
              processProjectedWaiters <= policy.maximumWaiterCount
        else {
            return queueDemand(owner: owner, token: token, rootEpoch: rootEpoch)
        }

        func projectedEntryCounts(_ currentRoot: RootState) -> (root: Int, process: Int) {
            let removedEntries = removalFileIDs.reduce(0) {
                addingSaturating($0, currentRoot.liveByFileID[$1] == nil ? 0 : 1)
            }
            let shadowEntries = removesShadow && currentRoot.shadows[shadowKey] != nil ? 1 : 0
            return (
                addingSaturating(
                    addingSaturating(
                        subtractingFloor(
                            subtractingFloor(entryCount(currentRoot), removedEntries),
                            shadowEntries
                        ),
                        rootPreflightCount
                    ),
                    1
                ),
                addingSaturating(
                    addingSaturating(
                        subtractingFloor(
                            subtractingFloor(usage().entryCount, removedEntries),
                            shadowEntries
                        ),
                        demandPreflights.count
                    ),
                    1
                )
            )
        }

        while projectedEntryCounts(root).root > policy.maximumEntryCountPerRoot {
            guard evictEntryForCapacity(
                requiredRootEpoch: rootEpoch,
                excludingFileIDs: removalFileIDs.union([token.identity.fileID])
            ) else {
                return queueDemand(owner: owner, token: token, rootEpoch: rootEpoch)
            }
            root = roots[rootEpoch] ?? root
        }
        while projectedEntryCounts(root).process > policy.maximumEntryCount {
            guard evictEntryForCapacity(
                requiredRootEpoch: nil,
                excludingFileIDs: removalFileIDs.union([token.identity.fileID])
            ) else {
                return queueDemand(owner: owner, token: token, rootEpoch: rootEpoch)
            }
            root = roots[rootEpoch] ?? root
        }

        for fileID in removalFileIDs {
            removeLiveEntry(fileID: fileID, from: &root)
        }
        root.shadows.removeValue(forKey: shadowKey)
        advanceContributionGeneration(&root, rootEpoch: rootEpoch)
        let ticket = WorkspaceCodemapLiveDemandTicket(
            token: token,
            contributionGeneration: root.contributionGeneration,
            requestID: UUID()
        )
        root.liveByFileID[token.identity.fileID] = .pending(Pending(
            binding: binding,
            ticket: ticket,
            owners: [owner]
        ))
        root.liveFileIDByRelativePath[relativePath] = token.identity.fileID
        roots[rootEpoch] = root
        return .started(ticket)
    }

    func resumeDemand(
        owner: WorkspaceCodemapLiveDemandOwner,
        reservation: WorkspaceCodemapLiveDemandReservation
    ) -> WorkspaceCodemapLiveDemandDisposition {
        guard let index = admissionReservations.firstIndex(where: {
            $0.reservationID == reservation.reservationID &&
                $0.owner == owner && $0 == reservation
        }) else {
            return .rejected(.admissionReservationInvalid)
        }
        guard index == admissionReservations.startIndex else {
            return .queued(admissionReservations[index])
        }

        activeAdmissionReservationID = reservation.reservationID
        let disposition = beginDemand(owner: owner, token: reservation.token)
        activeAdmissionReservationID = nil
        switch disposition {
        case .queued, .busy:
            break
        case .started, .joined, .ready, .rejected:
            admissionReservations.removeAll { $0.reservationID == reservation.reservationID }
        }
        return disposition
    }

    @discardableResult
    func cancelDemandReservation(
        owner: WorkspaceCodemapLiveDemandOwner,
        reservation: WorkspaceCodemapLiveDemandReservation
    ) -> Bool {
        guard let index = admissionReservations.firstIndex(where: {
            $0.reservationID == reservation.reservationID &&
                $0.owner == owner && $0 == reservation
        }) else { return false }
        admissionReservations.remove(at: index)
        return true
    }

    @discardableResult
    func cancelDemand(
        owner: WorkspaceCodemapLiveDemandOwner,
        ticket: WorkspaceCodemapLiveDemandTicket
    ) -> Bool {
        ensureAccessOrdinalCapacity(requiredCount: 1)
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: ticket.token.identity.rootID,
            rootLifetimeID: ticket.token.identity.rootLifetimeID
        )
        guard var root = roots[rootEpoch],
              case var .pending(pending) = root.liveByFileID[ticket.token.identity.fileID],
              pending.ticket == ticket,
              pending.owners.remove(owner) != nil
        else { return false }
        if pending.owners.isEmpty {
            let path = pending.binding.identity.standardizedRelativePath
            removeLiveEntry(fileID: pending.binding.identity.fileID, from: &root)
            root.shadows[ShadowKey(
                pipelineIdentity: pending.ticket.token.pipelineIdentity,
                relativePath: path
            )] = Shadow(reason: .modified, accessOrdinal: takeAccessOrdinal())
            advanceAllManifestInvalidationGenerations(&root, rootEpoch: rootEpoch)
            advanceContributionGeneration(&root, rootEpoch: rootEpoch)
        } else {
            root.liveByFileID[ticket.token.identity.fileID] = .pending(pending)
        }
        roots[rootEpoch] = root
        return true
    }

    @discardableResult
    func cancelDemands(owner: WorkspaceCodemapLiveDemandOwner) -> Int {
        ensureAccessOrdinalCapacity(requiredCount: usage().entryCount)
        let reservationCountBefore = admissionReservations.count
        admissionReservations.removeAll { $0.owner == owner }
        let preflightCountBefore = demandPreflights.count
        demandPreflights = demandPreflights.filter { $0.value.ticket.owner != owner }
        var cancellationCount = subtractingFloor(
            reservationCountBefore,
            admissionReservations.count
        )
        cancellationCount = addingSaturating(
            cancellationCount,
            subtractingFloor(preflightCountBefore, demandPreflights.count)
        )
        let orderedRootEpochs = roots.keys.sorted(by: rootEpochPrecedes)
        for rootEpoch in orderedRootEpochs {
            guard var root = roots[rootEpoch] else { continue }
            let orderedFileIDs = root.liveByFileID.keys.sorted { $0.uuidString < $1.uuidString }
            var changed = false
            for fileID in orderedFileIDs {
                guard case var .pending(pending)? = root.liveByFileID[fileID],
                      pending.owners.remove(owner) != nil
                else { continue }
                cancellationCount = addingSaturating(cancellationCount, 1)
                changed = true
                if pending.owners.isEmpty {
                    let path = pending.binding.identity.standardizedRelativePath
                    removeLiveEntry(fileID: fileID, from: &root)
                    root.shadows[ShadowKey(
                        pipelineIdentity: pending.ticket.token.pipelineIdentity,
                        relativePath: path
                    )] = Shadow(reason: .modified, accessOrdinal: takeAccessOrdinal())
                    advanceAllManifestInvalidationGenerations(&root, rootEpoch: rootEpoch)
                } else {
                    root.liveByFileID[fileID] = .pending(pending)
                }
            }
            if changed {
                advanceContributionGeneration(&root, rootEpoch: rootEpoch)
                roots[rootEpoch] = root
            }
        }
        return cancellationCount
    }

    @discardableResult
    func revokeReadyArtifact(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        requestGeneration: UInt64
    ) -> Bool {
        guard var root = roots[rootEpoch],
              case let .ready(ready)? = root.liveByFileID[fileID],
              ready.completion.token.requestGeneration == requestGeneration
        else { return false }
        removeLiveEntry(fileID: fileID, from: &root)
        advanceContributionGeneration(&root, rootEpoch: rootEpoch)
        roots[rootEpoch] = root
        return true
    }

    func acceptCompletion(
        ticket: WorkspaceCodemapLiveDemandTicket,
        completion: WorkspaceCodemapArtifactCompletion,
        lease: CodeMapArtifactLease
    ) async -> WorkspaceCodemapLiveCompletionDisposition {
        ensureAccessOrdinalCapacity(requiredCount: 1)
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: ticket.token.identity.rootID,
            rootLifetimeID: ticket.token.identity.rootLifetimeID
        )
        guard var root = roots[rootEpoch] else {
            recordStaleCompletionDrop()
            return .rejected(.rootNotRegistered)
        }
        guard root.authorityIsCurrent else {
            recordStaleCompletionDrop()
            return .rejected(.rootAuthorityInvalid)
        }
        guard ticket.token.catalogGeneration == root.registration.catalogGeneration else {
            recordStaleCompletionDrop()
            return .rejected(.catalogGenerationMismatch)
        }
        guard ticket.token.sourceExpectation.sourceAuthority.repositoryAuthority ==
            root.registration.capability.repositoryAuthority
        else {
            recordStaleCompletionDrop()
            return .rejected(.repositoryAuthorityMismatch)
        }
        guard case let .pending(pending) = root.liveByFileID[ticket.token.identity.fileID] else {
            if case var .ready(ready)? = root.liveByFileID[ticket.token.identity.fileID],
               ready.completionTicket == ticket,
               ready.completion == completion,
               artifactMatches(lease.handle, completion: completion)
            {
                ready.accessOrdinal = takeAccessOrdinal()
                root.liveByFileID[ticket.token.identity.fileID] = .ready(ready)
                roots[rootEpoch] = root
                await lease.close()
                return .exactDuplicate(readySnapshot(rootEpoch: rootEpoch, ready: ready))
            }
            recordStaleCompletionDrop()
            return .rejected(.pendingRequestMissing)
        }
        guard pending.ticket.requestID == ticket.requestID,
              pending.ticket.token == ticket.token
        else {
            recordStaleCompletionDrop()
            return .rejected(.staleTicket)
        }
        guard pending.ticket.contributionGeneration == ticket.contributionGeneration else {
            recordStaleCompletionDrop()
            return .rejected(.contributionGenerationMismatch)
        }

        var candidateBinding = pending.binding
        let disposition = candidateBinding.apply(completion)
        guard disposition == .accepted else {
            recordStaleCompletionDrop()
            return .rejected(.binding(disposition))
        }
        guard artifactMatches(lease.handle, completion: completion) else {
            return .rejected(.artifactHandleMismatch)
        }

        if case .oversize = completion.outcome {
            return acceptUnavailableCompletion(
                ticket: ticket,
                outcome: .oversize,
                lease: lease,
                rootEpoch: rootEpoch,
                root: &root
            )
        }
        if case .decodeFailed = completion.outcome {
            return acceptUnavailableCompletion(
                ticket: ticket,
                outcome: .decodeFailed,
                lease: lease,
                rootEpoch: rootEpoch,
                root: &root
            )
        }
        if case .parseFailed = completion.outcome {
            return acceptUnavailableCompletion(
                ticket: ticket,
                outcome: .parseFailed,
                lease: lease,
                rootEpoch: rootEpoch,
                root: &root
            )
        }

        let candidateBytes = lease.handle.estimatedResidentByteCount
        guard candidateBytes <= policy.maximumArtifactByteCountPerRoot,
              candidateBytes <= policy.maximumArtifactByteCount
        else {
            recordBusyDrop()
            return .busy(.artifactByteLimit)
        }
        guard addingSaturating(rootLeaseCount(root), 1) <= policy.maximumLeaseCountPerRoot,
              addingSaturating(usage().leaseCount, 1) <= policy.maximumLeaseCount
        else {
            recordBusyDrop()
            return .busy(.leaseLimit)
        }
        guard addingSaturating(rootArtifactBytes(root), candidateBytes) <=
            policy.maximumArtifactByteCountPerRoot,
            addingSaturating(usage().artifactByteCount, candidateBytes) <= policy.maximumArtifactByteCount
        else {
            recordBusyDrop()
            return .busy(.artifactByteLimit)
        }

        let ready = StoredReady(
            binding: candidateBinding,
            leaseOwner: WorkspaceCodemapSharedArtifactLease(lease),
            source: .live,
            completionTicket: ticket,
            accessOrdinal: takeAccessOrdinal()
        )
        root.liveByFileID[ticket.token.identity.fileID] = .ready(ready)
        advanceContributionGeneration(&root, rootEpoch: rootEpoch)
        roots[rootEpoch] = root
        return .accepted(readySnapshot(rootEpoch: rootEpoch, ready: ready))
    }

    @discardableResult
    func setUnavailable(
        ticket: WorkspaceCodemapLiveDemandTicket,
        reason: WorkspaceCodemapLiveOverlayUnavailableReason
    ) -> WorkspaceCodemapLiveUnavailableDisposition {
        ensureAccessOrdinalCapacity(requiredCount: 1)
        let identity = ticket.token.identity
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: identity.rootID,
            rootLifetimeID: identity.rootLifetimeID
        )
        guard var root = roots[rootEpoch] else {
            return .rejected(.rootNotRegistered)
        }
        guard root.authorityIsCurrent else {
            return .rejected(.rootAuthorityInvalid)
        }
        guard ticket.token.catalogGeneration == root.registration.catalogGeneration else {
            return .rejected(.catalogGenerationMismatch)
        }
        guard ticket.token.sourceExpectation.sourceAuthority.repositoryAuthority ==
            root.registration.capability.repositoryAuthority
        else {
            return .rejected(.repositoryAuthorityMismatch)
        }
        switch reason {
        case .unsupportedFileType, .transient, .securityExcluded:
            break
        case .terminalArtifact, .invalidated:
            return .rejected(.invalidReason)
        }
        if case let .unavailable(currentTicket, currentReason, _)? = root.liveByFileID[identity.fileID],
           currentTicket == ticket,
           currentReason == reason
        {
            return .exactDuplicate
        }
        guard case let .pending(pending)? = root.liveByFileID[identity.fileID] else {
            return .rejected(.pendingRequestMissing)
        }
        guard pending.ticket.requestID == ticket.requestID,
              pending.ticket.token == ticket.token
        else {
            return .rejected(.staleTicket)
        }
        guard pending.ticket.contributionGeneration == ticket.contributionGeneration else {
            return .rejected(.contributionGenerationMismatch)
        }

        root.liveByFileID[identity.fileID] = .unavailable(
            ticket: ticket,
            reason: reason,
            accessOrdinal: takeAccessOrdinal()
        )
        root.liveFileIDByRelativePath[identity.standardizedRelativePath] = identity.fileID
        advanceContributionGeneration(&root, rootEpoch: rootEpoch)
        roots[rootEpoch] = root
        return .accepted
    }

    @discardableResult
    func invalidatePaths(
        rootEpoch: WorkspaceCodemapRootEpoch,
        standardizedRelativePaths: Set<String>,
        reason: WorkspaceCodemapLiveOverlayInvalidationReason
    ) -> Int {
        ensureAccessOrdinalCapacity(requiredCount: standardizedRelativePaths.count)
        guard var root = roots[rootEpoch], root.authorityIsCurrent else { return 0 }
        var invalidated = 0
        var observedValidPath = false
        for path in standardizedRelativePaths {
            guard let relativePath = validatedRelativePath(path) else { continue }
            observedValidPath = true
            var affectedPipelines: Set<CodeMapPipelineIdentity> = []
            let removedClean = root.cleanByRelativePath.removeValue(forKey: relativePath) != nil
            if let pipelineIdentity = root.cleanPipelineByRelativePath.removeValue(forKey: relativePath),
               var pipeline = root.pipelines[pipelineIdentity]
            {
                affectedPipelines.insert(pipelineIdentity)
                pipeline.cleanRelativePaths.remove(relativePath)
                root.pipelines[pipelineIdentity] = pipeline
            }
            let liveFileID = root.liveFileIDByRelativePath[relativePath]
            if let liveFileID, let live = root.liveByFileID[liveFileID] {
                affectedPipelines.insert(live.pipelineIdentity)
                removeLiveEntry(fileID: liveFileID, from: &root)
            }
            for (pipelineIdentity, pipeline) in root.pipelines where pipeline.manifest?.records.contains(where: {
                loadedRootRelativePath(
                    repositoryRelativePath: $0.repositoryRelativePath,
                    prefix: root.registration.capability.repositoryRelativeLoadedRootPrefix
                ) == relativePath
            }) == true {
                affectedPipelines.insert(pipelineIdentity)
            }
            if removedClean || liveFileID != nil || !affectedPipelines.isEmpty {
                invalidated = addingSaturating(invalidated, 1)
                for pipelineIdentity in affectedPipelines {
                    root.shadows[ShadowKey(
                        pipelineIdentity: pipelineIdentity,
                        relativePath: relativePath
                    )] = Shadow(reason: reason, accessOrdinal: takeAccessOrdinal())
                }
            }
        }
        if observedValidPath {
            advanceAllManifestInvalidationGenerations(&root, rootEpoch: rootEpoch)
            advanceContributionGeneration(&root, rootEpoch: rootEpoch)
        }
        roots[rootEpoch] = root
        return invalidated
    }

    @discardableResult
    func invalidateRootAuthority(
        rootEpoch: WorkspaceCodemapRootEpoch,
        expectedAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        reason _: WorkspaceCodemapLiveOverlayInvalidationReason
    ) -> Bool {
        guard var root = roots[rootEpoch],
              root.registration.capability.repositoryAuthority == expectedAuthority
        else { return false }
        root.authorityIsCurrent = false
        removeAdmissionReservations(rootEpoch: rootEpoch)
        advanceAllManifestInvalidationGenerations(&root, rootEpoch: rootEpoch)
        root.pipelines.removeAll()
        root.cleanByRelativePath.removeAll()
        root.cleanPipelineByRelativePath.removeAll()
        root.liveByFileID.removeAll()
        root.liveFileIDByRelativePath.removeAll()
        root.shadows.removeAll()
        advanceContributionGeneration(&root, rootEpoch: rootEpoch)
        roots[rootEpoch] = root
        return true
    }

    func snapshot(rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapLiveRootSnapshot? {
        ensureAccessOrdinalCapacity(requiredCount: roots[rootEpoch].map { visibleReadyEntries($0).count } ?? 0)
        guard var root = roots[rootEpoch] else { return nil }
        if root.authorityIsCurrent {
            touchVisibleReadyEntries(&root)
            roots[rootEpoch] = root
        }
        return WorkspaceCodemapLiveRootSnapshot(
            rootEpoch: rootEpoch,
            catalogGeneration: root.registration.catalogGeneration,
            repositoryAuthority: root.registration.capability.repositoryAuthority,
            contributionGeneration: root.contributionGeneration,
            authorityIsCurrent: root.authorityIsCurrent,
            manifestGeneration: root.pipelines.count == 1
                ? root.pipelines.values.first?.manifest?.manifestGeneration
                : nil,
            entries: entrySnapshots(rootEpoch: rootEpoch, root: root)
        )
    }

    func freeze(rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapLiveOverlayBundle? {
        ensureAccessOrdinalCapacity(requiredCount: roots[rootEpoch].map { visibleReadyEntries($0).count } ?? 0)
        guard var root = roots[rootEpoch], root.authorityIsCurrent else { return nil }
        touchVisibleReadyEntries(&root)
        roots[rootEpoch] = root
        let ready = visibleReadyEntries(root)
        return WorkspaceCodemapLiveOverlayBundle(
            rootEpoch: rootEpoch,
            catalogGeneration: root.registration.catalogGeneration,
            repositoryAuthority: root.registration.capability.repositoryAuthority,
            contributionGeneration: root.contributionGeneration,
            entries: ready.map { readySnapshot(rootEpoch: rootEpoch, ready: $0) },
            bindings: ready.map(\.binding),
            leaseOwners: ready.map(\.leaseOwner)
        )
    }

    func freezeReadyArtifact(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        requestGeneration: UInt64
    ) -> WorkspaceCodemapLiveOverlayBundle? {
        guard requestGeneration > 0 else { return nil }
        ensureAccessOrdinalCapacity(requiredCount: 1)
        guard var root = roots[rootEpoch],
              root.authorityIsCurrent
        else { return nil }

        let matches = visibleReadyEntries(root).filter {
            $0.binding.identity.fileID == fileID &&
                $0.completion.token.requestGeneration == requestGeneration
        }
        guard matches.count == 1, let matchedReady = matches.first else { return nil }

        touchVisibleReadyEntry(&root, matching: matchedReady)
        let refreshedMatches = visibleReadyEntries(root).filter {
            $0.binding.identity.fileID == fileID &&
                $0.completion.token.requestGeneration == requestGeneration
        }
        guard refreshedMatches.count == 1, let ready = refreshedMatches.first else { return nil }
        roots[rootEpoch] = root
        return WorkspaceCodemapLiveOverlayBundle(
            rootEpoch: rootEpoch,
            catalogGeneration: root.registration.catalogGeneration,
            repositoryAuthority: root.registration.capability.repositoryAuthority,
            contributionGeneration: root.contributionGeneration,
            entries: [readySnapshot(rootEpoch: rootEpoch, ready: ready)],
            bindings: [ready.binding],
            leaseOwners: [ready.leaseOwner]
        )
    }

    func graphContributions(rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapLiveGraphSnapshot? {
        ensureAccessOrdinalCapacity(requiredCount: roots[rootEpoch].map { visibleReadyEntries($0).count } ?? 0)
        guard var root = roots[rootEpoch], root.authorityIsCurrent else { return nil }
        touchVisibleReadyEntries(&root)
        roots[rootEpoch] = root
        return WorkspaceCodemapLiveGraphSnapshot(
            rootEpoch: rootEpoch,
            catalogGeneration: root.registration.catalogGeneration,
            repositoryAuthority: root.registration.capability.repositoryAuthority,
            contributionGeneration: root.contributionGeneration,
            bindings: visibleReadyEntries(root).map(\.binding)
        )
    }

    func consumeGraphSnapshot(
        _ snapshot: WorkspaceCodemapLiveGraphSnapshot
    ) -> [WorkspaceCodemapArtifactBinding]? {
        ensureAccessOrdinalCapacity(
            requiredCount: roots[snapshot.rootEpoch].map { visibleReadyEntries($0).count } ?? 0
        )
        guard let root = roots[snapshot.rootEpoch], root.authorityIsCurrent else { return nil }
        let current = WorkspaceCodemapLiveGraphSnapshot(
            rootEpoch: snapshot.rootEpoch,
            catalogGeneration: root.registration.catalogGeneration,
            repositoryAuthority: root.registration.capability.repositoryAuthority,
            contributionGeneration: root.contributionGeneration,
            bindings: visibleReadyEntries(root).map(\.binding)
        )
        guard current == snapshot else { return nil }
        touchVisibleReadyEntries(rootEpoch: snapshot.rootEpoch)
        return snapshot.bindings
    }

    func accounting() -> WorkspaceCodemapLiveOverlayAccounting {
        let perRoot = roots.map { rootEpoch, root in
            rootAccounting(rootEpoch: rootEpoch, root: root)
        }.sorted { lhs, rhs in
            lhs.rootEpoch.rootID.uuidString < rhs.rootEpoch.rootID.uuidString
        }
        return WorkspaceCodemapLiveOverlayAccounting(
            rootCount: roots.count,
            entryCount: perRoot.reduce(0) { addingSaturating($0, $1.entryCount) },
            readyEntryCount: perRoot.reduce(0) { addingSaturating($0, $1.readyEntryCount) },
            pendingEntryCount: perRoot.reduce(0) { addingSaturating($0, $1.pendingEntryCount) },
            unavailableEntryCount: perRoot.reduce(0) { addingSaturating($0, $1.unavailableEntryCount) },
            shadowEntryCount: perRoot.reduce(0) { addingSaturating($0, $1.shadowEntryCount) },
            waiterCount: perRoot.reduce(0) { addingSaturating($0, $1.waiterCount) },
            leaseCount: perRoot.reduce(0) { addingSaturating($0, $1.leaseCount) },
            artifactByteCount: perRoot.reduce(0) { addingSaturating($0, $1.artifactByteCount) },
            admissionReservationCount: addingSaturating(
                admissionReservations.count,
                demandPreflights.count
            ),
            evictionCount: evictionCount,
            busyDropCount: busyDropCount,
            staleCompletionDropCount: staleCompletionDropCount,
            roots: perRoot
        )
    }

    private func entrySnapshots(
        rootEpoch: WorkspaceCodemapRootEpoch,
        root: RootState
    ) -> [WorkspaceCodemapLiveEntrySnapshot] {
        var result: [WorkspaceCodemapLiveEntrySnapshot] = []
        for ready in visibleReadyEntries(root) {
            let completion = ready.completion
            result.append(WorkspaceCodemapLiveEntrySnapshot(
                fileID: ready.binding.identity.fileID,
                standardizedRelativePath: ready.binding.identity.standardizedRelativePath,
                requestGeneration: completion.token.requestGeneration,
                state: .ready(
                    source: ready.source,
                    artifactKey: completion.artifactKey,
                    outcome: WorkspaceCodemapLiveArtifactOutcome(completion.outcome)
                )
            ))
        }
        for entry in root.liveByFileID.values {
            switch entry {
            case .ready:
                continue
            case let .pending(pending):
                result.append(WorkspaceCodemapLiveEntrySnapshot(
                    fileID: pending.binding.identity.fileID,
                    standardizedRelativePath: pending.binding.identity.standardizedRelativePath,
                    requestGeneration: pending.ticket.token.requestGeneration,
                    state: .pending(waiterCount: pending.owners.count)
                ))
            case let .unavailable(ticket, reason, _):
                result.append(WorkspaceCodemapLiveEntrySnapshot(
                    fileID: ticket.token.identity.fileID,
                    standardizedRelativePath: ticket.token.identity.standardizedRelativePath,
                    requestGeneration: ticket.token.requestGeneration,
                    state: .unavailable(reason)
                ))
            }
        }
        for (key, shadow) in root.shadows {
            result.append(WorkspaceCodemapLiveEntrySnapshot(
                fileID: nil,
                standardizedRelativePath: key.relativePath,
                requestGeneration: nil,
                state: .shadowed(shadow.reason)
            ))
        }
        return result.sorted {
            if $0.standardizedRelativePath != $1.standardizedRelativePath {
                return $0.standardizedRelativePath.utf8.lexicographicallyPrecedes($1.standardizedRelativePath.utf8)
            }
            return ($0.fileID?.uuidString ?? "") < ($1.fileID?.uuidString ?? "")
        }
    }

    private func visibleReadyEntries(_ root: RootState) -> [StoredReady] {
        var result: [StoredReady] = root.cleanByRelativePath.compactMap { path, entry in
            guard let pipelineIdentity = root.cleanPipelineByRelativePath[path] else { return nil }
            let shadowKey = ShadowKey(
                pipelineIdentity: pipelineIdentity,
                relativePath: path
            )
            return root.liveFileIDByRelativePath[path] == nil && root.shadows[shadowKey] == nil ? entry : nil
        }
        result.append(contentsOf: root.liveByFileID.values.compactMap {
            guard case let .ready(ready) = $0 else { return nil }
            return ready
        })
        return result.sorted {
            let lhs = $0.binding.identity.standardizedRelativePath
            let rhs = $1.binding.identity.standardizedRelativePath
            if lhs != rhs { return lhs.utf8.lexicographicallyPrecedes(rhs.utf8) }
            return $0.binding.identity.fileID.uuidString < $1.binding.identity.fileID.uuidString
        }
    }

    private func touchVisibleReadyEntries(rootEpoch: WorkspaceCodemapRootEpoch) {
        guard var root = roots[rootEpoch], root.authorityIsCurrent else { return }
        touchVisibleReadyEntries(&root)
        roots[rootEpoch] = root
    }

    private func touchVisibleReadyEntry(
        _ root: inout RootState,
        matching selected: StoredReady
    ) {
        let identity = selected.binding.identity
        let requestGeneration = selected.completion.token.requestGeneration
        if case var .ready(ready)? = root.liveByFileID[identity.fileID],
           ready.binding.identity == identity,
           ready.completion.token.requestGeneration == requestGeneration
        {
            ready.accessOrdinal = takeAccessOrdinal()
            root.liveByFileID[identity.fileID] = .ready(ready)
            return
        }

        let relativePath = identity.standardizedRelativePath
        guard root.liveFileIDByRelativePath[relativePath] == nil,
              let pipelineIdentity = root.cleanPipelineByRelativePath[relativePath],
              root.shadows[ShadowKey(
                  pipelineIdentity: pipelineIdentity,
                  relativePath: relativePath
              )] == nil,
              var ready = root.cleanByRelativePath[relativePath],
              ready.binding.identity == identity,
              ready.completion.token.requestGeneration == requestGeneration
        else { return }
        ready.accessOrdinal = takeAccessOrdinal()
        root.cleanByRelativePath[relativePath] = ready
    }

    private func touchVisibleReadyEntries(_ root: inout RootState) {
        let cleanPaths = root.cleanByRelativePath.keys.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        for path in cleanPaths {
            guard let pipelineIdentity = root.cleanPipelineByRelativePath[path],
                  root.liveFileIDByRelativePath[path] == nil,
                  root.shadows[ShadowKey(
                      pipelineIdentity: pipelineIdentity,
                      relativePath: path
                  )] == nil,
                  var ready = root.cleanByRelativePath[path]
            else { continue }
            ready.accessOrdinal = takeAccessOrdinal()
            root.cleanByRelativePath[path] = ready
        }
        let liveFileIDs = root.liveByFileID.keys.sorted { $0.uuidString < $1.uuidString }
        for fileID in liveFileIDs {
            guard case var .ready(ready)? = root.liveByFileID[fileID] else { continue }
            ready.accessOrdinal = takeAccessOrdinal()
            root.liveByFileID[fileID] = .ready(ready)
        }
    }

    private func readySnapshot(
        rootEpoch: WorkspaceCodemapRootEpoch,
        ready: StoredReady
    ) -> WorkspaceCodemapLiveReadySnapshot {
        let completion = ready.completion
        return WorkspaceCodemapLiveReadySnapshot(
            rootEpoch: rootEpoch,
            fileID: ready.binding.identity.fileID,
            standardizedRelativePath: ready.binding.identity.standardizedRelativePath,
            requestGeneration: completion.token.requestGeneration,
            source: ready.source,
            artifactKey: completion.artifactKey,
            outcome: WorkspaceCodemapLiveArtifactOutcome(completion.outcome)
        )
    }

    private func rootAccounting(
        rootEpoch: WorkspaceCodemapRootEpoch,
        root: RootState
    ) -> WorkspaceCodemapLiveOverlayRootAccounting {
        let cleanReadyCount = root.cleanByRelativePath.count
        var liveReadyCount = 0
        var pendingCount = 0
        var unavailableCount = 0
        var waiters = 0
        var bytes: UInt64 = root.cleanByRelativePath.values.reduce(0) {
            addingSaturating($0, $1.leaseOwner.lease.handle.estimatedResidentByteCount)
        }
        for entry in root.liveByFileID.values {
            switch entry {
            case let .pending(pending):
                pendingCount = addingSaturating(pendingCount, 1)
                waiters = addingSaturating(waiters, pending.owners.count)
            case let .ready(ready):
                liveReadyCount = addingSaturating(liveReadyCount, 1)
                bytes = addingSaturating(bytes, ready.leaseOwner.lease.handle.estimatedResidentByteCount)
            case .unavailable:
                unavailableCount = addingSaturating(unavailableCount, 1)
            }
        }
        let readyCount = addingSaturating(cleanReadyCount, liveReadyCount)
        return WorkspaceCodemapLiveOverlayRootAccounting(
            rootEpoch: rootEpoch,
            entryCount: addingSaturating(
                addingSaturating(readyCount, pendingCount),
                addingSaturating(unavailableCount, root.shadows.count)
            ),
            readyEntryCount: readyCount,
            pendingEntryCount: pendingCount,
            unavailableEntryCount: unavailableCount,
            shadowEntryCount: root.shadows.count,
            waiterCount: waiters,
            leaseCount: readyCount,
            artifactByteCount: bytes,
            admissionReservationCount: admissionReservationCount(rootEpoch: rootEpoch)
        )
    }

    private func usage(
        excludingCleanEntriesFor rootEpoch: WorkspaceCodemapRootEpoch? = nil,
        pipelineIdentity: CodeMapPipelineIdentity? = nil
    ) -> (
        entryCount: Int,
        waiterCount: Int,
        leaseCount: Int,
        artifactByteCount: UInt64
    ) {
        roots.reduce(into: (0, 0, 0, UInt64(0))) { partial, element in
            let accounting = rootAccounting(rootEpoch: element.key, root: element.value)
            let excludedPaths: Set<String> = if element.key == rootEpoch, let pipelineIdentity {
                element.value.pipelines[pipelineIdentity]?.cleanRelativePaths ?? []
            } else if element.key == rootEpoch {
                Set(element.value.cleanByRelativePath.keys)
            } else {
                []
            }
            let cleanCount = excludedPaths.count
            let cleanBytes: UInt64 = element.key == rootEpoch
                ? cleanArtifactBytes(element.value, paths: excludedPaths)
                : 0
            partial.0 = addingSaturating(partial.0, subtractingFloor(accounting.entryCount, cleanCount))
            partial.1 = addingSaturating(partial.1, accounting.waiterCount)
            partial.2 = addingSaturating(partial.2, subtractingFloor(accounting.leaseCount, cleanCount))
            partial.3 = addingSaturating(
                partial.3,
                subtractingFloor(accounting.artifactByteCount, cleanBytes)
            )
        }
    }

    private func admissionReservationCount(rootEpoch: WorkspaceCodemapRootEpoch) -> Int {
        let queued = admissionReservations.reduce(0) {
            let matches = $1.token.identity.rootID == rootEpoch.rootID &&
                $1.token.identity.rootLifetimeID == rootEpoch.rootLifetimeID
            return addingSaturating($0, matches ? 1 : 0)
        }
        let preflights = demandPreflights.values.reduce(0) {
            addingSaturating($0, $1.ticket.rootEpoch == rootEpoch ? 1 : 0)
        }
        return addingSaturating(queued, preflights)
    }

    private func entryCount(_ root: RootState) -> Int {
        addingSaturating(
            addingSaturating(root.cleanByRelativePath.count, root.liveByFileID.count),
            root.shadows.count
        )
    }

    private func rootWaiterCount(_ root: RootState) -> Int {
        root.liveByFileID.values.reduce(0) {
            guard case let .pending(pending) = $1 else { return $0 }
            return addingSaturating($0, pending.owners.count)
        }
    }

    private func rootLeaseCount(_ root: RootState) -> Int {
        addingSaturating(root.cleanByRelativePath.count, liveLeaseCount(root))
    }

    private func liveLeaseCount(_ root: RootState) -> Int {
        root.liveByFileID.values.reduce(0) {
            guard case .ready = $1 else { return $0 }
            return addingSaturating($0, 1)
        }
    }

    private func rootArtifactBytes(_ root: RootState) -> UInt64 {
        addingSaturating(
            root.cleanByRelativePath.values.reduce(0) {
                addingSaturating($0, $1.leaseOwner.lease.handle.estimatedResidentByteCount)
            },
            liveArtifactBytes(root)
        )
    }

    private func cleanArtifactBytes(_ root: RootState, paths: Set<String>) -> UInt64 {
        paths.reduce(UInt64(0)) { partial, path in
            guard let ready = root.cleanByRelativePath[path] else { return partial }
            return addingSaturating(partial, ready.leaseOwner.lease.handle.estimatedResidentByteCount)
        }
    }

    private func liveArtifactBytes(_ root: RootState) -> UInt64 {
        root.liveByFileID.values.reduce(0) {
            guard case let .ready(ready) = $1 else { return $0 }
            return addingSaturating($0, ready.leaseOwner.lease.handle.estimatedResidentByteCount)
        }
    }

    private func removeLiveEntry(fileID: UUID, from root: inout RootState) {
        guard let removed = root.liveByFileID.removeValue(forKey: fileID) else { return }
        if root.liveFileIDByRelativePath[removed.identity.standardizedRelativePath] == fileID {
            root.liveFileIDByRelativePath.removeValue(forKey: removed.identity.standardizedRelativePath)
        }
    }

    private func evictEntryForCapacity(
        requiredRootEpoch: WorkspaceCodemapRootEpoch?,
        excludingFileIDs: Set<UUID>
    ) -> Bool {
        struct Candidate {
            let rootEpoch: WorkspaceCodemapRootEpoch
            let relativePath: String
            let fileID: UUID?
            let shadowKey: ShadowKey?
            let isShadow: Bool
            let isNegative: Bool
            let accessOrdinal: UInt64
        }
        var candidates: [Candidate] = []
        for (rootEpoch, root) in roots where requiredRootEpoch == nil || requiredRootEpoch == rootEpoch {
            for (key, shadow) in root.shadows {
                candidates.append(Candidate(
                    rootEpoch: rootEpoch,
                    relativePath: key.relativePath,
                    fileID: nil,
                    shadowKey: key,
                    isShadow: true,
                    isNegative: true,
                    accessOrdinal: shadow.accessOrdinal
                ))
            }
            for (path, ready) in root.cleanByRelativePath {
                candidates.append(Candidate(
                    rootEpoch: rootEpoch,
                    relativePath: path,
                    fileID: nil,
                    shadowKey: nil,
                    isShadow: false,
                    isNegative: false,
                    accessOrdinal: ready.accessOrdinal
                ))
            }
            for (fileID, entry) in root.liveByFileID where !excludingFileIDs.contains(fileID) {
                switch entry {
                case let .ready(ready):
                    candidates.append(Candidate(
                        rootEpoch: rootEpoch,
                        relativePath: ready.binding.identity.standardizedRelativePath,
                        fileID: fileID,
                        shadowKey: nil,
                        isShadow: false,
                        isNegative: false,
                        accessOrdinal: ready.accessOrdinal
                    ))
                case let .unavailable(ticket, _, accessOrdinal):
                    candidates.append(Candidate(
                        rootEpoch: rootEpoch,
                        relativePath: ticket.token.identity.standardizedRelativePath,
                        fileID: fileID,
                        shadowKey: nil,
                        isShadow: false,
                        isNegative: true,
                        accessOrdinal: accessOrdinal
                    ))
                case .pending:
                    continue
                }
            }
        }
        guard let candidate = candidates.min(by: { lhs, rhs in
            if lhs.isNegative != rhs.isNegative {
                return lhs.isNegative
            }
            if lhs.accessOrdinal != rhs.accessOrdinal {
                return lhs.accessOrdinal < rhs.accessOrdinal
            }
            if lhs.rootEpoch != rhs.rootEpoch {
                return rootEpochPrecedes(lhs.rootEpoch, rhs.rootEpoch)
            }
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
            }
            return (lhs.fileID?.uuidString ?? "") < (rhs.fileID?.uuidString ?? "")
        }), var root = roots[candidate.rootEpoch]
        else { return false }

        if let shadowKey = candidate.shadowKey {
            root.shadows.removeValue(forKey: shadowKey)
            if root.cleanPipelineByRelativePath[shadowKey.relativePath] == shadowKey.pipelineIdentity {
                removeCleanEntry(path: shadowKey.relativePath, from: &root)
            }
        } else if let fileID = candidate.fileID {
            removeLiveEntry(fileID: fileID, from: &root)
            removeCleanEntry(path: candidate.relativePath, from: &root)
        } else {
            removeCleanEntry(path: candidate.relativePath, from: &root)
        }
        if candidate.isNegative {
            advanceAllManifestInvalidationGenerations(&root, rootEpoch: candidate.rootEpoch)
        }
        advanceContributionGeneration(&root, rootEpoch: candidate.rootEpoch)
        roots[candidate.rootEpoch] = root
        evictionCount = addingSaturating(evictionCount, 1)
        return true
    }

    private func advanceContributionGeneration(
        _ root: inout RootState,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        let (next, overflow) = root.contributionGeneration.rawValue.addingReportingOverflow(1)
        guard !overflow else {
            failClosedGenerationExhaustion(&root, rootEpoch: rootEpoch)
            return
        }
        root.contributionGeneration = .init(rawValue: next)
    }

    @discardableResult
    private func advanceManifestInvalidationGeneration(
        _ pipeline: inout PipelineManifestState,
        root: inout RootState,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        let (next, overflow) = pipeline.invalidationGeneration.addingReportingOverflow(1)
        guard !overflow else {
            failClosedGenerationExhaustion(&root, rootEpoch: rootEpoch)
            return false
        }
        pipeline.invalidationGeneration = next
        return true
    }

    private func advanceAllManifestInvalidationGenerations(
        _ root: inout RootState,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        for identity in root.pipelines.keys {
            guard var pipeline = root.pipelines[identity],
                  advanceManifestInvalidationGeneration(
                      &pipeline,
                      root: &root,
                      rootEpoch: rootEpoch
                  )
            else { return }
            root.pipelines[identity] = pipeline
        }
    }

    private func removeCleanEntry(path: String, from root: inout RootState) {
        root.cleanByRelativePath.removeValue(forKey: path)
        guard let identity = root.cleanPipelineByRelativePath.removeValue(forKey: path),
              var pipeline = root.pipelines[identity]
        else { return }
        pipeline.cleanRelativePaths.remove(path)
        root.pipelines[identity] = pipeline
    }

    private func failClosedGenerationExhaustion(
        _ root: inout RootState,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        root.authorityIsCurrent = false
        removeAdmissionReservations(rootEpoch: rootEpoch)
    }

    private func rootEpochPrecedes(
        _ lhs: WorkspaceCodemapRootEpoch,
        _ rhs: WorkspaceCodemapRootEpoch
    ) -> Bool {
        if lhs.rootID != rhs.rootID {
            return lhs.rootID.uuidString < rhs.rootID.uuidString
        }
        return lhs.rootLifetimeID.uuidString < rhs.rootLifetimeID.uuidString
    }

    private func ensureAccessOrdinalCapacity(requiredCount: Int) {
        guard requiredCount > 0, let required = UInt64(exactly: requiredCount) else { return }
        let (_, overflow) = nextAccessOrdinal.addingReportingOverflow(required)
        if overflow { rebaseAccessOrdinals() }
    }

    private func rebaseAccessOrdinals() {
        var items: [AccessItem] = []
        for (rootEpoch, root) in roots {
            for (path, ready) in root.cleanByRelativePath {
                items.append(AccessItem(
                    location: .clean(rootEpoch: rootEpoch, path: path),
                    ordinal: ready.accessOrdinal,
                    rootEpoch: rootEpoch,
                    path: path,
                    fileID: ready.binding.identity.fileID
                ))
            }
            for (fileID, entry) in root.liveByFileID {
                switch entry {
                case let .ready(ready):
                    items.append(AccessItem(
                        location: .live(rootEpoch: rootEpoch, fileID: fileID),
                        ordinal: ready.accessOrdinal,
                        rootEpoch: rootEpoch,
                        path: ready.binding.identity.standardizedRelativePath,
                        fileID: fileID
                    ))
                case let .unavailable(ticket, _, ordinal):
                    items.append(AccessItem(
                        location: .unavailable(rootEpoch: rootEpoch, fileID: fileID),
                        ordinal: ordinal,
                        rootEpoch: rootEpoch,
                        path: ticket.token.identity.standardizedRelativePath,
                        fileID: fileID
                    ))
                case .pending:
                    break
                }
            }
            for (key, shadow) in root.shadows {
                items.append(AccessItem(
                    location: .shadow(rootEpoch: rootEpoch, key: key),
                    ordinal: shadow.accessOrdinal,
                    rootEpoch: rootEpoch,
                    path: key.relativePath,
                    fileID: nil
                ))
            }
        }
        items.sort {
            if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
            if $0.rootEpoch != $1.rootEpoch { return rootEpochPrecedes($0.rootEpoch, $1.rootEpoch) }
            if $0.path != $1.path { return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            return ($0.fileID?.uuidString ?? "") < ($1.fileID?.uuidString ?? "")
        }
        for (offset, item) in items.enumerated() {
            let (oneBasedOffset, overflow) = offset.addingReportingOverflow(1)
            guard !overflow,
                  let ordinal = UInt64(exactly: oneBasedOffset),
                  var root = roots[item.rootEpoch]
            else { continue }
            switch item.location {
            case let .clean(_, path):
                if var ready = root.cleanByRelativePath[path] {
                    ready.accessOrdinal = ordinal
                    root.cleanByRelativePath[path] = ready
                }
            case let .live(_, fileID):
                if case var .ready(ready)? = root.liveByFileID[fileID] {
                    ready.accessOrdinal = ordinal
                    root.liveByFileID[fileID] = .ready(ready)
                }
            case let .unavailable(_, fileID):
                if case let .unavailable(ticket, reason, _)? = root.liveByFileID[fileID] {
                    root.liveByFileID[fileID] = .unavailable(
                        ticket: ticket,
                        reason: reason,
                        accessOrdinal: ordinal
                    )
                }
            case let .shadow(_, key):
                if var shadow = root.shadows[key] {
                    shadow.accessOrdinal = ordinal
                    root.shadows[key] = shadow
                }
            }
            roots[item.rootEpoch] = root
        }
        nextAccessOrdinal = addingSaturating(UInt64(exactly: items.count) ?? .max, 1)
    }

    private func takeAccessOrdinal() -> UInt64 {
        let ordinal = nextAccessOrdinal
        let (successor, overflow) = nextAccessOrdinal.addingReportingOverflow(1)
        nextAccessOrdinal = overflow ? .max : successor
        return ordinal
    }

    private func recordBusyDrop() {
        busyDropCount = addingSaturating(busyDropCount, 1)
    }

    private func recordStaleCompletionDrop() {
        staleCompletionDropCount = addingSaturating(staleCompletionDropCount, 1)
    }

    private func hasActiveAdmissionPriority(
        owner: WorkspaceCodemapLiveDemandOwner,
        token: WorkspaceCodemapArtifactRequestToken
    ) -> Bool {
        guard let first = admissionReservations.first else { return true }
        return activeAdmissionReservationID == first.reservationID &&
            first.owner == owner && first.token == token
    }

    private func queueDemand(
        owner: WorkspaceCodemapLiveDemandOwner,
        token: WorkspaceCodemapArtifactRequestToken,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> WorkspaceCodemapLiveDemandDisposition {
        if let current = admissionReservations.first(where: {
            $0.owner == owner && $0.token == token
        }) {
            return .queued(current)
        }
        let rootCount = admissionReservations.reduce(0) {
            let candidateRoot = WorkspaceCodemapRootEpoch(
                rootID: $1.token.identity.rootID,
                rootLifetimeID: $1.token.identity.rootLifetimeID
            )
            return addingSaturating($0, candidateRoot == rootEpoch ? 1 : 0)
        }
        let preflightRootCount = demandPreflights.values.count(where: {
            $0.ticket.rootEpoch == rootEpoch
        })
        guard addingSaturating(rootCount, preflightRootCount) <
            policy.maximumAdmissionReservationCountPerRoot,
            addingSaturating(admissionReservations.count, demandPreflights.count) <
            policy.maximumAdmissionReservationCount
        else {
            recordBusyDrop()
            return .busy(.admissionQueueLimit)
        }
        let reservation = WorkspaceCodemapLiveDemandReservation(
            owner: owner,
            token: token,
            reservationID: UUID()
        )
        admissionReservations.append(reservation)
        return .queued(reservation)
    }

    private func removeAdmissionReservations(rootEpoch: WorkspaceCodemapRootEpoch) {
        admissionReservations.removeAll {
            $0.token.identity.rootID == rootEpoch.rootID &&
                $0.token.identity.rootLifetimeID == rootEpoch.rootLifetimeID
        }
        demandPreflights = demandPreflights.filter { $0.value.ticket.rootEpoch != rootEpoch }
    }

    private func resolvedCompletion(
        _ binding: WorkspaceCodemapArtifactBinding
    ) -> WorkspaceCodemapArtifactCompletion? {
        guard case let .resolved(completion) = binding.availability else { return nil }
        return completion
    }

    private func artifactMatches(
        _ handle: CodeMapArtifactHandle,
        completion: WorkspaceCodemapArtifactCompletion
    ) -> Bool {
        handle.key == completion.artifactKey && handle.outcome == completion.outcome
    }

    private func acceptUnavailableCompletion(
        ticket: WorkspaceCodemapLiveDemandTicket,
        outcome: WorkspaceCodemapLiveArtifactOutcome,
        lease: CodeMapArtifactLease,
        rootEpoch: WorkspaceCodemapRootEpoch,
        root: inout RootState
    ) -> WorkspaceCodemapLiveCompletionDisposition {
        let identity = ticket.token.identity
        root.liveByFileID[identity.fileID] = .unavailable(
            ticket: ticket,
            reason: .terminalArtifact(outcome),
            accessOrdinal: takeAccessOrdinal()
        )
        advanceContributionGeneration(&root, rootEpoch: rootEpoch)
        roots[rootEpoch] = root
        lease.closeSynchronously()
        return .acceptedUnavailable(outcome)
    }

    private func graphContribution(
        _ completion: WorkspaceCodemapArtifactCompletion
    ) -> CodeMapSelectionGraphContribution? {
        switch completion.outcome {
        case let .ready(artifact):
            CodeMapSelectionGraphContribution(artifactKey: completion.artifactKey, artifact: artifact)
        case .readyNoSymbols:
            CodeMapSelectionGraphContribution(
                artifactKey: completion.artifactKey,
                definitions: [] as [String],
                references: [] as [String]
            )
        case .oversize, .decodeFailed, .parseFailed:
            nil
        }
    }

    private func estimatedManifestByteCount(
        _ snapshot: CodeMapRootManifestSnapshot,
        limit: UInt64
    ) -> UInt64? {
        var total: UInt64 = 64

        func charge(_ byteCount: Int) -> Bool {
            guard let bytes = UInt64(exactly: byteCount) else { return false }
            guard let next = addingChecked(total, bytes), next <= limit else { return false }
            total = next
            return true
        }

        let authority = snapshot.authority
        guard charge(snapshot.namespace.canonicalBytes.count),
              charge(64),
              charge(authority.repositoryBindingEpoch.utf8.count),
              charge(authority.worktreeBindingEpoch.utf8.count),
              charge(authority.layoutGeneration.utf8.count),
              charge(authority.indexGeneration.utf8.count),
              charge(authority.checkoutConfigurationGeneration.utf8.count),
              charge(authority.attributeGeneration.utf8.count),
              charge(authority.sparseGeneration.utf8.count),
              charge(authority.metadataGeneration.utf8.count)
        else { return nil }
        for record in snapshot.records {
            guard charge(record.repositoryRelativePath.utf8.count),
                  charge(record.locatorIdentity.canonicalBytes.count),
                  charge(record.artifactKey.canonicalBytes.count),
                  charge(record.contribution == nil ? 16 : 64)
            else { return nil }
        }
        return total
    }

    private func manifestContentsEqual(
        _ lhs: CodeMapRootManifestSnapshot,
        _ rhs: CodeMapRootManifestSnapshot
    ) -> Bool {
        guard lhs.namespace == rhs.namespace,
              lhs.authority == rhs.authority
        else { return false }
        manifestRecordEqualityTraversal()
        return lhs.records == rhs.records
    }

    private func manifestOutcome(_ outcome: CodeMapSyntaxArtifactOutcome) -> CodeMapRootManifestOutcome {
        switch outcome {
        case .ready: .ready
        case .readyNoSymbols: .readyNoSymbols
        case .oversize: .terminalOversize
        case .decodeFailed: .terminalDecodeFailure
        case .parseFailed: .terminalParseFailure
        }
    }

    private func repositoryRelativePath(loadedRootRelativePath: String, prefix: String) -> String {
        prefix.isEmpty ? loadedRootRelativePath : prefix + "/" + loadedRootRelativePath
    }

    private func loadedRootRelativePath(repositoryRelativePath: String, prefix: String) -> String? {
        if prefix.isEmpty { return validatedRelativePath(repositoryRelativePath) }
        let expectedPrefix = prefix + "/"
        guard repositoryRelativePath.hasPrefix(expectedPrefix) else { return nil }
        return validatedRelativePath(String(repositoryRelativePath.dropFirst(expectedPrefix.count)))
    }

    private func validatedRelativePath(_ path: String) -> String? {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              path.utf8.count <= 4 * 1024
        else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components.joined(separator: "/")
    }

    private func addingChecked(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private func addingChecked(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private func addingSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private func subtractingFloor(_ lhs: Int, _ rhs: Int) -> Int {
        lhs >= rhs ? lhs - rhs : 0
    }

    private func subtractingFloor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }
}
