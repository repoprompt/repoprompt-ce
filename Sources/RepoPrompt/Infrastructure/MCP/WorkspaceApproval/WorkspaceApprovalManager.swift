//
//  WorkspaceApprovalManager.swift
//  RepoPrompt
//
//  Created by RepoPrompt – Workspace MCP approval integration
//

import AppKit
import Combine
import Foundation

/// Manages approval requests for workspace operations triggered by MCP clients.
/// Similar to the MCP client connection approval flow, but for workspace modifications.
@MainActor
public final class WorkspaceApprovalManager: ObservableObject {
    // MARK: - Singleton

    public static let shared = WorkspaceApprovalManager()

    // MARK: - Published State

    /// The currently pending approval request, if any.
    @Published public private(set) var pendingRequest: WorkspaceApprovalRequest?

    /// Whether the approval overlay should be visible.
    @Published public var isApprovalOverlayVisible: Bool = false

    /// Current approval settings.
    @Published public private(set) var settings: WorkspaceApprovalSettings

    // MARK: - Private State

    /// Queue of pending approval requests.
    private var pendingQueue: [(WorkspaceApprovalRequest, CheckedContinuation<WorkspaceApprovalResult, Never>)] = []

    /// Current approval continuation (for the active request).
    private var currentContinuation: CheckedContinuation<WorkspaceApprovalResult, Never>?

    /// UserDefaults key for settings persistence.
    private static let settingsKey = "workspace.approvalSettings"

    // MARK: - Init

    private init() {
        // Load settings from UserDefaults
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(WorkspaceApprovalSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = WorkspaceApprovalSettings()
        }
    }

    // MARK: - Public API

    /// Request approval for a workspace operation.
    /// Returns the user's decision.
    ///
    /// The wait is cancellation-aware: if the calling task is cancelled (for example by a
    /// tool-execution watchdog), the request resolves as `.denied` instead of parking the
    /// caller on an unresolvable continuation while the side effect remains pending.
    public func requestApproval(for request: WorkspaceApprovalRequest) async -> WorkspaceApprovalResult {
        // Check if auto-approved
        if settings.shouldAutoApprove(operation: request.operation, clientID: request.clientID) {
            // Update last used timestamp for the client policy
            updatePolicyLastUsed(clientID: request.clientID)
            return .approved(alwaysAllow: false)
        }

        // Need user approval
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .denied)
                    return
                }

                // If there's already a pending request, queue this one
                if pendingRequest != nil {
                    pendingQueue.append((request, continuation))
                    return
                }

                // Show approval overlay
                pendingRequest = request
                currentContinuation = continuation
                isApprovalOverlayVisible = true

                // Bring window to front and request attention
                bringWindowToFront(windowID: request.windowID)

                if !NSApp.isActive {
                    NSApp.requestUserAttention(.criticalRequest)
                }
            }
        } onCancel: {
            Task { @MainActor in
                WorkspaceApprovalManager.shared.cancelPending(requestID: request.id)
            }
        }
    }

    /// Deny and clear a specific pending approval request, whether it is the active
    /// request or still queued. No-op if the request has already been resolved.
    public func cancelPending(requestID: UUID) {
        if pendingRequest?.id == requestID {
            currentContinuation?.resume(returning: .denied)
            currentContinuation = nil
            pendingRequest = nil
            isApprovalOverlayVisible = false
            processNextQueuedRequest()
            return
        }

        guard let index = pendingQueue.firstIndex(where: { $0.0.id == requestID }) else { return }
        let (_, continuation) = pendingQueue.remove(at: index)
        continuation.resume(returning: .denied)
    }

    /// Resolve the current pending approval request.
    public func resolveApproval(allow: Bool, alwaysAllow: Bool = false) {
        guard let request = pendingRequest,
              let continuation = currentContinuation
        else {
            return
        }

        // If always-allow was selected, update the policy
        if allow && alwaysAllow {
            addAutoApproval(clientID: request.clientID, operation: request.operation)
        }

        // Resume the continuation
        let result: WorkspaceApprovalResult = allow ? .approved(alwaysAllow: alwaysAllow) : .denied
        continuation.resume(returning: result)

        // Clear current state
        currentContinuation = nil
        pendingRequest = nil
        isApprovalOverlayVisible = false

        // Process next queued request if any
        processNextQueuedRequest()
    }

    #if DEBUG
        var pendingQueueCountForTesting: Int {
            pendingQueue.count
        }
    #endif

    /// Cancel all pending approvals (e.g., when window closes).
    public func cancelAllPending() {
        // Cancel current
        if let continuation = currentContinuation {
            continuation.resume(returning: .denied)
        }

        // Cancel queued
        for (_, continuation) in pendingQueue {
            continuation.resume(returning: .denied)
        }

        currentContinuation = nil
        pendingRequest = nil
        pendingQueue = []
        isApprovalOverlayVisible = false
    }

    /// Cancel approvals associated with a specific window without affecting other windows.
    public func cancelPending(forWindowID windowID: Int) {
        if pendingRequest?.windowID == windowID {
            currentContinuation?.resume(returning: .denied)
            currentContinuation = nil
            pendingRequest = nil
            isApprovalOverlayVisible = false
        }

        var remainingQueue: [(WorkspaceApprovalRequest, CheckedContinuation<WorkspaceApprovalResult, Never>)] = []
        for (request, continuation) in pendingQueue {
            if request.windowID == windowID {
                continuation.resume(returning: .denied)
            } else {
                remainingQueue.append((request, continuation))
            }
        }
        pendingQueue = remainingQueue

        if pendingRequest == nil {
            processNextQueuedRequest()
        }
    }

    // MARK: - Settings Management

    /// Add an auto-approval for a specific client and operation.
    public func addAutoApproval(clientID: String, operation: WorkspaceApprovalOperation) {
        let storageKey = matchingPolicyKeys(for: clientID).first ?? clientID
        var policy = settings.clientPolicies[storageKey] ?? WorkspaceApprovalClientPolicy(clientID: storageKey)
        policy.allowedOperations.insert(operation)
        policy.lastUsedAt = Date()
        settings.clientPolicies[storageKey] = policy
        saveSettings()
    }

    /// Remove an auto-approval for a specific client and operation.
    public func removeAutoApproval(clientID: String, operation: WorkspaceApprovalOperation) {
        let keys = matchingPolicyKeys(for: clientID)
        guard !keys.isEmpty else { return }
        for key in keys {
            guard var policy = settings.clientPolicies[key] else { continue }
            policy.allowedOperations.remove(operation)

            if policy.allowedOperations.isEmpty {
                settings.clientPolicies.removeValue(forKey: key)
            } else {
                settings.clientPolicies[key] = policy
            }
        }
        saveSettings()
    }

    /// Remove all auto-approvals for a client.
    public func removeAllAutoApprovals(for clientID: String) {
        let keys = matchingPolicyKeys(for: clientID)
        guard !keys.isEmpty else { return }
        for key in keys {
            settings.clientPolicies.removeValue(forKey: key)
        }
        saveSettings()
    }

    /// Set global auto-approve all setting.
    public func setAutoApproveAll(_ enabled: Bool) {
        settings.autoApproveAll = enabled
        saveSettings()
    }

    /// Set global auto-approve for a specific operation.
    public func setAutoApproveOperation(_ operation: WorkspaceApprovalOperation, enabled: Bool) {
        if enabled {
            settings.autoApproveOperations.insert(operation)
        } else {
            settings.autoApproveOperations.remove(operation)
        }
        saveSettings()
    }

    /// Get all trusted clients with their policies.
    public var trustedClients: [WorkspaceApprovalClientPolicy] {
        Array(settings.clientPolicies.values).sorted { $0.clientID < $1.clientID }
    }

    // MARK: - Private Helpers

    private func processNextQueuedRequest() {
        guard !pendingQueue.isEmpty else { return }

        let (nextRequest, continuation) = pendingQueue.removeFirst()

        // Check if this queued request can now be auto-approved
        if settings.shouldAutoApprove(operation: nextRequest.operation, clientID: nextRequest.clientID) {
            updatePolicyLastUsed(clientID: nextRequest.clientID)
            continuation.resume(returning: .approved(alwaysAllow: false))
            processNextQueuedRequest()
            return
        }

        // Show approval overlay for next request
        pendingRequest = nextRequest
        currentContinuation = continuation
        isApprovalOverlayVisible = true

        bringWindowToFront(windowID: nextRequest.windowID)
    }

    private func updatePolicyLastUsed(clientID: String) {
        let keys = matchingPolicyKeys(for: clientID)
        guard !keys.isEmpty else { return }
        for key in keys {
            guard var policy = settings.clientPolicies[key] else { continue }
            policy.lastUsedAt = Date()
            settings.clientPolicies[key] = policy
        }
        saveSettings()
    }

    private func matchingPolicyKeys(for clientID: String) -> [String] {
        let exactMatches = settings.clientPolicies.keys.filter { $0 == clientID }
        let familyMatches = settings.clientPolicies.keys
            .filter { $0 != clientID && MCPClientIdentity.matches($0, clientID) }
            .sorted()
        return exactMatches + familyMatches
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private func bringWindowToFront(windowID: Int?) {
        // Try to find and activate the specific window, or just activate the app
        if let windowID,
           let windowState = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }),
           let nsWindow = windowState.nsWindow
        {
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            nsWindow.makeKeyAndOrderFront(nil)
        } else {
            // Just activate the app
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - Convenience Extensions

public extension WorkspaceApprovalManager {
    /// Create and request approval for a workspace creation operation.
    func requestCreateWorkspaceApproval(
        clientID: String,
        workspaceName: String,
        windowID: Int?
    ) async -> WorkspaceApprovalResult {
        let request = WorkspaceApprovalRequest(
            clientID: clientID,
            operation: .createWorkspace,
            workspaceName: workspaceName,
            windowID: windowID
        )
        return await requestApproval(for: request)
    }

    /// Create and request approval for a workspace deletion operation.
    func requestDeleteWorkspaceApproval(
        clientID: String,
        workspaceName: String,
        workspaceID: UUID,
        windowID: Int?
    ) async -> WorkspaceApprovalResult {
        let request = WorkspaceApprovalRequest(
            clientID: clientID,
            operation: .deleteWorkspace,
            workspaceName: workspaceName,
            workspaceID: workspaceID,
            windowID: windowID
        )
        return await requestApproval(for: request)
    }

    /// Create and request approval for adding a folder to a workspace.
    func requestAddFolderApproval(
        clientID: String,
        folderPath: String,
        workspaceName: String,
        workspaceID: UUID,
        windowID: Int?
    ) async -> WorkspaceApprovalResult {
        let request = WorkspaceApprovalRequest(
            clientID: clientID,
            operation: .addFolder,
            workspaceName: workspaceName,
            workspaceID: workspaceID,
            folderPath: folderPath,
            windowID: windowID
        )
        return await requestApproval(for: request)
    }

    /// Create and request approval for removing a folder from a workspace.
    func requestRemoveFolderApproval(
        clientID: String,
        folderPath: String,
        workspaceName: String,
        workspaceID: UUID,
        windowID: Int?
    ) async -> WorkspaceApprovalResult {
        let request = WorkspaceApprovalRequest(
            clientID: clientID,
            operation: .removeFolder,
            workspaceName: workspaceName,
            workspaceID: workspaceID,
            folderPath: folderPath,
            windowID: windowID
        )
        return await requestApproval(for: request)
    }
}
