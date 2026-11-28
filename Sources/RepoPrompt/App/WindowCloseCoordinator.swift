import AppKit
import Foundation

enum WindowCloseDecision: Equatable {
    case allow
    case confirm(WindowCloseConfirmation)
    case background
    case denyDuplicatePrompt
}

struct WindowCloseAuthorization: Equatable {
    enum Source: Equatable {
        case userConfirmed
        case workspaceDelete
        case system
    }

    let source: Source
    let bypassConfirmation: Bool
    let bypassBackgroundPreservation: Bool
}

struct WindowCloseActivityItem: Equatable, Hashable {
    let id: String
    let count: Int
    let singularLabel: String
    let pluralLabel: String

    func formattedCount() -> String {
        let label = count == 1 ? singularLabel : pluralLabel
        return "\(count) \(label)"
    }
}

struct WindowCloseImpactSnapshot: Equatable {
    let isTerminating: Bool
    let isLastAppWindow: Bool
    let isLastMCPEnabledWindow: Bool
    let activeItems: [WindowCloseActivityItem]
    let mcp: WindowMCPCloseSafetyState
}

enum WindowCloseSecondaryAction: Equatable {
    case backgroundWindow
}

struct WindowCloseConfirmation: Equatable {
    let title: String
    let message: String
    let confirmButtonTitle: String
    let secondaryButtonTitle: String?
    let secondaryAction: WindowCloseSecondaryAction?
}

@MainActor
final class WindowCloseCoordinator {
    private struct PendingCloseAttempt {
        let id: UUID
        let confirmation: WindowCloseConfirmation
    }

    weak var windowState: WindowState?
    private var pendingAuthorization: WindowCloseAuthorization?
    private var pendingConfirmation: PendingCloseAttempt?
    private var presentedAlert: NSAlert?

    init(windowState: WindowState? = nil) {
        self.windowState = windowState
    }

    func enqueueAuthorization(_ authorization: WindowCloseAuthorization) {
        pendingAuthorization = authorization
    }

    func handleCloseAttempt(for window: NSWindow) -> WindowCloseDecision {
        guard let windowState else {
            return .allow
        }

        if WindowStatesManager.shared.isTerminating {
            clearPendingSheetIfNeeded()
            pendingAuthorization = nil
            return .allow
        }

        let authorization = consumeAuthorization()
        let snapshot = windowState.makeCloseImpactSnapshot()
        let decision = Self.decide(
            snapshot: snapshot, authorization: authorization,
            preservesAgentExecution: windowState.agentModeViewModel.preservableExecutionHost() != nil,
            keepsProcessAliveForAgentExecution: snapshot.isLastAppWindow && AppDelegate.hasUnsettledAgentExecution()
        )

        switch decision {
        case let .confirm(confirmation):
            guard presentConfirmationIfNeeded(confirmation, for: window) else {
                return .denyDuplicatePrompt
            }
            return .confirm(confirmation)
        case .background:
            MCPBackgroundModeCoordinator.shared.background(windowState: windowState)
            return .background
        case .allow, .denyDuplicatePrompt:
            return decision
        }
    }

    func beginClose() {
        clearPendingSheetIfNeeded()
        pendingAuthorization = nil
    }

    func windowWillClose() {
        clearPendingSheetIfNeeded()
        pendingAuthorization = nil
    }

    static func decide(
        snapshot: WindowCloseImpactSnapshot,
        authorization: WindowCloseAuthorization?,
        preservesAgentExecution: Bool = false,
        keepsProcessAliveForAgentExecution: Bool = false
    ) -> WindowCloseDecision {
        if snapshot.isTerminating {
            return .allow
        }

        if authorization != nil {
            return .allow
        }

        let activeItems = activeItems(for: snapshot).filter {
            !preservesAgentExecution || $0.id != AgentModeWorkspaceSwitchSessionProvider.activityID
        }
        if !activeItems.isEmpty {
            return .confirm(activeWorkConfirmation(activeItems: activeItems))
        }

        if snapshot.isLastMCPEnabledWindow {
            if snapshot.isLastAppWindow, snapshot.mcp.toolsEnabled, !keepsProcessAliveForAgentExecution {
                return .confirm(lastWindowMCPContinuityConfirmation(connectionCount: snapshot.mcp.liveConnectionCount))
            }
            if snapshot.mcp.hasIdleLiveConnections {
                return .confirm(mcpContinuityConfirmation(connectionCount: snapshot.mcp.liveConnectionCount))
            }
        }

        return .allow
    }

    private func consumeAuthorization() -> WindowCloseAuthorization? {
        let authorization = pendingAuthorization
        pendingAuthorization = nil
        return authorization
    }

    private func presentConfirmationIfNeeded(_ confirmation: WindowCloseConfirmation, for window: NSWindow) -> Bool {
        guard pendingConfirmation == nil else {
            return false
        }

        let attempt = PendingCloseAttempt(id: UUID(), confirmation: confirmation)
        pendingConfirmation = attempt

        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmation.confirmButtonTitle)
        let hasSecondaryAction = confirmation.secondaryButtonTitle != nil && confirmation.secondaryAction != nil
        if let secondaryButtonTitle = confirmation.secondaryButtonTitle {
            alert.addButton(withTitle: secondaryButtonTitle)
        }
        alert.addButton(withTitle: "Cancel")
        presentedAlert = alert

        alert.beginSheetModal(for: window) { [weak self, weak windowState] response in
            Task { @MainActor in
                guard let self else { return }
                guard self.pendingConfirmation?.id == attempt.id else { return }

                self.pendingConfirmation = nil
                self.presentedAlert = nil

                guard let windowState,
                      windowState.nsWindow != nil,
                      !windowState.isClosing
                else {
                    return
                }

                if response == .alertFirstButtonReturn {
                    windowState.requestClose(
                        authorization: WindowCloseAuthorization(
                            source: .userConfirmed,
                            bypassConfirmation: true,
                            bypassBackgroundPreservation: true
                        )
                    )
                    return
                }

                if hasSecondaryAction,
                   response == .alertSecondButtonReturn,
                   let action = confirmation.secondaryAction
                {
                    self.performSecondaryAction(action, for: windowState)
                }
            }
        }

        return true
    }

    private func clearPendingSheetIfNeeded() {
        pendingConfirmation = nil
        if let alert = presentedAlert,
           let parent = alert.window.sheetParent
        {
            parent.endSheet(alert.window, returnCode: .cancel)
        }
        presentedAlert = nil
    }

    private static func activeItems(for snapshot: WindowCloseImpactSnapshot) -> [WindowCloseActivityItem] {
        var items = snapshot.activeItems.filter { $0.count > 0 }
        if snapshot.mcp.activeExecutionCount > 0 {
            items.append(
                WindowCloseActivityItem(
                    id: "mcp-active-execution",
                    count: snapshot.mcp.activeExecutionCount,
                    singularLabel: "active MCP tool execution",
                    pluralLabel: "active MCP tool executions"
                )
            )
        }
        return items.sorted { $0.id < $1.id }
    }

    private func performSecondaryAction(_ action: WindowCloseSecondaryAction, for windowState: WindowState) {
        switch action {
        case .backgroundWindow:
            MCPBackgroundModeCoordinator.shared.background(windowState: windowState)
        }
    }

    private static func activeWorkConfirmation(activeItems: [WindowCloseActivityItem]) -> WindowCloseConfirmation {
        WindowCloseConfirmation(
            title: "Close Window?",
            message: "Closing this window will terminate \(summaryText(for: activeItems)). Do you want to continue?",
            confirmButtonTitle: "Close and End Sessions",
            secondaryButtonTitle: nil,
            secondaryAction: nil
        )
    }

    private static func mcpContinuityConfirmation(connectionCount: Int) -> WindowCloseConfirmation {
        let label = connectionCount == 1 ? "client" : "clients"
        return WindowCloseConfirmation(
            title: "Disconnect MCP?",
            message: "Closing this window will disconnect \(connectionCount) MCP \(label).",
            confirmButtonTitle: "Close and Disconnect",
            secondaryButtonTitle: nil,
            secondaryAction: nil
        )
    }

    private static func lastWindowMCPContinuityConfirmation(connectionCount: Int) -> WindowCloseConfirmation {
        let message: String
        if connectionCount > 0 {
            let label = connectionCount == 1 ? "client" : "clients"
            message = "This is the last MCP-enabled window. Close to disconnect \(connectionCount) \(label) and stop MCP, or hide it to keep MCP running from the menu bar."
        } else {
            message = "This is the last MCP-enabled window. Close to stop MCP, or hide it to keep MCP running from the menu bar."
        }
        return WindowCloseConfirmation(
            title: "Keep MCP running?",
            message: message,
            confirmButtonTitle: "Close and Stop MCP",
            secondaryButtonTitle: "Hide and Keep Running",
            secondaryAction: .backgroundWindow
        )
    }

    private static func summaryText(for items: [WindowCloseActivityItem]) -> String {
        items
            .filter { $0.count > 0 }
            .map { $0.formattedCount() }
            .joined(separator: " and ")
    }
}
