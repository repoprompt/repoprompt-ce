import Foundation

struct DecisionServiceCapabilities: Equatable {
    struct FiniteChoice: Equatable {
        let minimumChoices: Int
        let maximumChoices: Int
        let maximumContextBytes: Int
        let maximumInstructionsBytes: Int
        let maximumChoiceDescriptionBytes: Int
        let maximumAggregateBytes: Int
    }

    struct Evidence: Equatable {
        let confidence: Bool
        let probabilityDistribution: Bool
        let usage: Bool
    }

    enum ContextKind: Hashable { case text }

    let contextKinds: Set<ContextKind>
    let finiteChoice: FiniteChoice
    let evidence: Evidence

    func supports(_ requirement: DecisionCapabilityRequirement, request: FiniteChoiceDecisionRequest) -> Bool {
        guard contextKinds.contains(requirement.contextKind),
              !requirement.requiresConfidence || evidence.confidence,
              !requirement.requiresProbabilities || evidence.probabilityDistribution,
              !requirement.requiresUsage || evidence.usage
        else { return false }
        let count = request.question.choices.count
        return count >= finiteChoice.minimumChoices
            && count <= finiteChoice.maximumChoices
            && request.textContext.utf8.count <= finiteChoice.maximumContextBytes
            && request.question.instructions.utf8.count <= finiteChoice.maximumInstructionsBytes
            && request.question.choices.allSatisfy {
                $0.description.utf8.count <= finiteChoice.maximumChoiceDescriptionBytes
            }
            && request.aggregateUTF8Bytes <= finiteChoice.maximumAggregateBytes
    }

    var isValid: Bool {
        contextKinds.contains(.text)
            && finiteChoice.minimumChoices >= 2
            && finiteChoice.maximumChoices >= finiteChoice.minimumChoices
            && finiteChoice.maximumContextBytes > 0
            && finiteChoice.maximumInstructionsBytes > 0
            && finiteChoice.maximumChoiceDescriptionBytes > 0
            && finiteChoice.maximumAggregateBytes > 0
    }
}

struct DecisionCapabilityRequirement: Equatable {
    let contextKind: DecisionServiceCapabilities.ContextKind
    let requiresConfidence: Bool
    let requiresProbabilities: Bool
    let requiresUsage: Bool

    static let textFiniteChoice = Self(
        contextKind: .text,
        requiresConfidence: false,
        requiresProbabilities: false,
        requiresUsage: false
    )
}

extension FiniteChoiceDecisionRequest {
    var aggregateUTF8Bytes: Int {
        textContext.utf8.count
            + question.name.utf8.count
            + question.instructions.utf8.count
            + question.choices.reduce(0) { $0 + $1.opaqueKey.utf8.count + $1.description.utf8.count }
    }
}

protocol DecisionService: Sendable {
    var id: DecisionServiceID { get }
    var displayName: String { get }
    var capabilities: DecisionServiceCapabilities { get }
    func readinessSnapshot() async -> DecisionReadiness
    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome
}

/// Backend-owned credential/configuration authority. Generic Settings receives redacted
/// presentation and action results, never a stored secret.
protocol DecisionServiceConfigurationController: Sendable {
    func readinessSnapshot() async -> DecisionReadiness
    func readinessUpdates() async -> AsyncStream<DecisionReadiness>
    func perform(_ action: DecisionServiceSettingsAction) async -> DecisionServiceSettingsActionResult
    func bootstrapStoredConfigurationIfNeeded() async
    func cancelAndAdvanceGeneration() async
}

enum DecisionAuthenticationKind: Equatable {
    case apiKey
    case oauth
    case localConfiguration
    case none
}

struct DecisionCredentialContextSummary: Equatable {
    let contextID: String
    let ownerLabel: String
    let accountLabel: String?
    let billingContextDescription: String?
    let isVerified: Bool
}

struct DecisionServiceConfigurationRegistration {
    let presentation: DecisionServiceSettingsPresentation
    let controller: any DecisionServiceConfigurationController
    let authenticationKind: DecisionAuthenticationKind
    let credentialContext: DecisionCredentialContextSummary?

    init(
        presentation: DecisionServiceSettingsPresentation,
        controller: any DecisionServiceConfigurationController,
        authenticationKind: DecisionAuthenticationKind = .apiKey,
        credentialContext: DecisionCredentialContextSummary? = nil
    ) {
        self.presentation = presentation
        self.controller = controller
        self.authenticationKind = authenticationKind
        self.credentialContext = credentialContext
    }
}

struct DecisionServiceRegistration {
    let id: DecisionServiceID
    let displayName: String
    let service: any DecisionService
    let capabilities: DecisionServiceCapabilities
    let configuration: DecisionServiceConfigurationRegistration?
    let displayOrder: Int

    init(
        service: any DecisionService,
        configuration: DecisionServiceConfigurationRegistration? = nil,
        displayOrder: Int = 1000
    ) {
        id = service.id
        displayName = service.displayName
        self.service = service
        capabilities = service.capabilities
        self.configuration = configuration
        self.displayOrder = displayOrder
    }
}

enum DecisionServiceRegistryError: Error, Equatable {
    case invalidServiceID
    case duplicateServiceID(DecisionServiceID)
    case invalidCapabilities(DecisionServiceID)
}

/// Immutable compile-time registration table. Lookup is exact, including persisted unknown IDs.
actor DecisionServiceRegistry {
    private let registrationsByID: [DecisionServiceID: DecisionServiceRegistration]
    private let orderedIDs: [DecisionServiceID]

    init(registrations: [DecisionServiceRegistration]) throws {
        var byID: [DecisionServiceID: DecisionServiceRegistration] = [:]
        for registration in registrations {
            guard !registration.id.rawValue.isEmpty else { throw DecisionServiceRegistryError.invalidServiceID }
            guard byID[registration.id] == nil else {
                throw DecisionServiceRegistryError.duplicateServiceID(registration.id)
            }
            guard registration.capabilities.isValid else {
                throw DecisionServiceRegistryError.invalidCapabilities(registration.id)
            }
            byID[registration.id] = registration
        }
        registrationsByID = byID
        orderedIDs = byID.values.sorted {
            ($0.displayOrder, $0.id) < ($1.displayOrder, $1.id)
        }.map(\.id)
    }

    func registrations() -> [DecisionServiceRegistration] {
        orderedIDs.compactMap { registrationsByID[$0] }
    }

    func registration(for id: DecisionServiceID) -> DecisionServiceRegistration? {
        registrationsByID[id]
    }

    func compatibleRegistrations(
        with requirement: DecisionCapabilityRequirement,
        request: FiniteChoiceDecisionRequest
    ) -> [DecisionServiceRegistration] {
        orderedIDs.compactMap { id in
            guard let registration = registrationsByID[id],
                  registration.capabilities.supports(requirement, request: request)
            else { return nil }
            return registration
        }
    }
}
