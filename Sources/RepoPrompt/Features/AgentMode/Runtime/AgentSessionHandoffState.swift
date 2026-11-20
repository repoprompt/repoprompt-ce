import CryptoKit
import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// In-memory values only. Persisted session fields and dispatch authorities are unchanged.
struct AgentPendingHandoffState: Equatable {
    var payload: String?
    var createdAt: Date?
    var sourceItemID: UUID?
    /// True only for a freshly-created handoff tab. Keeps agent selection editable
    /// until the destination tab successfully sends its first real user turn.
    var defersProviderLockUntilSend: Bool = false
    var isStagedForSend: Bool = false
    /// Durable failure/preparation marker; ordinary send cleanup must never clear it.
    var executionLocationFailure: String?
    /// Nil retains the existing fork/resume-recovery delivery policy.
    var providerSwitchDelivery: AgentProviderSwitchDelivery?
    /// Captured by the existing physical fence; never persisted or reused by another dispatch.
    var providerSwitchDispatch: AgentProviderSwitchPhysicalDispatch?

    var hasPayload: Bool {
        guard let payload else { return false }
        return !payload.isEmpty
    }

    mutating func clearAfterSend() {
        payload = nil
        createdAt = nil
        sourceItemID = nil
        defersProviderLockUntilSend = false
        isStagedForSend = false
        providerSwitchDelivery = nil
        providerSwitchDispatch = nil
    }
}

struct AgentProviderSwitchPhysicalDispatch: Equatable {
    let dispatchID: AgentSessionLinkPromptDispatchID?
    let binding: AgentSessionRestorationBindingToken?
    let admission: AgentProviderSwitchAdmissionEvidence
    let acceptedInputID: UUID?
    let composerAttemptID: UUID?
    let autoWakeID: UUID?
    let stopFence: AgentRunStartStopFence
    /// Value identities only: never retains a task, session, controller, or terminal resource.
    let runOwnership: AgentRunOwnership?
    let runID: UUID?

    func bindingDispatch(_ id: AgentSessionLinkPromptDispatchID, runID: UUID) -> Self {
        .init(
            dispatchID: id,
            binding: binding,
            admission: admission,
            acceptedInputID: acceptedInputID,
            composerAttemptID: composerAttemptID,
            autoWakeID: autoWakeID,
            stopFence: stopFence,
            runOwnership: runOwnership,
            runID: runID
        )
    }

    func associatingRun(_ ownership: AgentRunOwnership) -> Self? {
        guard runOwnership == nil, runID == nil, dispatchID == nil,
              let binding,
              ownership.binding.tabID == binding.bindingIdentity.tabID,
              ownership.binding.persistentSessionID == binding.bindingIdentity.sessionID,
              ownership.binding.persistentBindingGeneration == binding.bindingIdentity.generation,
              ownership.binding.bindingTransitionGeneration == binding.bindingTransitionGeneration
        else { return nil }
        return .init(
            dispatchID: nil,
            binding: binding,
            admission: admission,
            acceptedInputID: acceptedInputID,
            composerAttemptID: composerAttemptID,
            autoWakeID: autoWakeID,
            stopFence: stopFence,
            runOwnership: ownership,
            runID: nil
        )
    }
}

/// Request-local composition evidence, not a persisted preview or a second admission owner.
struct AgentProviderSwitchSendPreparation {
    let command: AgentSessionRuntimeStore.Command
    let binding: AgentSessionRestorationBindingToken?
    private(set) var handoff: AgentPendingHandoffState
    let agent: AgentProviderKind
    let model: String
    let rawInput: String
    let augmentedInput: String
    let initialThreadInput: String
    let instructions: [String]
    let inputAlreadyIncludesSupplement: Bool
    let historyToolAllowed: Bool
    let computerUseArmed: Bool
    let catalogWindow: Int?
    let composerAttemptID: UUID?
    let autoWakeID: UUID?
    let stopFence: AgentRunStartStopFence
    var acceptedInputID: UUID?
    var taggedFileFailures: [AgentSessionProviderInputRuntime.ExplicitFileFailure] = []
    var inputSources: [AgentSessionProviderInputRuntime.WorkspaceSource] = []

    @MainActor
    func validateInputSources() async -> Bool {
        guard command.isCurrent, inputSources.allSatisfy({ $0.isCurrent() }) else { return false }
        for source in inputSources {
            guard await source.validate(), command.isCurrent, inputSources.allSatisfy({ $0.isCurrent() }) else { return false }
        }
        return true
    }

    @MainActor
    func accepting(_ itemID: UUID, session: AgentTabSession) -> Self {
        var copy = self
        copy.acceptedInputID = itemID
        if command.isCurrent, command.writer.session === session,
           session.currentRestorationBindingToken == binding, session.pendingHandoff == handoff
        {
            copy.handoff.providerSwitchDispatch = copy.physicalDispatch
            session.pendingHandoff.providerSwitchDispatch = copy.handoff.providerSwitchDispatch
        }
        return copy
    }

    @MainActor
    var physicalDispatch: AgentProviderSwitchPhysicalDispatch {
        .init(
            dispatchID: nil,
            binding: binding,
            admission: .init(self),
            acceptedInputID: acceptedInputID,
            composerAttemptID: composerAttemptID,
            autoWakeID: autoWakeID,
            stopFence: stopFence,
            runOwnership: nil,
            runID: nil
        )
    }
}

struct AgentProviderSwitchAdmissionEvidence: Equatable {
    let writerIdentity: AgentSessionRuntimeStore.WriterIdentity
    let agent: AgentProviderKind
    let model: String
    let catalogWindow: Int?
    let computerUseArmed: Bool
    let historyToolAllowed: Bool
    let inputAlreadyIncludesSupplement: Bool
    let instructionsDigest: SHA256.Digest

    @MainActor
    init(_ preparation: AgentProviderSwitchSendPreparation) {
        writerIdentity = preparation.command.writer.identity
        agent = preparation.agent
        model = preparation.model
        catalogWindow = preparation.catalogWindow
        computerUseArmed = preparation.computerUseArmed
        historyToolAllowed = preparation.historyToolAllowed
        inputAlreadyIncludesSupplement = preparation.inputAlreadyIncludesSupplement
        instructionsDigest = Self.digest(preparation.instructions)
    }

    static func digest(_ strings: [String]) -> SHA256.Digest {
        var hash = SHA256()
        for string in strings {
            hash.update(data: Data("\(string.utf8.count):".utf8))
            hash.update(data: Data(string.utf8))
        }
        return hash.finalize()
    }
}
