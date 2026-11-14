import Foundation
import RepoPromptDomainRuntime

/// Storage selected for a turn, not the window's workspace when the provider finishes.
struct AgentSessionAttachmentLocation: Equatable {
    let workspaceDirectory: URL
    let retainedRoot: URL?

    init(workspaceDirectory: URL, retainedRoot: URL?) {
        // URL's inferred directory flag can change when the first retention creates a folder.
        // These are directory capabilities even before they exist; freeze that representation
        // rather than treating creation of the same path as a storage-location change.
        self.workspaceDirectory = URL(fileURLWithPath: workspaceDirectory.standardizedFileURL.path, isDirectory: true)
        self.retainedRoot = retainedRoot.map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: true) }
    }
}

struct AgentSessionAttachmentPlacement {
    let location: AgentSessionAttachmentLocation
    let binding: AgentPersistentSessionBindingIdentity?
    /// The storage owner selected at reservation, not a replacement configuration at completion.
    let validateLocation: @MainActor (AgentTabSession) async -> Bool
    let requiresCurrentLocationBeforeIO: Bool
}

/// Owns provider consumption, retention and canonical-path repair independently of presentation.
/// File admission/deletion remains with AgentSessionDataService; this owner joins those operations
/// and fences their in-memory publication to the exact incarnation that requested them.
@MainActor
final class AgentSessionAttachmentRuntime {
    struct Configuration {
        let location: (AgentTabSession) -> AgentSessionAttachmentLocation?
        let locationIsCurrent: (AgentSessionAttachmentLocation, AgentTabSession) async -> Bool
        /// Legacy reservations already own their move destination, even after presentation
        /// changes. Canonical storage additionally requires a fresh authority read before IO.
        var requiresCurrentLocationBeforeIO = false

        static func canonical(
            location: @escaping (AgentTabSession) -> AgentSessionAttachmentLocation?
        ) -> Self {
            .init(location: location, locationIsCurrent: { captured, session in
                guard let current = location(session) else { return false }
                return current.retainedRoot == captured.retainedRoot
            })
        }
    }

    private weak var scope: AgentSessionRuntimeStore.Scope?
    var configuration: Configuration?
    var clearsConsumedFiles = true
    var limits: AgentSessionAttachmentStore.Limits = .standard
    var invalidatePreviews: (([String]) -> Void)?
    private struct Retention {
        let task: Task<Void, Never>
        let sessionID: UUID
        let sessionIdentity: ObjectIdentifier
        let attachments: [AgentFileAttachment]
    }

    private var retentionTasks: [UUID: Retention] = [:]
    var sweepProtection: (sessionIDs: Set<UUID>, temporaryPaths: Set<String>) {
        (
            Set(retentionTasks.values.map(\.sessionID)),
            Set(retentionTasks.values.flatMap(\.attachments).compactMap(AgentImageAttachmentAvailabilityResolver.path(for:)))
        )
    }

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    func makeRunHooks() -> AgentModeRunService.AttachmentLifecycleHooks {
        .init(
            reserveAttachmentsForTurn: { [self] attachments, session in
                reserveAttachmentsForTurn(attachments, session: session)
            },
            markAttachmentsConsumed: { [self] session, reservationID in
                markAttachmentsConsumed(for: session, reservationID: reservationID)
            },
            stageConsumedAttachmentFilesForDeferredCleanup: { [self] attachments, session in
                stageConsumedAttachmentFilesForDeferredCleanup(attachments, session: session)
            },
            consumeDeferredAttachmentCleanup: { [self] session, shouldDeleteFiles in
                consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: shouldDeleteFiles)
            },
            finalizeAttachmentsForTurn: { [self] session, reservationID, disposition in
                finalizeAttachmentsForTurn(for: session, reservationID: reservationID, disposition: disposition)
            }
        )
    }

    private func retainConsumedAttachmentFiles(_ attachments: [AgentFileAttachment], session: AgentTabSession) {
        guard clearsConsumedFiles, !attachments.isEmpty, let scope else { return }
        guard let placement = session.attachmentRetentionPlacement else {
            // Deferred cleanup can outlive the reservation. Preserve the managed-temp fallback;
            // the attachment store refuses paths outside this directory's managed root.
            if let location = configuration?.location(session) {
                clearTemporaryFiles(attachments, workspaceDirectory: location.workspaceDirectory)
            }
            return
        }
        let location = placement.location
        // An unbound first turn has not claimed a persisted identity yet. Qualify its same live
        // object at consumption; a reservation already bound to an identity never adopts another.
        let binding = placement.binding ?? session.persistentSessionBindingIdentity
        guard let sessionID = binding?.sessionID,
              let root = location.retainedRoot,
              let membership = scope.membership(of: session)
        else {
            clearTemporaryFiles(attachments, workspaceDirectory: location.workspaceDirectory)
            return
        }
        let store = AgentSessionAttachmentStore(rootURL: root, limits: limits)
        let restoration = session.currentRestorationBindingToken
        let token = UUID()
        let task = Task { @MainActor [self, scope, session] in
            defer {
                retentionTasks[token] = nil
                scope.noteSettlementChanged()
            }
            if placement.requiresCurrentLocationBeforeIO {
                guard await placement.validateLocation(session) else { return }
            }
            guard membership.isCurrent,
                  session.persistentSessionBindingIdentity == binding,
                  session.currentRestorationBindingToken == restoration
            else { return }
            let result = await AgentSessionDataService.shared.retainConsumedAttachments(
                attachments, sessionID: sessionID, store: store, workspaceDirectory: location.workspaceDirectory
            )
            let movedPaths = attachments.filter { result.retained[$0.id] != nil }
                .compactMap(AgentImageAttachmentAvailabilityResolver.path(for:))
            invalidatePreviews?(movedPaths + result.evictedPaths)
            guard await placement.validateLocation(session),
                  membership.isCurrent,
                  session.persistentSessionBindingIdentity == binding,
                  session.currentRestorationBindingToken == restoration
            else { return }
            applyRetainedAttachments(result.retained, to: session, sessionID: sessionID)
        }
        retentionTasks[token] = Retention(task: task, sessionID: sessionID, sessionIdentity: ObjectIdentifier(session), attachments: attachments)
    }

    private func clearTemporaryFiles(_ attachments: [AgentFileAttachment], workspaceDirectory: URL) {
        AgentAttachmentStore().clearConsumedLocalFiles(attachments, workspaceDirectory: workspaceDirectory)
        invalidatePreviews?(attachments.compactMap(AgentImageAttachmentAvailabilityResolver.path(for:)))
    }

    func repairRetainedAttachmentPathsAfterHydration(_ session: AgentTabSession, sessionID: UUID) {
        guard clearsConsumedFiles, let scope,
              let membership = scope.membership(of: session),
              session.activeAgentSessionID == sessionID,
              let configuration, let location = configuration.location(session), let root = location.retainedRoot
        else { return }
        let attachments = session.items.filter { $0.kind == .user }.flatMap(\.attachments)
            + session.transcript.turns.compactMap(\.request).flatMap(\.attachments)
        guard attachments.contains(where: { if case .localFile = $0.source { true } else { false } }) else { return }
        let store = AgentSessionAttachmentStore(rootURL: root, limits: limits)
        let binding = session.persistentSessionBindingIdentity
        let restoration = session.currentRestorationBindingToken
        let token = UUID()
        let task = Task { @MainActor [self, scope, session] in
            defer {
                retentionTasks[token] = nil
                scope.noteSettlementChanged()
            }
            if configuration.requiresCurrentLocationBeforeIO {
                guard await configuration.locationIsCurrent(location, session) else { return }
            }
            guard membership.isCurrent,
                  session.persistentSessionBindingIdentity == binding,
                  session.currentRestorationBindingToken == restoration
            else { return }
            let repaired = await Task.detached(priority: .utility) {
                store.repairMissingPaths(attachments, sessionID: sessionID)
            }.value
            guard await configuration.locationIsCurrent(location, session),
                  membership.isCurrent,
                  session.persistentSessionBindingIdentity == binding,
                  session.currentRestorationBindingToken == restoration
            else { return }
            applyRetainedAttachments(repaired, to: session, sessionID: sessionID)
        }
        retentionTasks[token] = Retention(task: task, sessionID: sessionID, sessionIdentity: ObjectIdentifier(session), attachments: attachments)
    }

    var hasPendingRetention: Bool {
        !retentionTasks.isEmpty
    }

    func hasPendingRetention(for session: AgentTabSession) -> Bool {
        retentionTasks.values.contains { $0.sessionIdentity == ObjectIdentifier(session) }
    }

    /// Joins admitted moves and hydration path repairs, including their in-memory publication.
    /// Cancellation of a waiter is not completion of the admitted disk operation. A completed
    /// join is not durability: repaired paths remain dirty until a subsequent acknowledged save.
    func waitForRetention(for session: AgentTabSession? = nil) async {
        let identity = session.map(ObjectIdentifier.init)
        while true {
            let pending = retentionTasks.values.filter { identity == nil || $0.sessionIdentity == identity }
            guard !pending.isEmpty else { return }
            for operation in pending {
                await operation.task.value
            }
        }
    }

    /// Repairs canonical requests and their working copies without replacing row-owned metadata.
    func applyRetainedAttachments(_ retained: [UUID: AgentFileAttachment], to session: AgentTabSession, sessionID: UUID) {
        guard !retained.isEmpty, session.activeAgentSessionID == sessionID,
              scope?.sessions[session.tabID] === session
        else { return }
        func repaired(_ attachments: [AgentFileAttachment]) -> [AgentFileAttachment] {
            attachments.map { attachment in
                guard let kept = retained[attachment.id] else { return attachment }
                return AgentFileAttachment(
                    id: attachment.id,
                    source: kept.source,
                    title: attachment.title,
                    createdAt: attachment.createdAt,
                    kind: attachment.kind,
                    fileName: attachment.fileName,
                    byteCount: attachment.byteCount
                )
            }
        }

        let canonicalRequestsChanged = session.transcript.turns.contains { turn in
            guard let request = turn.request else { return false }
            return repaired(request.attachments) != request.attachments
        }
        let workingRowsChanged = session.items.contains { item in
            item.kind == .user && repaired(item.attachments) != item.attachments
        }
        guard workingRowsChanged || canonicalRequestsChanged else { return }

        session.mutateItemsBatch(touchActivity: false) { items in
            for index in items.indices where items[index].kind == .user {
                items[index].attachments = repaired(items[index].attachments)
            }
        }
        if !AgentSessionTranscriptRefreshRuntime.canReuseDerivedTranscriptForSave(
            for: session,
            projectionProtection: AgentSessionTranscriptRefreshRuntime.transcriptProjectionProtection(for: session)
        ) {
            // Drain pending working-row mutations before committing canonical-only repairs.
            AgentSessionTranscriptRefreshRuntime.refreshDerivedTranscriptState(for: session)
        }
        var transcript = session.transcript
        for index in transcript.turns.indices {
            guard var request = transcript.turns[index].request else { continue }
            request.attachments = repaired(request.attachments)
            transcript.turns[index].request = request
        }
        if transcript != session.transcript {
            AgentSessionTranscriptRefreshRuntime.applyTranscriptPresentation(transcript, to: session)
        }
        session.isDirty = true
        scope?.persistence.scheduleSave(for: session)
        scope?.presentation.makeRunHooks().requestUIRefresh(session, false)
    }

    @discardableResult
    func reserveAttachmentsForTurn(_ attachments: [AgentFileAttachment], session: AgentTabSession) -> UUID? {
        guard !attachments.isEmpty else {
            session.attachmentTurnState = .idle
            return nil
        }
        let reservationID = UUID()
        session.attachmentTurnState = .reserved(reservationID: reservationID, attachments: attachments)
        session.attachmentRetentionPlacement = configuration.flatMap { configuration in
            configuration.location(session).map { location in
                AgentSessionAttachmentPlacement(
                    location: location, binding: session.persistentSessionBindingIdentity,
                    validateLocation: { await configuration.locationIsCurrent(location, $0) },
                    requiresCurrentLocationBeforeIO: configuration.requiresCurrentLocationBeforeIO
                )
            }
        }
        return reservationID
    }

    func markAttachmentsConsumed(for session: AgentTabSession, reservationID: UUID?) {
        switch session.attachmentTurnState {
        case .idle:
            return
        case let .reserved(storedID, attachments):
            if let reservationID, reservationID != storedID {
                return
            }
            session.attachmentTurnState = .consumed(reservationID: storedID, attachments: attachments)
        case let .consumed(storedID, _):
            if let reservationID, reservationID != storedID {
                return
            }
            return
        }
    }

    func stageConsumedAttachmentFilesForDeferredCleanup(_ attachments: [AgentFileAttachment], session: AgentTabSession) {
        guard clearsConsumedFiles else { return }
        guard !attachments.isEmpty else { return }
        if session.attachmentsPendingProviderConsumptionCleanup.isEmpty {
            session.attachmentsPendingProviderConsumptionCleanup = attachments
            return
        }
        let existingIDs = Set(session.attachmentsPendingProviderConsumptionCleanup.map(\.id))
        let uniqueNewAttachments = attachments.filter { !existingIDs.contains($0.id) }
        session.attachmentsPendingProviderConsumptionCleanup.append(contentsOf: uniqueNewAttachments)
    }

    func consumeDeferredAttachmentCleanup(for session: AgentTabSession, shouldDeleteFiles: Bool) {
        let attachments = session.attachmentsPendingProviderConsumptionCleanup
        session.attachmentsPendingProviderConsumptionCleanup.removeAll()
        guard shouldDeleteFiles else { return }
        retainConsumedAttachmentFiles(attachments, session: session)
    }

    func finalizeAttachmentsForTurn(
        for session: AgentTabSession,
        reservationID: UUID? = nil,
        disposition: DomainAgentRunAttachmentTurnDisposition
    ) {
        let attachments: [AgentFileAttachment]
        switch session.attachmentTurnState {
        case .idle:
            if disposition == .deleteFiles {
                consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: true)
            } else {
                consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: false)
            }
            session.attachmentRetentionPlacement = nil
            return
        case let .reserved(storedID, storedAttachments),
             let .consumed(storedID, storedAttachments):
            if let reservationID, reservationID != storedID {
                return
            }
            attachments = storedAttachments
        }

        switch disposition {
        case .restoreToPending:
            let existingIDs = Set(session.pendingFileAttachments.map(\.id))
            let unique = attachments.filter { !existingIDs.contains($0.id) }
            if !unique.isEmpty {
                session.pendingFileAttachments = unique + session.pendingFileAttachments
                session.isDirty = true
            }
            consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: false)
        case .deleteFiles:
            let hadDeferred = !session.attachmentsPendingProviderConsumptionCleanup.isEmpty
            consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: true)
            if !hadDeferred {
                retainConsumedAttachmentFiles(attachments, session: session)
            }
        case .keepFiles:
            consumeDeferredAttachmentCleanup(for: session, shouldDeleteFiles: false)
        }

        session.attachmentTurnState = .idle
        session.attachmentRetentionPlacement = nil
        session.isDirty = true
        scope?.persistence.scheduleSave(for: session)
    }
}
