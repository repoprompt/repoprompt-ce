import Foundation
import MCP

extension MCPBootstrapLeaseSpec {
    static func headless(
        runID: UUID,
        gateID: UUID,
        clientName: String,
        windowID: Int,
        restrictedTools: Set<String>,
        additionalTools: Set<String>? = nil,
        oneShot: Bool = true,
        reason: String? = nil,
        ttl: TimeInterval,
        tabID: UUID? = nil,
        purpose: MCPRunPurpose,
        requiresExpectedAgentPID: Bool = false
    ) -> MCPBootstrapLeaseSpec {
        MCPBootstrapLeaseSpec(
            runID: runID,
            gateID: gateID,
            windowID: windowID,
            tabID: tabID,
            clientName: clientName,
            restrictedTools: restrictedTools,
            additionalTools: additionalTools,
            oneShot: oneShot,
            reason: reason,
            ttl: ttl,
            purpose: purpose,
            taskLabelKind: nil,
            allowsAgentExternalControlTools: false,
            requiresExpectedAgentPID: requiresExpectedAgentPID
        )
    }
}
