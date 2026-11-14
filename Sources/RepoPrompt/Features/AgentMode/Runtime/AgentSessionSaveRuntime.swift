import Foundation
import RepoPromptDomainRuntime

/// Configured creation continues to use AgentTabSession's existing readiness authority.
/// This value identifies which acknowledgment is permitted, never a second creation state.
enum AgentSessionCreationSave {
    case configured(AgentSessionCreationHandle)
    case recovery(AgentSessionCreationHandle)

    var handle: AgentSessionCreationHandle {
        switch self { case let .configured(handle), let .recovery(handle): handle }
    }
}

/// Owns the prepared payload and its durable acknowledgment. The caller supplies storage
/// placement currency and current display metadata; no provider coordinator or UI object is
/// needed to build, write, validate configuration, or acknowledge a configured first save.
@MainActor
enum AgentSessionSaveRuntime {
    struct PreparationFailure: LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    struct PreparedWrite {
        fileprivate let payload: AgentSession
        fileprivate let creation: AgentSessionCreationSave?
        fileprivate let configurationStamp: Data?
        fileprivate let sessionIdentity: ObjectIdentifier
        fileprivate let binding: AgentSessionRestorationBindingToken
        fileprivate let sourceItemsRevision: Int
        fileprivate let persistenceMutationGeneration: UInt64
        fileprivate let saveRequestGeneration: UInt64
    }

    struct Receipt {
        /// Exact command/query incarnation that earned this durable acknowledgement.
        /// Kept even after retirement so consumers cannot credit a successor writer.
        let writerIdentity: AgentSessionRuntimeStore.WriterIdentity
        let payload: AgentSession
        let binding: AgentSessionRestorationBindingToken
        let acknowledgedCreation: Bool
    }

    enum Outcome {
        case committed(Receipt)
        case deferred(String, requestFreshSave: Bool)
    }

    static func prepare(
        payload: AgentSession, session: AgentTabSession,
        creation: AgentSessionCreationSave?
    ) throws -> PreparedWrite {
        guard let binding = session.currentRestorationBindingToken,
              payload.id == binding.bindingIdentity.sessionID,
              payload.composeTabID == session.tabID,
              payload.workspaceID == binding.bindingIdentity.workspaceID,
              payload.workspaceID != nil
        else { throw PreparationFailure(message: "The payload does not match the session's exact storage binding.") }
        let stamp: Data?
        switch creation {
        case let .configured(handle):
            let candidate = try AgentSessionPayloadBuilder.creationConfigurationStamp(for: payload)
            guard session.markCreationReady(handle, configurationStamp: candidate) else {
                throw PreparationFailure(message: "Initial session configuration changed after it was prepared. Create a new session instead of retrying this save.")
            }
            stamp = candidate
        case .recovery:
            guard payload.pendingHandoffExecutionLocationFailure != nil else {
                throw PreparationFailure(message: "An incomplete session can only save an explicitly blocked recovery payload.")
            }
            stamp = nil
        case nil:
            stamp = nil
        }
        return PreparedWrite(
            payload: payload, creation: creation, configurationStamp: stamp,
            sessionIdentity: ObjectIdentifier(session), binding: binding,
            sourceItemsRevision: session.sourceItemsRevision,
            persistenceMutationGeneration: session.persistenceMutationGeneration,
            saveRequestGeneration: session.saveRequestGeneration
        )
    }

    static func commit(
        _ prepared: PreparedWrite,
        workspace: WorkspaceModel,
        canonicalItemCount: Int,
        writer: AgentSessionRuntimeStore.Writer,
        token: AgentSessionSaveCommitToken,
        storageIsCurrent: () -> Bool,
        currentName: () -> String,
        observingPhase: ((AgentSessionRequiredSavePhase) -> Void)? = nil,
        saver: AgentSessionPayloadWriter.Saver
    ) async throws -> Outcome {
        let session = writer.session
        guard prepared.sessionIdentity == ObjectIdentifier(session),
              prepared.binding == writer.restoration,
              prepared.sourceItemsRevision == token.sourceItemsRevision,
              prepared.persistenceMutationGeneration == token.persistenceMutationGeneration,
              prepared.saveRequestGeneration == token.saveRequestGeneration
        else {
            return .deferred("The prepared payload no longer matches the session's write revision.", requestFreshSave: true)
        }
        var payload = prepared.payload
        let outcome = try await AgentSessionPayloadWriter.write(
            payload, workspace: workspace, canonicalItemCount: canonicalItemCount,
            writer: writer, token: token, creationHandle: prepared.creation?.handle,
            storageIsCurrent: storageIsCurrent, observingPhase: observingPhase, saver: saver
        )
        switch outcome {
        case .rejectedBeforeWrite:
            return .deferred("The session writer or its storage location changed before persistence could commit.", requestFreshSave: true)
        case .supersededAfterWrite:
            return .deferred("The session writer or its storage location changed while persistence was committing.", requestFreshSave: true)
        case let .written(fileURL):
            payload.fileURL = fileURL
        }
        var acknowledgedCreation = false
        if case let .configured(handle) = prepared.creation, let stamp = prepared.configurationStamp {
            var current = payload
            AgentSessionPayloadBuilder.refreshCreationConfiguration(from: session, name: currentName(), payload: &current)
            guard try AgentSessionPayloadBuilder.creationConfigurationStamp(for: current) == stamp,
                  session.acknowledgeConfiguredCreationSave(handle, configurationStamp: stamp)
            else {
                return .deferred("The prepared session configuration changed while its initial payload was saving.", requestFreshSave: false)
            }
            acknowledgedCreation = true
        }
        let binding = AgentSessionRestorationBindingToken(
            bindingIdentity: token.binding,
            bindingTransitionGeneration: token.bindingTransitionGeneration
        )
        guard session.currentRestorationBindingToken == binding else {
            return .deferred("The session binding changed after persistence committed.", requestFreshSave: true)
        }
        session.isDirty = false
        session.lastUserMessageAt = payload.lastUserMessageAt
        if acknowledgedCreation {
            // Like hydration, the configured durable acknowledgment earns readiness for
            // this payload. Renew after clearing dirty state so projection compares with
            // the clean saved payload, without requiring a UI lookup.
            writer.scope.installedInteractions?.adoptReadyApprovalPayload(for: session)
        }
        // The caller can publish index/presentation effects before reporting the terminal
        // durable phase. The receipt is exact; a returned file URL by itself is insufficient.
        return .committed(Receipt(writerIdentity: writer.identity, payload: payload, binding: binding, acknowledgedCreation: acknowledgedCreation))
    }
}
