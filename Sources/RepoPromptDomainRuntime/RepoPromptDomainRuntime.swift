import Foundation

package enum DomainRuntimeMode: String, CaseIterable, Sendable {
    case app
    case standalone
}

package struct DomainRuntimeConfiguration: Sendable {
    package let mode: DomainRuntimeMode
    package let profileIdentifier: String
    package let storageDirectory: URL
    package let eventDirectory: URL
    package let temporaryDirectory: URL

    package init(
        mode: DomainRuntimeMode,
        profileIdentifier: String,
        storageDirectory: URL,
        eventDirectory: URL,
        temporaryDirectory: URL
    ) {
        self.mode = mode
        self.profileIdentifier = profileIdentifier
        self.storageDirectory = storageDirectory
        self.eventDirectory = eventDirectory
        self.temporaryDirectory = temporaryDirectory
    }
}

package struct DomainRuntimeIdentity: Hashable, Sendable {
    package let runtimeID: UUID
    package let lifecycleGeneration: UInt64
    package let processID: Int32
    package let mode: DomainRuntimeMode
    package let createdAt: Date

    package init(
        runtimeID: UUID,
        lifecycleGeneration: UInt64,
        processID: Int32,
        mode: DomainRuntimeMode,
        createdAt: Date
    ) {
        self.runtimeID = runtimeID
        self.lifecycleGeneration = lifecycleGeneration
        self.processID = processID
        self.mode = mode
        self.createdAt = createdAt
    }
}

package enum DomainRuntimeLifecycle: String, CaseIterable, Sendable {
    case created
    case starting
    case ready
    case draining
    case stopped
    case degraded
}

package struct DomainRuntimeSnapshot: Sendable {
    package let identity: DomainRuntimeIdentity
    package let lifecycle: DomainRuntimeLifecycle
    package let publicationSequence: UInt64
    package let catalogRevision: UInt64
}

package struct DomainShutdownResult: Sendable {
    package let identity: DomainRuntimeIdentity
    package let previousLifecycle: DomainRuntimeLifecycle
    package let finalLifecycle: DomainRuntimeLifecycle
}

package enum DomainRuntimeLifecycleError: Error, Equatable, Sendable {
    case stoppedRuntimeCannotRestart
}

package actor MCPDomainRuntime {
    package nonisolated let identity: DomainRuntimeIdentity
    package nonisolated let configuration: DomainRuntimeConfiguration
    package nonisolated let toolRegistry: MCPDomainToolRegistry

    private var lifecycle: DomainRuntimeLifecycle = .created
    private var publicationSequence: UInt64 = 0

    package init(
        configuration: DomainRuntimeConfiguration,
        runtimeID: UUID = UUID(),
        lifecycleGeneration: UInt64 = 1,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        createdAt: Date = Date(),
        registryID: UUID = UUID()
    ) {
        self.configuration = configuration
        identity = DomainRuntimeIdentity(
            runtimeID: runtimeID,
            lifecycleGeneration: lifecycleGeneration,
            processID: processID,
            mode: configuration.mode,
            createdAt: createdAt
        )
        toolRegistry = MCPDomainToolRegistry(registryID: registryID)
    }

    package func start() async throws {
        switch lifecycle {
        case .created:
            lifecycle = .starting
            publishSnapshot()
            lifecycle = .ready
            publishSnapshot()
        case .starting, .ready, .degraded:
            return
        case .draining, .stopped:
            throw DomainRuntimeLifecycleError.stoppedRuntimeCannotRestart
        }
    }

    package func shutdown() async -> DomainShutdownResult {
        let previousLifecycle = lifecycle
        guard lifecycle != .stopped else {
            return DomainShutdownResult(
                identity: identity,
                previousLifecycle: previousLifecycle,
                finalLifecycle: .stopped
            )
        }
        lifecycle = .draining
        publishSnapshot()
        lifecycle = .stopped
        publishSnapshot()
        return DomainShutdownResult(
            identity: identity,
            previousLifecycle: previousLifecycle,
            finalLifecycle: .stopped
        )
    }

    package func snapshot() async -> DomainRuntimeSnapshot {
        let catalog = await toolRegistry.snapshot()
        return DomainRuntimeSnapshot(
            identity: identity,
            lifecycle: lifecycle,
            publicationSequence: publicationSequence,
            catalogRevision: catalog.revision
        )
    }

    private func publishSnapshot() {
        publicationSequence &+= 1
    }
}
