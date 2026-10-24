import Combine
import Foundation

@MainActor
final class RouterOpenAIServiceExpansionState: ObservableObject {
    @Published private(set) var isExpanded = false

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
    }
}

@MainActor
final class RouterSecretDraftState: ObservableObject {
    @Published private(set) var value = ""
    private(set) var revision: UInt64 = 0
    private var isTracked = false

    var snapshot: RouterSettingsViewState.SecretDraftSnapshot {
        .init(value: value, revision: revision)
    }

    func setValue(_ value: String) {
        guard self.value != value else { return }
        revision &+= 1
        isTracked = true
        self.value = value
    }

    @discardableResult
    func clear(ifRevision revision: UInt64) -> Bool {
        guard self.revision == revision else { return false }
        self.revision &+= 1
        isTracked = false
        if !value.isEmpty {
            value = ""
        }
        return true
    }

    func clearIfTracked() {
        guard isTracked else { return }
        revision &+= 1
        isTracked = false
        if !value.isEmpty {
            value = ""
        }
    }
}

/// Window-local Router Settings UI state. This never persists or reads stored credentials.
@MainActor
final class RouterSettingsViewState: ObservableObject {
    struct SecretDraftSnapshot: Equatable {
        let value: String
        let revision: UInt64
    }

    struct ConfigureRequest: Equatable, Identifiable {
        let backendID: DecisionServiceID
        let token: UUID

        var id: UUID {
            token
        }
    }

    @Published private var nonOpenAIExpandedServiceIDs: Set<DecisionServiceID> = []
    @Published private(set) var expandedDisclosureIDs: Set<String> = []

    let openAIServiceExpansion = RouterOpenAIServiceExpansionState()

    var expandedServiceIDs: Set<DecisionServiceID> {
        var serviceIDs = nonOpenAIExpandedServiceIDs
        if openAIServiceExpansion.isExpanded {
            serviceIDs.insert(.openAIDecisions)
        }
        return serviceIDs
    }

    @Published private(set) var configureRequest: ConfigureRequest?

    private var secretDraftStatesByBackendID: [DecisionServiceID: RouterSecretDraftState] = [:]

    func secretDraftState(for backendID: DecisionServiceID) -> RouterSecretDraftState {
        if let state = secretDraftStatesByBackendID[backendID] {
            return state
        }
        let state = RouterSecretDraftState()
        secretDraftStatesByBackendID[backendID] = state
        return state
    }

    func secretDraft(for backendID: DecisionServiceID) -> String {
        secretDraftState(for: backendID).value
    }

    func secretDraftSnapshot(for backendID: DecisionServiceID) -> SecretDraftSnapshot {
        secretDraftState(for: backendID).snapshot
    }

    func setSecretDraft(_ value: String, for backendID: DecisionServiceID) {
        secretDraftState(for: backendID).setValue(value)
    }

    @discardableResult
    func clearSecretDraft(for backendID: DecisionServiceID, ifRevision revision: UInt64) -> Bool {
        secretDraftState(for: backendID).clear(ifRevision: revision)
    }

    func clearAllSecretDrafts() {
        for state in secretDraftStatesByBackendID.values {
            state.clearIfTracked()
        }
    }

    func isServiceExpanded(_ backendID: DecisionServiceID) -> Bool {
        if backendID == .openAIDecisions {
            return openAIServiceExpansion.isExpanded
        }
        return nonOpenAIExpandedServiceIDs.contains(backendID)
    }

    func setServiceExpanded(_ expanded: Bool, backendID: DecisionServiceID) {
        if backendID == .openAIDecisions {
            openAIServiceExpansion.setExpanded(expanded)
            return
        }
        if expanded {
            nonOpenAIExpandedServiceIDs.insert(backendID)
        } else {
            nonOpenAIExpandedServiceIDs.remove(backendID)
        }
    }

    func isDisclosureExpanded(_ disclosureID: String) -> Bool {
        expandedDisclosureIDs.contains(disclosureID)
    }

    func setDisclosureExpanded(_ expanded: Bool, disclosureID: String) {
        if expanded {
            expandedDisclosureIDs.insert(disclosureID)
        } else {
            expandedDisclosureIDs.remove(disclosureID)
        }
    }

    func requestConfigure(_ backendID: DecisionServiceID) {
        setServiceExpanded(true, backendID: backendID)
        configureRequest = .init(backendID: backendID, token: UUID())
    }
}
