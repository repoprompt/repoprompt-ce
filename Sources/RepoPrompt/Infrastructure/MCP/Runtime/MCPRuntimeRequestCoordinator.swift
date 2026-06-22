import Foundation
import RepoPromptCore

struct MCPRuntimeFileToolSnapshot: @unchecked Sendable {
    let adapterTicket: MCPRuntimeAdapterTicket
    let runtimeID: WorkspaceRuntimeID
    let sessionID: WorkspaceSessionID
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay
    let codeMapsEnabled: Bool

    func context(admittedRuntime: WorkspaceAdmittedRuntimeSession) -> MCPRuntimeFileToolContext? {
        guard admittedRuntime.runtimeID == runtimeID,
              admittedRuntime.sessionID == sessionID
        else { return nil }
        return MCPRuntimeFileToolContext(
            adapterTicket: adapterTicket,
            runtimeID: runtimeID,
            sessionID: sessionID,
            query: admittedRuntime.query,
            lookupContext: lookupContext,
            filePathDisplay: filePathDisplay,
            codeMapsEnabled: codeMapsEnabled
        )
    }
}

struct MCPRuntimeFileToolContext: @unchecked Sendable {
    let adapterTicket: MCPRuntimeAdapterTicket
    let runtimeID: WorkspaceRuntimeID
    let sessionID: WorkspaceSessionID
    let query: WorkspaceSessionQueryCapability
    let lookupContext: WorkspaceLookupContext
    let filePathDisplay: FilePathDisplay
    let codeMapsEnabled: Bool
}

struct MCPRuntimeRequestContext: @unchecked Sendable {
    let lifetimeClass: MCPToolLifetimeClass
    let routingSnapshot: MCPRuntimeRoutingSnapshot
    let admittedRuntime: WorkspaceAdmittedRuntimeSession
    let adapterTicket: MCPRuntimeAdapterTicket?
    let fileToolContext: MCPRuntimeFileToolContext?

    var runtimeID: WorkspaceRuntimeID {
        admittedRuntime.runtimeID
    }

    var sessionID: WorkspaceSessionID {
        admittedRuntime.sessionID
    }

    var admissionToken: WorkspaceRuntimeAdmissionToken {
        admittedRuntime.admissionToken
    }
}

enum MCPRuntimeRequestAdmissionError: Error, Equatable {
    case routingUnavailable
    case mappingChanged
    case adapterUnavailable
    case runtimeUnavailable(WorkspaceRuntimeAdmissionFailure)
}

/// Exactly-once release owner for one admitted MCP runtime request.
actor MCPRuntimeRequestLease {
    let context: MCPRuntimeRequestContext
    private let registry: WorkspaceRuntimeLifecycleRegistry
    private var didRelease = false

    init(context: MCPRuntimeRequestContext, registry: WorkspaceRuntimeLifecycleRegistry) {
        self.context = context
        self.registry = registry
    }

    @discardableResult
    func release() async -> WorkspaceRuntimeReleaseResult? {
        guard !didRelease else { return nil }
        didRelease = true
        return await registry.release(context.admissionToken)
    }
}

enum MCPRuntimeRequestCoordinator {
    static func admit(
        routingSnapshot: MCPRuntimeRoutingSnapshot,
        lifetimeClass: MCPToolLifetimeClass,
        lifecycleRegistry: WorkspaceRuntimeLifecycleRegistry,
        adapterRegistry: MCPAppRuntimeAdapterRegistry
    ) async -> Result<MCPRuntimeRequestLease, MCPRuntimeRequestAdmissionError> {
        if lifetimeClass.requiresUIAdapterAtStart {
            let adapterAvailable = await MainActor.run {
                adapterRegistry.adapter(for: routingSnapshot.ticket) != nil
            }
            guard adapterAvailable else { return .failure(.adapterUnavailable) }
        }

        // Freeze every UI-derived value before Core admission. Once admission succeeds, runtime-
        // capable work must not consult the weak app adapter again.
        let fileToolSnapshot = await adapterRegistry.captureRuntimeFileToolSnapshot(
            ticket: routingSnapshot.ticket
        )
        let mappingIsStillExact = await MainActor.run {
            guard let current = adapterRegistry.routingSnapshot(windowID: routingSnapshot.windowID) else {
                return false
            }
            return current.ticket == routingSnapshot.ticket
        }
        guard mappingIsStillExact else { return .failure(.mappingChanged) }

        let admission = await lifecycleRegistry.admit(runtimeID: routingSnapshot.runtimeID)
        guard case let .admitted(admittedRuntime) = admission else {
            if case let .unavailable(failure) = admission {
                return .failure(.runtimeUnavailable(failure))
            }
            return .failure(.routingUnavailable)
        }

        let fileToolContext = fileToolSnapshot?.context(admittedRuntime: admittedRuntime)
        return .success(MCPRuntimeRequestLease(
            context: MCPRuntimeRequestContext(
                lifetimeClass: lifetimeClass,
                routingSnapshot: routingSnapshot,
                admittedRuntime: admittedRuntime,
                adapterTicket: lifetimeClass.requiresUIAdapterAtStart ? routingSnapshot.ticket : nil,
                fileToolContext: fileToolContext
            ),
            registry: lifecycleRegistry
        ))
    }
}
