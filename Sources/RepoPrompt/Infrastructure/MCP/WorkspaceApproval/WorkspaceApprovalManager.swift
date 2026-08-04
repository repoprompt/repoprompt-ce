//
//  WorkspaceApprovalManager.swift
//  RepoPrompt
//
//  Created by RepoPrompt – Workspace MCP approval integration
//

import AppKit
import Combine
import Foundation
import RepoPromptDomainRuntime

/// AppKit presenter and compatibility-policy façade for the domain mutation approval broker.
/// Queueing, timeout, cancellation, and late-response authority are AppKit-free and runtime-owned.
@MainActor
public final class WorkspaceApprovalManager: ObservableObject {
    public static let shared = WorkspaceApprovalManager()

    @Published public private(set) var pendingRequest: WorkspaceApprovalRequest?
    @Published public var isApprovalOverlayVisible: Bool = false
    @Published public private(set) var settings: WorkspaceApprovalSettings

    private static let settingsKey = "workspace.approvalSettings"
    private let broker = AppDomainRuntimeComposition.shared.runtime.mutationApprovalBroker
    private var requestsByID: [UUID: WorkspaceApprovalRequest] = [:]
    private var outstandingRequestIDs: Set<UUID> = []
    private var presenterRegistered = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(WorkspaceApprovalSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = WorkspaceApprovalSettings()
        }
    }

    public func requestApproval(for request: WorkspaceApprovalRequest) async -> WorkspaceApprovalResult {
        if settings.shouldAutoApprove(operation: request.operation, clientID: request.clientID) {
            updatePolicyLastUsed(clientID: request.clientID)
            return .approved(alwaysAllow: false)
        }
        guard !Task.isCancelled else { return .denied }

        await ensurePresenterRegistered()
        requestsByID[request.id] = request
        outstandingRequestIDs.insert(request.id)
        defer {
            requestsByID.removeValue(forKey: request.id)
            outstandingRequestIDs.remove(request.id)
        }

        let result = await broker.request(DomainMutationApprovalRequest(
            id: request.id,
            principalSummary: request.clientID,
            toolName: "manage_workspaces",
            action: request.operation.rawValue,
            risk: request.operation.riskLevel.domainRisk,
            summary: request.summary,
            windowID: request.windowID,
            deadline: Date().addingTimeInterval(300)
        ))
        switch result {
        case let .approved(alwaysAllow):
            return .approved(alwaysAllow: alwaysAllow)
        case .timeout:
            return .timeout
        case .denied, .cancelled, .presenterUnavailable:
            return .denied
        }
    }

    public func cancelPending(requestID: UUID) {
        clearPresentedRequestIfMatching(requestID)
        requestsByID.removeValue(forKey: requestID)
        outstandingRequestIDs.remove(requestID)
        Task { await broker.cancel(requestID: requestID) }
    }

    public func resolveApproval(allow: Bool, alwaysAllow: Bool = false) {
        guard let request = pendingRequest else { return }
        if allow, alwaysAllow {
            addAutoApproval(clientID: request.clientID, operation: request.operation)
        }
        let requestID = request.id
        clearPresentedRequestIfMatching(requestID)
        Task {
            await broker.resolve(
                requestID: requestID,
                approved: allow,
                alwaysAllow: alwaysAllow
            )
        }
    }

    #if DEBUG
        var pendingQueueCountForTesting: Int {
            max(0, outstandingRequestIDs.count - (pendingRequest == nil ? 0 : 1))
        }
    #endif

    public func cancelAllPending() {
        let ids = outstandingRequestIDs
        requestsByID.removeAll()
        outstandingRequestIDs.removeAll()
        pendingRequest = nil
        isApprovalOverlayVisible = false
        guard !ids.isEmpty else { return }
        Task { await broker.cancel(requestIDs: ids) }
    }

    public func cancelPending(forWindowID windowID: Int) {
        let ids = Set(requestsByID.values.compactMap { request in
            request.windowID == windowID ? request.id : nil
        })
        for id in ids {
            requestsByID.removeValue(forKey: id)
            outstandingRequestIDs.remove(id)
            clearPresentedRequestIfMatching(id)
        }
        guard !ids.isEmpty else { return }
        Task { await broker.cancel(requestIDs: ids) }
    }

    public func addAutoApproval(clientID: String, operation: WorkspaceApprovalOperation) {
        let storageKey = matchingPolicyKeys(for: clientID).first ?? clientID
        var policy = settings.clientPolicies[storageKey] ?? WorkspaceApprovalClientPolicy(clientID: storageKey)
        policy.allowedOperations.insert(operation)
        policy.lastUsedAt = Date()
        settings.clientPolicies[storageKey] = policy
        saveSettings()
    }

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

    public func removeAllAutoApprovals(for clientID: String) {
        for key in matchingPolicyKeys(for: clientID) {
            settings.clientPolicies.removeValue(forKey: key)
        }
        saveSettings()
    }

    public func setAutoApproveAll(_ enabled: Bool) {
        settings.autoApproveAll = enabled
        saveSettings()
    }

    public func setAutoApproveOperation(_ operation: WorkspaceApprovalOperation, enabled: Bool) {
        if enabled {
            settings.autoApproveOperations.insert(operation)
        } else {
            settings.autoApproveOperations.remove(operation)
        }
        saveSettings()
    }

    public var trustedClients: [WorkspaceApprovalClientPolicy] {
        Array(settings.clientPolicies.values).sorted { $0.clientID < $1.clientID }
    }

    private func ensurePresenterRegistered() async {
        guard !presenterRegistered else { return }
        presenterRegistered = true
        let manager = self
        await broker.registerPresenter(DomainMutationApprovalPresenter(
            present: { request in
                await manager.presentDomainApproval(request)
            },
            dismiss: { requestID in
                await manager.dismissDomainApproval(requestID)
            }
        ))
    }

    private func presentDomainApproval(_ request: DomainMutationApprovalRequest) -> Bool {
        guard let appRequest = requestsByID[request.id] else { return false }
        pendingRequest = appRequest
        isApprovalOverlayVisible = true
        bringWindowToFront(windowID: appRequest.windowID)
        if !NSApp.isActive {
            NSApp.requestUserAttention(.criticalRequest)
        }
        return true
    }

    private func dismissDomainApproval(_ requestID: UUID) {
        clearPresentedRequestIfMatching(requestID)
    }

    private func clearPresentedRequestIfMatching(_ requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        pendingRequest = nil
        isApprovalOverlayVisible = false
    }

    private func updatePolicyLastUsed(clientID: String) {
        for key in matchingPolicyKeys(for: clientID) {
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
        if let windowID,
           let windowState = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }),
           let nsWindow = windowState.nsWindow
        {
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            nsWindow.makeKeyAndOrderFront(nil)
        } else if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private extension WorkspaceApprovalRiskLevel {
    var domainRisk: DomainMutationApprovalRisk {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}

public extension WorkspaceApprovalManager {
    func requestCreateWorkspaceApproval(
        clientID: String,
        workspaceName: String,
        windowID: Int?
    ) async -> WorkspaceApprovalResult {
        await requestApproval(for: WorkspaceApprovalRequest(
            clientID: clientID,
            operation: .createWorkspace,
            workspaceName: workspaceName,
            windowID: windowID
        ))
    }

    func requestDeleteWorkspaceApproval(
        clientID: String,
        workspaceName: String,
        workspaceID: UUID,
        windowID: Int?
    ) async -> WorkspaceApprovalResult {
        await requestApproval(for: WorkspaceApprovalRequest(
            clientID: clientID,
            operation: .deleteWorkspace,
            workspaceName: workspaceName,
            workspaceID: workspaceID,
            windowID: windowID
        ))
    }

    func requestAddFolderApproval(
        clientID: String,
        folderPath: String,
        workspaceName: String,
        workspaceID: UUID,
        windowID: Int?
    ) async -> WorkspaceApprovalResult {
        await requestApproval(for: WorkspaceApprovalRequest(
            clientID: clientID,
            operation: .addFolder,
            workspaceName: workspaceName,
            workspaceID: workspaceID,
            folderPath: folderPath,
            windowID: windowID
        ))
    }

    func requestRemoveFolderApproval(
        clientID: String,
        folderPath: String,
        workspaceName: String,
        workspaceID: UUID,
        windowID: Int?
    ) async -> WorkspaceApprovalResult {
        await requestApproval(for: WorkspaceApprovalRequest(
            clientID: clientID,
            operation: .removeFolder,
            workspaceName: workspaceName,
            workspaceID: workspaceID,
            folderPath: folderPath,
            windowID: windowID
        ))
    }
}
