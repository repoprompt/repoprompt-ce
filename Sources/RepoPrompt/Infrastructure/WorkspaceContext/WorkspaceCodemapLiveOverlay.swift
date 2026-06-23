import Foundation

actor WorkspaceCodemapLiveOverlay {
    private struct Registration: Equatable {
        let capability: GitCodemapRootCapability
        let namespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority
        let catalogGeneration: UInt64
    }

    private struct StoredReady {
        let binding: WorkspaceCodemapArtifactBinding
        let leaseOwner: WorkspaceCodemapSharedArtifactLease
        let source: WorkspaceCodemapLiveOverlaySource
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
    }

    private struct Shadow {
        let reason: WorkspaceCodemapLiveOverlayInvalidationReason
        var accessOrdinal: UInt64
    }

    private struct RootState {
        var registration: Registration
        var authorityIsCurrent: Bool
        var manifest: CodeMapRootManifestSnapshot?
        var manifestInvalidationGeneration: UInt64
        var manifestAdoptedInvalidationGeneration: UInt64?
        var cleanByRelativePath: [String: StoredReady]
        var liveByFileID: [UUID: LiveEntry]
        var liveFileIDByRelativePath: [String: UUID]
        var shadows: [String: Shadow]
        var contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    }

    private enum AccessLocation {
        case clean(rootEpoch: WorkspaceCodemapRootEpoch, path: String)
        case live(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID)
        case unavailable(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID)
        case shadow(rootEpoch: WorkspaceCodemapRootEpoch, path: String)
    }

    private struct AccessItem {
        let location: AccessLocation
        let ordinal: UInt64
        let rootEpoch: WorkspaceCodemapRootEpoch
        let path: String
        let fileID: UUID?
    }

    private let policy: WorkspaceCodemapLiveOverlayPolicy
    private let manifestRecordEqualityTraversal: @Sendable () -> Void
    private var roots: [WorkspaceCodemapRootEpoch: RootState] = [:]
    private var admissionReservations: [WorkspaceCodemapLiveDemandReservation] = []
    private var activeAdmissionReservationID: UUID?
    private var nextAccessOrdinal: UInt64
    private var evictionCount: UInt64
    private var busyDropCount: UInt64
    private var staleCompletionDropCount: UInt64

    init(
        policy: WorkspaceCodemapLiveOverlayPolicy = .default,
        initialAccessOrdinal: UInt64 = 1,
        initialCounterValue: UInt64 = 0,
        manifestRecordEqualityTraversal: @escaping @Sendable () -> Void = {}
    ) {
        self.policy = policy
        self.manifestRecordEqualityTraversal = manifestRecordEqualityTraversal
        nextAccessOrdinal = initialAccessOrdinal
        evictionCount = initialCounterValue
        busyDropCount = initialCounterValue
        staleCompletionDropCount = initialCounterValue
    }

    func register(
        capability state: WorkspaceCodemapGitCapabilityState,
        namespace: CodeMapRootManifestNamespace,
        catalogGeneration: UInt64
    ) -> WorkspaceCodemapLiveOverlayRegistrationDisposition {
        guard case let .eligible(capability) = state else {
            return .rejected(.capabilityUnavailable)
        }
        guard catalogGeneration > 0 else {
            return .rejected(.catalogGenerationInvalid)
        }
        guard namespace.isCurrent else {
            return .rejected(.staleNamespace)
        }
        let expectedNamespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority
        do {
            expectedNamespace = try CodeMapRootManifestNamespace(
                capability: capability,
                pipelineIdentity: namespace.pipelineIdentity
            )
            authority = try CodeMapRootManifestAuthority(
                namespace: namespace,
                token: capability.repositoryAuthority
            )
        } catch {
            return .rejected(.authorityMismatch)
        }
        guard expectedNamespace == namespace else {
            return .rejected(.namespaceMismatch)
        }

        let registration = Registration(
            capability: capability,
            namespace: namespace,
            authority: authority,
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
            manifest: nil,
            manifestInvalidationGeneration: 1,
            manifestAdoptedInvalidationGeneration: nil,
            cleanByRelativePath: [:],
            liveByFileID: [:],
            liveFileIDByRelativePath: [:],
            shadows: [:],
            contributionGeneration: .init(rawValue: 1)
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
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> WorkspaceCodemapLiveManifestAdoptionTicket? {
        guard let root = roots[rootEpoch], root.authorityIsCurrent else { return nil }
        return WorkspaceCodemapLiveManifestAdoptionTicket(
            rootEpoch: rootEpoch,
            catalogGeneration: root.registration.catalogGeneration,
            repositoryAuthority: root.registration.capability.repositoryAuthority,
            invalidationGeneration: root.manifestInvalidationGeneration
        )
    }

    func adoptManifest(
        ticket: WorkspaceCodemapLiveManifestAdoptionTicket,
        snapshot: CodeMapRootManifestSnapshot,
        readyEntries: [WorkspaceCodemapLiveManifestAdoptionEntry]
    ) -> WorkspaceCodemapLiveManifestAdoptionDisposition {
        let rootEpoch = ticket.rootEpoch
        guard var root = roots[rootEpoch] else {
            return .rejected(.rootNotRegistered)
        }
        guard root.authorityIsCurrent else {
            return .rejected(.rootAuthorityInvalid)
        }
        guard ticket.catalogGeneration == root.registration.catalogGeneration,
              ticket.repositoryAuthority == root.registration.capability.repositoryAuthority,
              ticket.invalidationGeneration == root.manifestInvalidationGeneration
        else {
            return .rejected(.staleLoad)
        }
        guard snapshot.namespace == root.registration.namespace else {
            return .rejected(.namespaceMismatch)
        }
        guard snapshot.authority == root.registration.authority else {
            return .rejected(.authorityMismatch)
        }
        if let currentManifest = root.manifest {
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

        let usage = usage(excludingCleanEntriesFor: rootEpoch)
        let projectedRootEntryCount = addingSaturating(readyEntries.count, root.liveByFileID.count)
        let projectedProcessEntryCount = addingSaturating(
            subtractingFloor(usage.entryCount, root.shadows.count),
            readyEntries.count
        )
        guard projectedRootEntryCount <= policy.maximumEntryCountPerRoot,
              projectedProcessEntryCount <= policy.maximumEntryCount
        else {
            recordBusyDrop()
            return .busy(.entryLimit)
        }
        guard addingSaturating(readyEntries.count, liveLeaseCount(root)) <=
            policy.maximumLeaseCountPerRoot,
            addingSaturating(usage.leaseCount, readyEntries.count) <= policy.maximumLeaseCount
        else {
            recordBusyDrop()
            return .busy(.leaseLimit)
        }
        var byteCount: UInt64 = 0
        for entry in readyEntries {
            byteCount = addingSaturating(byteCount, entry.lease.handle.estimatedResidentByteCount)
            guard addingSaturating(liveArtifactBytes(root), byteCount) <=
                policy.maximumArtifactByteCountPerRoot,
                addingSaturating(usage.artifactByteCount, byteCount) <= policy.maximumArtifactByteCount
            else {
                recordBusyDrop()
                return .busy(.artifactByteLimit)
            }
        }

        if let currentManifest = root.manifest,
           snapshot.manifestGeneration == currentManifest.manifestGeneration
        {
            guard manifestContentsEqual(snapshot, currentManifest) else {
                return .rejected(.manifestGenerationConflict)
            }
            if root.manifestAdoptedInvalidationGeneration == root.manifestInvalidationGeneration {
                return .exactDuplicate(readyEntryCount: root.cleanByRelativePath.count)
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
        root.manifest = snapshot
        root.manifestAdoptedInvalidationGeneration = root.manifestInvalidationGeneration
        root.cleanByRelativePath = Dictionary(uniqueKeysWithValues: validatedEntries.map { relativePath, entry in
            (relativePath, StoredReady(
                binding: entry.binding,
                leaseOwner: WorkspaceCodemapSharedArtifactLease(entry.lease),
                source: .cleanManifest,
                accessOrdinal: takeAccessOrdinal()
            ))
        })
        root.shadows.removeAll()
        advanceContributionGeneration(&root)
        roots[rootEpoch] = root
        return .adopted(readyEntryCount: validatedEntries.count)
    }

    func beginDemand(
        owner: WorkspaceCodemapLiveDemandOwner,
        token: WorkspaceCodemapArtifactRequestToken
    ) -> WorkspaceCodemapLiveDemandDisposition {
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
        let removesShadow = root.shadows[relativePath] != nil
        let rootProjectedWaiters = addingSaturating(
            subtractingFloor(rootWaiterCount(root), removedWaiters),
            1
        )
        let processProjectedWaiters = addingSaturating(
            subtractingFloor(usage().waiterCount, removedWaiters),
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
            let shadowEntries = removesShadow && currentRoot.shadows[relativePath] != nil ? 1 : 0
            return (
                addingSaturating(
                    subtractingFloor(
                        subtractingFloor(entryCount(currentRoot), removedEntries),
                        shadowEntries
                    ),
                    1
                ),
                addingSaturating(
                    subtractingFloor(
                        subtractingFloor(usage().entryCount, removedEntries),
                        shadowEntries
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
        root.shadows.removeValue(forKey: relativePath)
        advanceContributionGeneration(&root)
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
            root.shadows[path] = Shadow(reason: .modified, accessOrdinal: takeAccessOrdinal())
            advanceManifestInvalidationGeneration(&root)
            advanceContributionGeneration(&root)
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
        var cancellationCount = subtractingFloor(
            reservationCountBefore,
            admissionReservations.count
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
                    root.shadows[path] = Shadow(reason: .modified, accessOrdinal: takeAccessOrdinal())
                    advanceManifestInvalidationGeneration(&root)
                } else {
                    root.liveByFileID[fileID] = .pending(pending)
                }
            }
            if changed {
                advanceContributionGeneration(&root)
                roots[rootEpoch] = root
            }
        }
        return cancellationCount
    }

    func acceptCompletion(
        ticket: WorkspaceCodemapLiveDemandTicket,
        completion: WorkspaceCodemapArtifactCompletion,
        lease: CodeMapArtifactLease
    ) -> WorkspaceCodemapLiveCompletionDisposition {
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
               ready.completion == completion,
               artifactMatches(lease.handle, completion: completion)
            {
                ready.accessOrdinal = takeAccessOrdinal()
                root.liveByFileID[ticket.token.identity.fileID] = .ready(ready)
                roots[rootEpoch] = root
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
            accessOrdinal: takeAccessOrdinal()
        )
        root.liveByFileID[ticket.token.identity.fileID] = .ready(ready)
        advanceContributionGeneration(&root)
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
        advanceContributionGeneration(&root)
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
            let removedClean = root.cleanByRelativePath.removeValue(forKey: relativePath) != nil
            let liveFileID = root.liveFileIDByRelativePath[relativePath]
            if let liveFileID {
                removeLiveEntry(fileID: liveFileID, from: &root)
            }
            let manifestContainsPath = root.manifest?.records.contains(where: {
                loadedRootRelativePath(
                    repositoryRelativePath: $0.repositoryRelativePath,
                    prefix: root.registration.capability.repositoryRelativeLoadedRootPrefix
                ) == relativePath
            }) == true
            if removedClean || liveFileID != nil || manifestContainsPath {
                invalidated = addingSaturating(invalidated, 1)
                root.shadows[relativePath] = Shadow(reason: reason, accessOrdinal: takeAccessOrdinal())
            }
        }
        if observedValidPath {
            advanceManifestInvalidationGeneration(&root)
            advanceContributionGeneration(&root)
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
        advanceManifestInvalidationGeneration(&root)
        root.manifest = nil
        root.manifestAdoptedInvalidationGeneration = nil
        root.cleanByRelativePath.removeAll()
        root.liveByFileID.removeAll()
        root.liveFileIDByRelativePath.removeAll()
        root.shadows.removeAll()
        advanceContributionGeneration(&root)
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
            manifestGeneration: root.manifest?.manifestGeneration,
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
            admissionReservationCount: admissionReservations.count,
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
        for (relativePath, shadow) in root.shadows {
            result.append(WorkspaceCodemapLiveEntrySnapshot(
                fileID: nil,
                standardizedRelativePath: relativePath,
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
        var result = root.cleanByRelativePath.compactMap { path, entry in
            root.liveFileIDByRelativePath[path] == nil && root.shadows[path] == nil ? entry : nil
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

    private func touchVisibleReadyEntries(_ root: inout RootState) {
        let cleanPaths = root.cleanByRelativePath.keys.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        for path in cleanPaths
            where root.liveFileIDByRelativePath[path] == nil && root.shadows[path] == nil
        {
            guard var ready = root.cleanByRelativePath[path] else { continue }
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

    private func usage(excludingCleanEntriesFor rootEpoch: WorkspaceCodemapRootEpoch? = nil) -> (
        entryCount: Int,
        waiterCount: Int,
        leaseCount: Int,
        artifactByteCount: UInt64
    ) {
        roots.reduce(into: (0, 0, 0, UInt64(0))) { partial, element in
            let accounting = rootAccounting(rootEpoch: element.key, root: element.value)
            let cleanCount = element.key == rootEpoch ? element.value.cleanByRelativePath.count : 0
            let cleanBytes: UInt64 = element.key == rootEpoch
                ? element.value.cleanByRelativePath.values.reduce(0) {
                    addingSaturating($0, $1.leaseOwner.lease.handle.estimatedResidentByteCount)
                }
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
        admissionReservations.reduce(0) {
            let matches = $1.token.identity.rootID == rootEpoch.rootID &&
                $1.token.identity.rootLifetimeID == rootEpoch.rootLifetimeID
            return addingSaturating($0, matches ? 1 : 0)
        }
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
            let isShadow: Bool
            let isNegative: Bool
            let accessOrdinal: UInt64
        }
        var candidates: [Candidate] = []
        for (rootEpoch, root) in roots where requiredRootEpoch == nil || requiredRootEpoch == rootEpoch {
            for (path, shadow) in root.shadows {
                candidates.append(Candidate(
                    rootEpoch: rootEpoch,
                    relativePath: path,
                    fileID: nil,
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
                        isShadow: false,
                        isNegative: false,
                        accessOrdinal: ready.accessOrdinal
                    ))
                case let .unavailable(ticket, _, accessOrdinal):
                    candidates.append(Candidate(
                        rootEpoch: rootEpoch,
                        relativePath: ticket.token.identity.standardizedRelativePath,
                        fileID: fileID,
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

        if candidate.isShadow {
            root.shadows.removeValue(forKey: candidate.relativePath)
            root.cleanByRelativePath.removeValue(forKey: candidate.relativePath)
        } else if let fileID = candidate.fileID {
            removeLiveEntry(fileID: fileID, from: &root)
            root.cleanByRelativePath.removeValue(forKey: candidate.relativePath)
        } else {
            root.cleanByRelativePath.removeValue(forKey: candidate.relativePath)
        }
        if candidate.isNegative {
            advanceManifestInvalidationGeneration(&root)
        }
        advanceContributionGeneration(&root)
        roots[candidate.rootEpoch] = root
        evictionCount = addingSaturating(evictionCount, 1)
        return true
    }

    private func advanceContributionGeneration(_ root: inout RootState) {
        root.contributionGeneration = .init(
            rawValue: addingSaturating(root.contributionGeneration.rawValue, 1)
        )
    }

    private func advanceManifestInvalidationGeneration(_ root: inout RootState) {
        root.manifestInvalidationGeneration = addingSaturating(
            root.manifestInvalidationGeneration,
            1
        )
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
            for (path, shadow) in root.shadows {
                items.append(AccessItem(
                    location: .shadow(rootEpoch: rootEpoch, path: path),
                    ordinal: shadow.accessOrdinal,
                    rootEpoch: rootEpoch,
                    path: path,
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
            case let .shadow(_, path):
                if var shadow = root.shadows[path] {
                    shadow.accessOrdinal = ordinal
                    root.shadows[path] = shadow
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
        guard rootCount < policy.maximumAdmissionReservationCountPerRoot,
              admissionReservations.count < policy.maximumAdmissionReservationCount
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
        advanceContributionGeneration(&root)
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
            let next = addingSaturating(total, bytes)
            guard next <= limit else { return false }
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
