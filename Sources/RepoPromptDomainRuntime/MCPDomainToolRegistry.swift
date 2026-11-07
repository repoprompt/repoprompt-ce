#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation

package enum MCPDomainToolRegistryError: Error, Equatable {
    case emptyRegistration
    case invalidWindowID(Int)
    case duplicateToolName(String)
    case unknownToolName(String)
    case scopeMismatch(toolName: String, expected: MCPDomainToolScopeKind, actual: MCPDomainToolScopeKind)
    case bindingAlreadyRegistered(toolName: String, scope: MCPDomainToolRegistrationScope)
    case conflictingDefinition(toolName: String)
}

package struct MCPDomainToolScopePresence: Equatable {
    package let revision: UInt64
    package let isComplete: Bool

    package init(revision: UInt64, isComplete: Bool) {
        self.revision = revision
        self.isComplete = isComplete
    }
}

package struct MCPDomainToolCatalogSnapshot {
    package let revision: UInt64
    package let definitions: [MCPDomainToolDefinition]
    package let fingerprintsByToolName: [String: MCPDomainToolFingerprint]
    package let activeScopesByToolName: [String: Set<MCPDomainToolRegistrationScope>]
    package let catalogFingerprint: String

    package var toolNames: [String] {
        definitions.map(\.name)
    }
}

package enum MCPDomainRegistryRemoval: Equatable {
    case removed
    case unchanged
}

package enum MCPDomainToolRegistrationDisposition: Equatable {
    case inserted
    case replaced
    case unchanged
}

package struct MCPDomainToolRegistrationResult: Equatable {
    package let handle: MCPDomainToolRegistrationHandle
    package let disposition: MCPDomainToolRegistrationDisposition
}

package struct MCPDomainToolRegistryDiagnostics: Equatable {
    package let registrationCount: Int
    package let exactScopedToolCount: Int
    package let canonicalToolCount: Int
    package let canonicalRegistrationMembershipCount: Int
    package let windowToolCount: Int
    package let windowRegistrationMembershipCount: Int
    package let scopePresenceCount: Int
}

package struct MCPDomainToolRegistrationRequest {
    package let registrationID: MCPDomainToolRegistrationID
    package let scope: MCPDomainToolRegistrationScope
    package let bindings: [MCPDomainToolBinding]

    package init(
        registrationID: MCPDomainToolRegistrationID,
        scope: MCPDomainToolRegistrationScope,
        bindings: [MCPDomainToolBinding]
    ) {
        self.registrationID = registrationID
        self.scope = scope
        self.bindings = bindings
    }
}

package actor MCPDomainToolRegistry {
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

    package nonisolated let registryID: UUID

    private var revision: UInt64 = 0
    private var nextGeneration: UInt64 = 0
    private var registrations: [MCPDomainToolRegistrationID: Registration] = [:]
    private var registrationIDByScopedTool: [ScopedToolKey: MCPDomainToolRegistrationID] = [:]
    private var canonicalDefinitionsByToolName: [String: CanonicalDefinitionIndex] = [:]
    private var windowRegistrationIDsByToolName: [String: Set<MCPDomainToolRegistrationID>] = [:]
    private var activeToolNamesByScope: [MCPDomainToolRegistrationScope: Set<String>] = [:]

    package init(registryID: UUID = UUID()) {
        self.registryID = registryID
    }

    @discardableResult
    package func register(
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
    package func registerAtomically(
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

    package func registerWithResult(
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

    package func unregister(
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

    package func unregister(_ handle: MCPDomainToolRegistrationHandle) -> MCPDomainRegistryRemoval {
        guard handle.registryID == registryID else { return .unchanged }
        return unregister(
            registrationID: handle.registrationID,
            expectedGeneration: handle.generation
        )
    }

    package func isRegistered(_ registrationID: MCPDomainToolRegistrationID) -> Bool {
        registrations[registrationID] != nil
    }

    package func isActive(_ handle: MCPDomainToolRegistrationHandle) -> Bool {
        guard handle.registryID == registryID else { return false }
        return registrations[handle.registrationID]?.handle.generation == handle.generation
    }

    package func resolve(
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

    package func resolveUniqueWindowTool(toolName: String) -> MCPDomainResolvedTool? {
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
    package func scopePresence(
        requiredToolNames: [String],
        scope: MCPDomainToolRegistrationScope
    ) -> MCPDomainToolScopePresence {
        let activeNames = activeToolNamesByScope[scope] ?? []
        return MCPDomainToolScopePresence(
            revision: revision,
            isComplete: requiredToolNames.allSatisfy(activeNames.contains)
        )
    }

    package func snapshot() -> MCPDomainToolCatalogSnapshot {
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

    package func diagnostics() -> MCPDomainToolRegistryDiagnostics {
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
