import Foundation
import SwiftUI

enum WorkspaceSwitchResult: Equatable {
    case switched
    case cancelled(String)
    case blocked(String)

    var didSwitch: Bool {
        if case .switched = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .switched:
            nil
        case let .cancelled(message), let .blocked(message):
            message
        }
    }
}

enum WorkspaceSwitchPhase: String, Equatable {
    case preparing
    case awaitingConfirmation
    case cancellingSessions
    case waitingForChatIdle
    case savingCurrentWorkspace
    case unloadingRoots
    case loadingTargetWorkspace
    case restoringState
    case hydratingRoots
    case notifyingListeners
    case finalizing

    var displayName: String {
        switch self {
        case .preparing:
            "preparing"
        case .awaitingConfirmation:
            "awaiting confirmation"
        case .cancellingSessions:
            "cancelling sessions"
        case .waitingForChatIdle:
            "waiting for chat idle"
        case .savingCurrentWorkspace:
            "saving current workspace"
        case .unloadingRoots:
            "unloading roots"
        case .loadingTargetWorkspace:
            "loading target workspace"
        case .restoringState:
            "restoring state"
        case .hydratingRoots:
            "hydrating roots"
        case .notifyingListeners:
            "notifying listeners"
        case .finalizing:
            "finalizing"
        }
    }
}

struct WorkspaceSwitchActivity: Equatable {
    let operationID: UUID
    let previousWorkspaceID: UUID?
    let previousWorkspaceName: String?
    let targetWorkspaceID: UUID
    let targetWorkspaceName: String
    let reason: String
    let phase: WorkspaceSwitchPhase
    let startedAt: Date
    let phaseStartedAt: Date
}

struct WorkspaceSwitchBlockageReport: Equatable {
    let requestedTargetWorkspaceID: UUID
    let requestedTargetWorkspaceName: String
    let activeSwitch: WorkspaceSwitchActivity
    let totalAge: TimeInterval
    let phaseAge: TimeInterval
    let isStale: Bool
    let message: String
}

struct WorkspaceSwitchBlockedNotice: Identifiable, Equatable {
    let id: UUID
    let message: String
    let blockingOperationID: UUID?

    init(
        id: UUID = UUID(),
        message: String,
        blockingOperationID: UUID? = nil
    ) {
        self.id = id
        self.message = message
        self.blockingOperationID = blockingOperationID
    }

    func isBlocked(by operationID: UUID) -> Bool {
        blockingOperationID == operationID
    }
}

struct WorkspaceSwitchTimingPolicy: @unchecked Sendable {
    static let production = WorkspaceSwitchTimingPolicy(
        staleThreshold: 30,
        chatBusySettleTimeoutNanoseconds: 2_000_000_000,
        chatBusyPollIntervalNanoseconds: 50_000_000,
        now: { Date() },
        sleep: { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    )

    let staleThreshold: TimeInterval
    let chatBusySettleTimeoutNanoseconds: UInt64
    let chatBusyPollIntervalNanoseconds: UInt64
    let now: @Sendable () -> Date
    let sleep: @Sendable (UInt64) async throws -> Void
}

struct WorkspaceSwitchSessionItem: Hashable {
    let id: String
    let count: Int
    let singularLabel: String
    let pluralLabel: String

    func formattedCount() -> String {
        let label = count == 1 ? singularLabel : pluralLabel
        return "\(count) \(label)"
    }
}

struct WorkspaceSwitchSessionSnapshot {
    let items: [WorkspaceSwitchSessionItem]

    var hasActiveSessions: Bool {
        !items.isEmpty
    }
}

struct WorkspaceSwitchConfirmation: Identifiable {
    let id = UUID()
    let targetWorkspaceName: String
    let items: [WorkspaceSwitchSessionItem]

    private func summaryText() -> String {
        let parts = items
            .filter { $0.count > 0 }
            .map { $0.formattedCount() }
        return parts.joined(separator: " and ")
    }

    var message: String {
        let summary = summaryText()
        if summary.isEmpty {
            return "Switching workspaces will terminate any running sessions. Do you want to continue?"
        }
        return "Switching to \"\(targetWorkspaceName)\" will terminate \(summary). Do you want to continue?"
    }

    var cancelMessage: String {
        let summary = summaryText()
        if summary.isEmpty {
            return "Workspace switch was cancelled by the user."
        }
        return "Workspace switch cancelled. The current workspace has \(summary). Confirm termination to proceed."
    }
}

struct WorkspaceSwitchOverlayState: Equatable {
    let targetWorkspaceName: String
    let startedAt: Date
}

// MARK: - View Modifier for Switch Confirmation Alert

// Extracted to reduce type-checking complexity in ContentView

struct WorkspaceSwitchConfirmationModifier: ViewModifier {
    @ObservedObject var workspaceManager: WorkspaceManagerViewModel

    static func confirmationPresentationBinding(
        manager: WorkspaceManagerViewModel,
        confirmationID: UUID
    ) -> Binding<Bool> {
        Binding(
            get: { manager.pendingSwitchConfirmation?.id == confirmationID },
            set: { newValue in
                if !newValue {
                    manager.resolveSwitchConfirmation(id: confirmationID, allow: false)
                }
            }
        )
    }

    static func blockedNoticePresentationBinding(
        manager: WorkspaceManagerViewModel,
        noticeID: UUID
    ) -> Binding<Bool> {
        Binding(
            get: { manager.pendingWorkspaceSwitchBlockedNotice?.id == noticeID },
            set: { newValue in
                if !newValue {
                    manager.dismissWorkspaceSwitchBlockedNotice(id: noticeID)
                }
            }
        )
    }

    private var isPresented: Binding<Bool> {
        guard let confirmationID = workspaceManager.pendingSwitchConfirmation?.id else {
            return .constant(false)
        }
        return Self.confirmationPresentationBinding(
            manager: workspaceManager,
            confirmationID: confirmationID
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Switch Workspace?",
                isPresented: isPresented,
                presenting: workspaceManager.pendingSwitchConfirmation
            ) { confirmation in
                Button("Switch and End Sessions", role: .destructive) {
                    workspaceManager.resolveSwitchConfirmation(id: confirmation.id, allow: true)
                }
                Button("Cancel", role: .cancel) {
                    workspaceManager.resolveSwitchConfirmation(id: confirmation.id, allow: false)
                }
            } message: { confirmation in
                Text(confirmation.message)
            }
            .background {
                if workspaceManager.pendingSwitchConfirmation == nil,
                   let notice = workspaceManager.pendingWorkspaceSwitchBlockedNotice
                {
                    Color.clear
                        .alert(
                            "Workspace Switch Blocked",
                            isPresented: Self.blockedNoticePresentationBinding(
                                manager: workspaceManager,
                                noticeID: notice.id
                            ),
                            presenting: notice
                        ) { presentedNotice in
                            Button("OK") {
                                workspaceManager.dismissWorkspaceSwitchBlockedNotice(
                                    id: presentedNotice.id
                                )
                            }
                        } message: { presentedNotice in
                            Text(presentedNotice.message)
                        }
                }
            }
    }
}

extension View {
    func workspaceSwitchConfirmation(manager: WorkspaceManagerViewModel) -> some View {
        modifier(WorkspaceSwitchConfirmationModifier(workspaceManager: manager))
    }
}
