import Foundation

enum ContextBuilderSentryTelemetry {
    static func recordStarted(tokenBudget: Int?) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .contextBuilderAction,
            action: .contextBuilderStarted,
            attributes: attributes(phase: .discovery, outcome: .started, tokenBudget: tokenBudget)
        )
    }

    static func recordCompleted(fileCount: Int, tokenBudget: Int?) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .contextBuilderAction,
            action: .contextBuilderCompleted,
            attributes: attributes(
                phase: .selectionCommit,
                outcome: .completed,
                fileCount: fileCount,
                tokenBudget: tokenBudget
            )
        )
    }

    static func recordFailed(tokenBudget: Int?, errorKind: SentryTelemetryBootstrap.ErrorKind) {
        SentryTelemetryBootstrap.addBreadcrumb(
            .contextBuilderAction,
            action: .contextBuilderFailed,
            attributes: attributes(
                phase: .discovery,
                outcome: errorKind == .cancelled ? .cancelled : .failed,
                tokenBudget: tokenBudget,
                errorKind: errorKind
            )
        )
    }

    static func attributes(
        phase: SentryTelemetryBootstrap.ContextBuilderPhase,
        outcome: SentryTelemetryBootstrap.Outcome,
        fileCount: Int? = nil,
        tokenBudget: Int? = nil,
        errorKind: SentryTelemetryBootstrap.ErrorKind? = nil
    ) -> [SentryTelemetryBootstrap.Attribute] {
        var attributes: [SentryTelemetryBootstrap.Attribute] = [
            .entrypoint(.mcp),
            .clientClass(.externalAgent),
            .toolName(.contextBuilder),
            .toolDomain(.context),
            .contextBuilderPhase(phase),
            .outcome(outcome),
            .tokenBudgetBucket(tokenBudgetBucket(for: tokenBudget))
        ]
        if let fileCount {
            attributes.append(.selectionFileCount(fileCount))
            attributes.append(.resultCount(fileCount))
        }
        if let errorKind {
            attributes.append(.errorKind(errorKind))
        }
        return attributes
    }

    private static func tokenBudgetBucket(for tokenBudget: Int?) -> SentryTelemetryBootstrap.TokenBudgetBucket {
        guard let tokenBudget else { return .unknown }
        return switch tokenBudget {
        case ..<25000:
            .under25K
        case 25000 ..< 75000:
            .k25To75
        case 75000 ..< 150_000:
            .k75To150
        default:
            .over150K
        }
    }
}
