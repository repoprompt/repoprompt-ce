import Combine
import Foundation

@MainActor
protocol CodexManagedSessionShutdownParticipant: AnyObject {
    func stopCodexSessionsForManagedLogout() async
}

@MainActor
final class CodexManagedSessionFence: ObservableObject {
    struct Token: Equatable {
        fileprivate let generation: UInt64
    }

    static let shared = CodexManagedSessionFence()

    static let blockedMessage = "Codex is signing out. Your draft was preserved; sign in again before sending it."

    @Published private(set) var isFenced = false
    @Published private(set) var isLogoutInProgress = false
    private var generation: UInt64 = 0

    func beginLogout() -> Token {
        if !isLogoutInProgress {
            generation &+= 1
            isLogoutInProgress = true
            isFenced = true
        }
        return Token(generation: generation)
    }

    func finishLogout(token: Token, succeeded: Bool) {
        guard isCurrent(token) else { return }
        isLogoutInProgress = false
        isFenced = succeeded
    }

    func beginAuthenticationAttempt() -> Token? {
        guard !isLogoutInProgress else { return nil }
        return Token(generation: generation)
    }

    func capturePublicationToken() -> Token {
        Token(generation: generation)
    }

    func isCurrent(_ token: Token) -> Bool {
        token.generation == generation
    }

    func allowsAuthenticationPublication(_ token: Token) -> Bool {
        isCurrent(token) && !isLogoutInProgress
    }

    @discardableResult
    func finishAuthentication(token: Token) -> Bool {
        guard allowsAuthenticationPublication(token) else { return false }
        isFenced = false
        return true
    }

    func allowsCodexSessionInstallation(_ token: Token) -> Bool {
        isCurrent(token) && !isFenced && !isLogoutInProgress
    }
}

enum CodexManagedSignOutConfirmation {
    enum Decision: Equatable {
        case cancel
        case stopSessionsAndSignOut
    }

    static let title = "Stop Codex Sessions and Sign Out?"
    static let message = "Active Codex work in all RepoPrompt CE windows will stop. Conversations and unsent drafts will be preserved."
    static let confirmTitle = "Stop Sessions & Sign Out"
    static let cancelTitle = "Cancel"

    static func shouldProceed(with decision: Decision) -> Bool {
        decision == .stopSessionsAndSignOut
    }
}

@MainActor
final class CodexManagedLogoutCoordinator {
    typealias LogoutOperation = @Sendable () async -> CodexManagedAuthLogoutResult
    typealias AdditionalTeardown = @MainActor @Sendable () async -> Void
    typealias FailedLogoutRecovery = @MainActor @Sendable () async -> Void

    static let shared = CodexManagedLogoutCoordinator(
        fence: .shared,
        logoutOperation: {
            await CodexManagedAuthRecoveryService.shared.logoutManagedAccount()
        }
    )

    private struct InFlightLogout {
        let id: UUID
        let task: Task<CodexManagedAuthLogoutResult, Never>
    }

    private let fence: CodexManagedSessionFence
    private let logoutOperation: LogoutOperation
    private var inFlightLogout: InFlightLogout?

    init(
        fence: CodexManagedSessionFence,
        logoutOperation: @escaping LogoutOperation
    ) {
        self.fence = fence
        self.logoutOperation = logoutOperation
    }

    func stopSessionsAndSignOut(
        participants: [any CodexManagedSessionShutdownParticipant],
        additionalTeardown: @escaping AdditionalTeardown = {},
        failedLogoutRecovery: @escaping FailedLogoutRecovery = {}
    ) async -> CodexManagedAuthLogoutResult {
        if let inFlightLogout {
            return await inFlightLogout.task.value
        }

        let id = UUID()
        let fenceGeneration = fence.beginLogout()
        let logoutOperation = logoutOperation
        let task = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for participant in participants {
                    group.addTask { @MainActor in
                        await participant.stopCodexSessionsForManagedLogout()
                    }
                }
            }
            await additionalTeardown()
            let result = await logoutOperation()
            fence.finishLogout(
                token: fenceGeneration,
                succeeded: result == .signedOut
            )
            if result != .signedOut {
                await failedLogoutRecovery()
            }
            return result
        }
        inFlightLogout = InFlightLogout(id: id, task: task)
        let result = await task.value
        if inFlightLogout?.id == id {
            inFlightLogout = nil
        }
        return result
    }
}
