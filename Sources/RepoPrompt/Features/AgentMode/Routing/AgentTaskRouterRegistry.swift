import Foundation

actor AgentTaskRouterRegistry {
    private let registrationsByID: [AgentTaskRouterBackendID: AgentTaskRouterBackendRegistration]
    private let orderedIDs: [AgentTaskRouterBackendID]

    init(registrations: [AgentTaskRouterBackendRegistration]) throws {
        var byID: [AgentTaskRouterBackendID: AgentTaskRouterBackendRegistration] = [:]
        for registration in registrations {
            guard !registration.id.rawValue.isEmpty else { throw AgentTaskRouterRegistryError.invalidBackendID }
            guard byID[registration.id] == nil else {
                throw AgentTaskRouterRegistryError.duplicateBackendID(registration.id)
            }
            byID[registration.id] = registration
        }
        registrationsByID = byID
        orderedIDs = byID.keys.sorted()
    }

    func registrations() -> [AgentTaskRouterBackendRegistration] {
        orderedIDs.compactMap { registrationsByID[$0] }
    }

    func registration(for id: AgentTaskRouterBackendID) -> AgentTaskRouterBackendRegistration? {
        registrationsByID[id]
    }
}
