import RepoPromptDomainRuntime

/// Route-snapshot evidence captured before later request awaits; never caller-supplied.
enum AgentSessionLinkWaitCallOrigin {
    @TaskLocal static var current: DomainAgentSessionLinkWaitInput?
}
