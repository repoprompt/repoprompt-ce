import Foundation

/// Explicit reports are local assertions, not remotely verified PR state or session authority.
enum AgentSessionPullRequestEvidence {
    static func report(
        url: String,
        relationship: String,
        provenance: String? = nil,
        trustedHosts: Set<String> = ["github.com"],
        executionID: String? = nil,
        now: Date = Date()
    ) throws -> AgentSessionPullRequestAssociation {
        guard ["created", "related"].contains(relationship) else { throw AgentSessionTitleError.denied("invalid_pr_relationship") }
        return try .init(
            identity: AgentSessionPullRequestIdentity(url: url, trustedHosts: trustedHosts),
            provenance: provenance ?? (relationship == "created" ? "agentReportedCreation" : "agentReportedAssociation"),
            firstAssociatedAt: now,
            executionID: executionID
        )
    }
}
