import Foundation

enum AgentSessionPersistenceSentryTelemetry {
    static func recordScheduled(session: AgentSession) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .persistenceAction,
            action: .persistenceScheduled,
            attributes: attributes(session: session, outcome: .started)
        )
    }

    static func recordCompleted(session: AgentSession) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .persistenceAction,
            action: .persistenceCompleted,
            attributes: attributes(session: session, outcome: .completed)
        )
    }

    static func recordFailed(session: AgentSession) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .persistenceAction,
            action: .persistenceFailed,
            attributes: attributes(session: session, outcome: .failed, isError: true)
        )
    }

    static func attributes(
        session: AgentSession,
        outcome: SentryTelemetryBootstrap.Outcome,
        isError: Bool = false
    ) -> [SentryTelemetryBootstrap.Attribute] {
        var attributes: [SentryTelemetryBootstrap.Attribute] = [
            .entrypoint(.agent),
            .clientClass(session.isMCPOriginated ? .externalAgent : .inApp),
            .outcome(outcome),
            .isError(isError),
            .messageCount(session.items.count),
            .isChildSession(session.parentSessionID != nil),
            .hasProviderResumeSession(session.providerSessionID != nil)
        ]
        if let agentKind = session.agentKind,
           let providerKind = SentryTelemetryBootstrap.ProviderKind(agentKindRaw: agentKind)
        {
            attributes.append(.providerKind(providerKind))
        }
        return attributes
    }
}
