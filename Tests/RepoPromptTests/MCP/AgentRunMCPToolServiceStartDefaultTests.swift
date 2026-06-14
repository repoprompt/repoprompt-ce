import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentRunMCPToolServiceStartDefaultTests: XCTestCase {
    func testUntargetedStartWithoutModelIDResolvesThroughPairDefault() throws {
        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: nil)
        XCTAssertEqual(defaultLabel, .pair)

        var requestedRole: AgentModelCatalog.TaskLabelKind?
        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: nil,
            defaultTaskLabel: defaultLabel,
            availability: .current,
            roleSelectionProvider: { role, _ in
                requestedRole = role
                return AgentModelCatalog.NormalizedAgentSelection(agent: .codexExec, modelRaw: "pair-default-model")
            }
        )

        XCTAssertEqual(requestedRole, .pair)
        XCTAssertEqual(resolved.taskLabelKind, .pair)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(resolved.modelRaw, "pair-default-model")
    }

    func testFreshPairEngineerAndExploreStartsUseCodexSafeManagedDefaults() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        CodexAgentToolPreferences.setMCPServerEnabled(
            normalizedName: "external-tools",
            isEnabled: true,
            defaults: defaults
        )
        let service = makeBindingService(defaults: defaults)

        for role in [AgentModelCatalog.TaskLabelKind.pair, .engineer, .explore] {
            let selection = try AgentMCPSelectionResolver.resolve(
                modelID: role.rawValue,
                defaultTaskLabel: nil,
                availability: .current,
                roleSelectionProvider: { requestedRole, _ in
                    XCTAssertEqual(requestedRole, role)
                    return AgentModelCatalog.NormalizedAgentSelection(
                        agent: .codexExec,
                        modelRaw: "\(role.rawValue)-codex-model"
                    )
                }
            )
            XCTAssertEqual(selection.agentRaw, AgentProviderKind.codexExec.rawValue)

            let profile = service.permissionProfileForMCPActivation(
                isSubagent: true,
                provider: .codex
            )
            XCTAssertEqual(profile, .mcpSafeDefaults)

            let snapshot = service.controlsBinding(
                selectedAgent: .codexExec,
                selectedModelRaw: selection.modelRaw,
                permissionProfile: profile,
                isSubagent: true,
                externallyManagedReason: nil
            )
            XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.autoReview.displayName)
            XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .workspaceWrite)
            XCTAssertEqual(snapshot.runtimePermission.codexApprovalPolicy, .onRequest)
            XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .autoReview)
            XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, true)
            XCTAssertEqual(snapshot.codexTools?.mcpServerStatesByNormalizedName["external-tools"], false)
            XCTAssertTrue(profile.codexBashToolEnabled(userConfigured: false))
            XCTAssertTrue(profile.codexSuppressesThirdPartyMCPServers)
        }
    }

    func testInheritedRestrictiveCodexSettingsRemainRestrictive() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.inheritProviderSettings, defaults: defaults)
        CodexAgentToolPreferences.setPermissionLevel(.readOnly, defaults: defaults)
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .userConfigured)
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .readOnly)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .user)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, false)
        XCTAssertFalse(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertFalse(profile.codexSuppressesThirdPartyMCPServers)
    }

    func testCustomRestrictiveCodexOverrideWinsOverSafeManagedDefaults() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom, defaults: defaults)
        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
            .codex(.readOnly),
            for: .codex,
            defaults: defaults
        )
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .providerOverride(.codex(.readOnly)))
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .readOnly)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .user)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, false)
        XCTAssertFalse(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertFalse(profile.codexSuppressesThirdPartyMCPServers)
    }

    func testSubagentPolicyStorageFailureUsesCodexSafeManagedSnapshot() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let secureStore = AgentPermissionSecureStore(
            secureStrings: AgentRunFailingSecurePlainStringStore(),
            notificationCenter: NotificationCenter()
        )
        let service = makeBindingService(defaults: defaults, secureStore: secureStore)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .mcpSafeDefaults)
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.autoReview.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .autoReview)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, true)
        XCTAssertEqual(snapshot.codexTools?.mcpServerStatesByNormalizedName["external-tools"], false)
        XCTAssertTrue(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertTrue(profile.codexSuppressesThirdPartyMCPServers)
        XCTAssertEqual(secureStore.diagnostic(for: .subagent)?.kind, .keychainInteractionNotAllowed)
    }

    func testExplicitTargetTabWithOmittedModelIDPreservesCurrentSelection() {
        let targetTabID = UUID()

        XCTAssertNil(AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: targetTabID))
    }

    func testWorkflowDefaultDoesNotOverridePairForUntargetedStart() {
        XCTAssertEqual(AgentWorkflow.oracleExport.defaultTaskLabelKind, .explore)

        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(
            resolvedTabID: nil,
            workflow: AgentWorkflow.oracleExport.definition
        )

        XCTAssertEqual(defaultLabel, .pair)
    }

    private func makeBindingService(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> AgentModeProviderBindingService {
        AgentModeProviderBindingService(
            preferences: AgentProviderPreferenceSnapshotStore(
                defaults: defaults,
                securePermissions: secureStore,
                codexMCPServerEntries: {
                    [
                        MCPIntegrationHelper.CodexServerEntry(
                            rawName: "external-tools",
                            normalizedName: "external-tools",
                            cliPathComponent: "external-tools"
                        )
                    ]
                }
            )
        )
    }

    func testExplicitModelIDTakesPrecedenceOverStartPairDefault() throws {
        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: nil)

        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: "codexExec:explicit-model",
            defaultTaskLabel: defaultLabel,
            availability: AgentModelCatalog.AvailabilityContext(codexAvailable: true)
        )

        XCTAssertNil(resolved.taskLabelKind)
        XCTAssertEqual(resolved.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(resolved.modelRaw, "explicit-model")
    }
}

private final class AgentRunFailingSecurePlainStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true

    func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String? {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }
}
