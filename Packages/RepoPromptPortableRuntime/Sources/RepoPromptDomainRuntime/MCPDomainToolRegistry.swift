#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation

public enum MCPDomainToolRegistryError: Error, Equatable, Sendable {
    case emptyRegistration
    case invalidWindowID(Int)
    case duplicateToolName(String)
    case unknownToolName(String)
    case scopeMismatch(toolName: String, expected: MCPDomainToolScopeKind, actual: MCPDomainToolScopeKind)
    case bindingAlreadyRegistered(toolName: String, scope: MCPDomainToolRegistrationScope)
    case conflictingDefinition(toolName: String)
}

public struct MCPDomainToolScopePresence: Equatable, Sendable {
    public let revision: UInt64
    public let isComplete: Bool

    public init(revision: UInt64, isComplete: Bool) {
        self.revision = revision
        self.isComplete = isComplete
    }
}

public struct MCPDomainToolCatalogSnapshot: Sendable {
    public let revision: UInt64
    public let definitions: [MCPDomainToolDefinition]
    public let fingerprintsByToolName: [String: MCPDomainToolFingerprint]
    public let activeScopesByToolName: [String: Set<MCPDomainToolRegistrationScope>]
    public let catalogFingerprint: String

    public var toolNames: [String] {
        definitions.map(\.name)
    }
}

public enum MCPDomainRegistryRemoval: Equatable, Sendable {
    case removed
    case unchanged
}

public enum MCPDomainToolRegistrationDisposition: Equatable, Sendable {
    case inserted
    case replaced
    case unchanged
}

public struct MCPDomainToolRegistrationResult: Equatable, Sendable {
    public let handle: MCPDomainToolRegistrationHandle
    public let disposition: MCPDomainToolRegistrationDisposition
}

public struct MCPDomainToolRegistryDiagnostics: Equatable, Sendable {
    public let registrationCount: Int
    public let exactScopedToolCount: Int
    public let canonicalToolCount: Int
    public let canonicalRegistrationMembershipCount: Int
    public let windowToolCount: Int
    public let windowRegistrationMembershipCount: Int
    public let scopePresenceCount: Int
}

public struct MCPDomainToolRegistrationRequest: Sendable {
    public let registrationID: MCPDomainToolRegistrationID
    public let scope: MCPDomainToolRegistrationScope
    public let bindings: [MCPDomainToolBinding]

    public init(
        registrationID: MCPDomainToolRegistrationID,
        scope: MCPDomainToolRegistrationScope,
        bindings: [MCPDomainToolBinding]
    ) {
        self.registrationID = registrationID
        self.scope = scope
        self.bindings = bindings
    }
}

public actor MCPDomainToolRegistry {
    private struct ScopedToolKey: Hashable {
        let scope: MCPDomainToolRegistrationScope
        let toolName: String
    }

    private struct CanonicalDefinitionIndex {
        let fingerprint: MCPDomainToolFingerprint
        var registrationIDs: Set<MCPDomainToolRegistrationID>
    }

    private struct Registration {
        let handle: MCPDomainToolRegistrationHandle
        let scope: MCPDomainToolRegistrationScope
        let bindingsByName: [String: MCPDomainToolBinding]
        let fingerprintsByName: [String: MCPDomainToolFingerprint]
    }

    public nonisolated let registryID: UUID

    private var revision: UInt64 = 0
    private var nextGeneration: UInt64 = 0
    private var registrations: [MCPDomainToolRegistrationID: Registration] = [:]
    private var registrationIDByScopedTool: [ScopedToolKey: MCPDomainToolRegistrationID] = [:]
    private var canonicalDefinitionsByToolName: [String: CanonicalDefinitionIndex] = [:]
    private var windowRegistrationIDsByToolName: [String: Set<MCPDomainToolRegistrationID>] = [:]
    private var activeToolNamesByScope: [MCPDomainToolRegistrationScope: Set<String>] = [:]

    public init(registryID: UUID = UUID()) {
        self.registryID = registryID
    }

    @discardableResult
    public func register(
        registrationID: MCPDomainToolRegistrationID,
        scope: MCPDomainToolRegistrationScope,
        bindings: [MCPDomainToolBinding]
    ) throws -> MCPDomainToolRegistrationHandle {
        try registerWithResult(
            registrationID: registrationID,
            scope: scope,
            bindings: bindings
        ).handle
    }

    /// Applies an ordered registration batch as one actor-isolated transaction.
    /// No partial registration is observable: any failure restores the exact prior
    /// registrations, generations, and revision before the actor is released.
    public func registerAtomically(
        _ requests: [MCPDomainToolRegistrationRequest]
    ) throws -> [MCPDomainToolRegistrationResult] {
        let priorRevision = revision
        let priorNextGeneration = nextGeneration
        let priorRegistrations = registrations
        let priorRegistrationIDByScopedTool = registrationIDByScopedTool
        let priorCanonicalDefinitionsByToolName = canonicalDefinitionsByToolName
        let priorWindowRegistrationIDsByToolName = windowRegistrationIDsByToolName
        let priorActiveToolNamesByScope = activeToolNamesByScope

        do {
            return try requests.map { request in
                try registerWithResult(
                    registrationID: request.registrationID,
                    scope: request.scope,
                    bindings: request.bindings
                )
            }
        } catch {
            registrations = priorRegistrations
            registrationIDByScopedTool = priorRegistrationIDByScopedTool
            canonicalDefinitionsByToolName = priorCanonicalDefinitionsByToolName
            windowRegistrationIDsByToolName = priorWindowRegistrationIDsByToolName
            activeToolNamesByScope = priorActiveToolNamesByScope
            nextGeneration = priorNextGeneration
            revision = priorRevision
            throw error
        }
    }

    public func registerWithResult(
        registrationID: MCPDomainToolRegistrationID,
        scope: MCPDomainToolRegistrationScope,
        bindings: [MCPDomainToolBinding]
    ) throws -> MCPDomainToolRegistrationResult {
        guard !bindings.isEmpty else {
            throw MCPDomainToolRegistryError.emptyRegistration
        }
        if case let .window(id) = scope, id <= 0 {
            throw MCPDomainToolRegistryError.invalidWindowID(id)
        }

        var proposedBindings: [String: MCPDomainToolBinding] = [:]
        var proposedFingerprints: [String: MCPDomainToolFingerprint] = [:]
        for binding in bindings {
            let name = binding.definition.name
            guard proposedBindings[name] == nil else {
                throw MCPDomainToolRegistryError.duplicateToolName(name)
            }
            guard let entry = MCPDomainToolCatalog.entry(named: name) else {
                throw MCPDomainToolRegistryError.unknownToolName(name)
            }
            guard entry.supports(registrationScope: scope) else {
                throw MCPDomainToolRegistryError.scopeMismatch(
                    toolName: name,
                    expected: entry.scope,
                    actual: scope.kind
                )
            }
            proposedBindings[name] = binding
            proposedFingerprints[name] = try MCPDomainToolFingerprint(definition: binding.definition)
        }

        for (toolName, proposedFingerprint) in proposedFingerprints {
            let scopedKey = ScopedToolKey(scope: scope, toolName: toolName)
            if let owner = registrationIDByScopedTool[scopedKey], owner != registrationID {
                throw MCPDomainToolRegistryError.bindingAlreadyRegistered(toolName: toolName, scope: scope)
            }
            if let canonical = canonicalDefinitionsByToolName[toolName] {
                let selfMembership = canonical.registrationIDs.contains(registrationID) ? 1 : 0
                if canonical.registrationIDs.count > selfMembership,
                   canonical.fingerprint != proposedFingerprint
                {
                    throw MCPDomainToolRegistryError.conflictingDefinition(toolName: toolName)
                }
            }
        }

        if let existing = registrations[registrationID],
           existing.scope == scope,
           existing.fingerprintsByName == proposedFingerprints
        {
            return MCPDomainToolRegistrationResult(
                handle: existing.handle,
                disposition: .unchanged
            )
        }

        nextGeneration &+= 1
        let handle = MCPDomainToolRegistrationHandle(
            registryID: registryID,
            registrationID: registrationID,
            generation: nextGeneration
        )
        let disposition: MCPDomainToolRegistrationDisposition = registrations[registrationID] == nil
            ? .inserted
            : .replaced
        if let existing = registrations[registrationID] {
            removeIndexEntries(registrationID: registrationID, registration: existing)
        }
        let registration = Registration(
            handle: handle,
            scope: scope,
            bindingsByName: proposedBindings,
            fingerprintsByName: proposedFingerprints
        )
        registrations[registrationID] = registration
        addIndexEntries(registrationID: registrationID, registration: registration)
        revision &+= 1
        return MCPDomainToolRegistrationResult(handle: handle, disposition: disposition)
    }

    public func unregister(
        registrationID: MCPDomainToolRegistrationID,
        expectedGeneration: UInt64? = nil
    ) -> MCPDomainRegistryRemoval {
        guard let registration = registrations[registrationID] else {
            return .unchanged
        }
        if let expectedGeneration, registration.handle.generation != expectedGeneration {
            return .unchanged
        }
        registrations.removeValue(forKey: registrationID)
        removeIndexEntries(registrationID: registrationID, registration: registration)
        revision &+= 1
        return .removed
    }

    public func unregister(_ handle: MCPDomainToolRegistrationHandle) -> MCPDomainRegistryRemoval {
        guard handle.registryID == registryID else { return .unchanged }
        return unregister(
            registrationID: handle.registrationID,
            expectedGeneration: handle.generation
        )
    }

    public func isRegistered(_ registrationID: MCPDomainToolRegistrationID) -> Bool {
        registrations[registrationID] != nil
    }

    public func isActive(_ handle: MCPDomainToolRegistrationHandle) -> Bool {
        guard handle.registryID == registryID else { return false }
        return registrations[handle.registrationID]?.handle.generation == handle.generation
    }

    public func resolve(
        toolName: String,
        scope: MCPDomainToolRegistrationScope
    ) -> MCPDomainResolvedTool? {
        let key = ScopedToolKey(scope: scope, toolName: toolName)
        guard let registrationID = registrationIDByScopedTool[key],
              let registration = registrations[registrationID],
              let binding = registration.bindingsByName[toolName]
        else { return nil }
        return resolvedTool(registration: registration, binding: binding)
    }

    public func resolveUniqueWindowTool(toolName: String) -> MCPDomainResolvedTool? {
        guard let registrationIDs = windowRegistrationIDsByToolName[toolName],
              registrationIDs.count == 1,
              let registrationID = registrationIDs.first,
              let registration = registrations[registrationID],
              let binding = registration.bindingsByName[toolName]
        else { return nil }
        return resolvedTool(registration: registration, binding: binding)
    }

    /// Lightweight readiness projection. This path consults only the actor-owned
    /// scope-name index; it never materializes definitions, fingerprints, or a
    /// catalog digest.
    public func scopePresence(
        requiredToolNames: [String],
        scope: MCPDomainToolRegistrationScope
    ) -> MCPDomainToolScopePresence {
        let activeNames = activeToolNamesByScope[scope] ?? []
        return MCPDomainToolScopePresence(
            revision: revision,
            isComplete: requiredToolNames.allSatisfy(activeNames.contains)
        )
    }

    public func snapshot() -> MCPDomainToolCatalogSnapshot {
        var definitionsByName: [String: MCPDomainToolDefinition] = [:]
        var fingerprintsByName: [String: MCPDomainToolFingerprint] = [:]
        var activeScopes: [String: Set<MCPDomainToolRegistrationScope>] = [:]
        for registration in registrations.values {
            for (name, binding) in registration.bindingsByName {
                definitionsByName[name] = binding.definition
                fingerprintsByName[name] = registration.fingerprintsByName[name]
                activeScopes[name, default: []].insert(registration.scope)
            }
        }
        let definitions = MCPDomainToolCatalog.orderedToolNames.compactMap { definitionsByName[$0] }
        let fingerprints = Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            fingerprintsByName[definition.name].map { (definition.name, $0) }
        })
        let catalogBytes = definitions.compactMap { fingerprints[$0.name]?.digest }.joined(separator: "\n")
        let catalogFingerprint = SHA256.hash(data: Data(catalogBytes.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return MCPDomainToolCatalogSnapshot(
            revision: revision,
            definitions: definitions,
            fingerprintsByToolName: fingerprints,
            activeScopesByToolName: activeScopes,
            catalogFingerprint: catalogFingerprint
        )
    }

    public func diagnostics() -> MCPDomainToolRegistryDiagnostics {
        MCPDomainToolRegistryDiagnostics(
            registrationCount: registrations.count,
            exactScopedToolCount: registrationIDByScopedTool.count,
            canonicalToolCount: canonicalDefinitionsByToolName.count,
            canonicalRegistrationMembershipCount: canonicalDefinitionsByToolName.values.reduce(0) {
                $0 + $1.registrationIDs.count
            },
            windowToolCount: windowRegistrationIDsByToolName.count,
            windowRegistrationMembershipCount: windowRegistrationIDsByToolName.values.reduce(0) {
                $0 + $1.count
            },
            scopePresenceCount: activeToolNamesByScope.count
        )
    }

    private func addIndexEntries(
        registrationID: MCPDomainToolRegistrationID,
        registration: Registration
    ) {
        for (toolName, fingerprint) in registration.fingerprintsByName {
            registrationIDByScopedTool[ScopedToolKey(
                scope: registration.scope,
                toolName: toolName
            )] = registrationID

            if var canonical = canonicalDefinitionsByToolName[toolName] {
                canonical.registrationIDs.insert(registrationID)
                canonicalDefinitionsByToolName[toolName] = canonical
            } else {
                canonicalDefinitionsByToolName[toolName] = CanonicalDefinitionIndex(
                    fingerprint: fingerprint,
                    registrationIDs: [registrationID]
                )
            }

            if case .window = registration.scope {
                windowRegistrationIDsByToolName[toolName, default: []].insert(registrationID)
            }
        }
        activeToolNamesByScope[registration.scope, default: []]
            .formUnion(registration.bindingsByName.keys)
    }

    private func removeIndexEntries(
        registrationID: MCPDomainToolRegistrationID,
        registration: Registration
    ) {
        for toolName in registration.bindingsByName.keys {
            let scopedKey = ScopedToolKey(scope: registration.scope, toolName: toolName)
            if registrationIDByScopedTool[scopedKey] == registrationID {
                registrationIDByScopedTool.removeValue(forKey: scopedKey)
            }

            if var canonical = canonicalDefinitionsByToolName[toolName] {
                canonical.registrationIDs.remove(registrationID)
                if canonical.registrationIDs.isEmpty {
                    canonicalDefinitionsByToolName.removeValue(forKey: toolName)
                } else {
                    canonicalDefinitionsByToolName[toolName] = canonical
                }
            }

            if var windowRegistrations = windowRegistrationIDsByToolName[toolName] {
                windowRegistrations.remove(registrationID)
                if windowRegistrations.isEmpty {
                    windowRegistrationIDsByToolName.removeValue(forKey: toolName)
                } else {
                    windowRegistrationIDsByToolName[toolName] = windowRegistrations
                }
            }
        }

        guard var activeNames = activeToolNamesByScope[registration.scope] else { return }
        activeNames.subtract(registration.bindingsByName.keys)
        if activeNames.isEmpty {
            activeToolNamesByScope.removeValue(forKey: registration.scope)
        } else {
            activeToolNamesByScope[registration.scope] = activeNames
        }
    }

    private func resolvedTool(
        registration: Registration,
        binding: MCPDomainToolBinding
    ) -> MCPDomainResolvedTool {
        MCPDomainResolvedTool(
            handle: registration.handle,
            scope: registration.scope,
            binding: binding
        )
    }
}
