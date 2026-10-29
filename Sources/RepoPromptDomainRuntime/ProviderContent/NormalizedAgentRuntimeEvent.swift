
package enum NormalizedAgentRuntimeEvent {
    case stream(RepoPromptDomainRuntime.AIStreamResult)
    case approvalRequested(AgentApprovalRequest)
    case approvalCancelled(AgentApprovalRequestID)
    case terminal(state: AgentSessionRunState, errorText: String?)
}
