import Foundation

struct ContextBuilderFollowUpFinalizationConfiguration: Equatable {
    let overallTimeout: TimeInterval
    let inactivityTimeout: TimeInterval
    let checkInterval: TimeInterval

    static let production = ContextBuilderFollowUpFinalizationConfiguration(
        overallTimeout: 4 * 60 * 60,
        inactivityTimeout: 10 * 60,
        checkInterval: 5
    )
}

struct ContextBuilderFollowUpTimeoutSnapshot: Equatable {
    enum Kind: String {
        case inactivity
        case overall
    }
}
