import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// Catalog gating for the agent-only `session_admin` tool, and the guarantee that the external MCP
/// surface is unchanged by it.
final class SessionAdminToolCatalogPolicyTests: XCTestCase {
    private let toolName = MCPWindowToolName.sessionAdmin

    // MARK: - Canonical entry

    func testCanonicalEntryFollowsAgentSessionLinkWithItsOwnCapability() throws {
        XCTAssertEqual(toolName, "session_admin")
        let entry = try XCTUnwrap(MCPDomainToolCatalog.entry(named: toolName))
        XCTAssertEqual(entry.scope, .window)
        XCTAssertEqual(entry.capability, .agentSessionAdmin)
        XCTAssertEqual(entry.admissionClass, .control)
        let names = MCPDomainToolCatalog.orderedToolNames
        let linkIndex = try XCTUnwrap(names.firstIndex(of: MCPWindowToolName.agentSessionLink))
        XCTAssertEqual(names[linkIndex + 1], toolName)
        XCTAssertEqual(MCPDomainCanonicalToolDefinitions.definitions.filter { $0.name == toolName }.count, 1)
        XCTAssertEqual(MCPDomainCanonicalToolDefinitions.definitions.map(\.name), names)
    }

    func testSchemaAdvertisesExactlyTheCatalogOperations() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
        let schema = try XCTUnwrap(definition.inputSchema.objectValue)
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(schema["required"], .array([.string("op")]))
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        XCTAssertEqual(
            properties["op"]?.objectValue?["enum"],
            .array(MCPDomainSessionAdminToolDefinition.operations.map { .string($0) })
        )
        for operation in MCPDomainSessionAdminToolDefinition.operations {
            XCTAssertEqual(
                MCPDomainToolCatalog.operationIdentity(for: toolName, input: .value(" \(operation.uppercased()) ")).normalizedOperation,
                operation
            )
        }
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: toolName, input: .value("delete_session")).normalizedOperation,
            MCPDomainToolOperationIdentity.unknownOperation,
            "session deletion is human-only and has no operation"
        )
        for required in ["scope_capability_missing", "scope_guardrail_exceeded", "scope_expired", "confirmation_required", "human-only"] {
            XCTAssertTrue(definition.description.contains(required), required)
        }
        XCTAssertTrue(MCPDomainSessionAdminToolDefinition.implementedOperations.isSubset(of: Set(MCPDomainSessionAdminToolDefinition.operations)))
        // Every catalog op that is an authority action has exactly one scope identity.
        for op in MCPDomainSessionAdminToolDefinition.operations where !["confirmation_status", "undo"].contains(op) {
            XCTAssertNotNil(DomainAgentSessionTargetOperation(rawValue: "session_admin.\(op)"), op)
        }
    }

    // MARK: - Policy classification

    func testNoProfileGrantsTheToolStatically() {
        XCTAssertTrue(MCPClientToolPolicyCatalog.policyGatedCapabilities.contains(.agentSessionAdmin))
        XCTAssertTrue(MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName))
        for profile in MCPClientToolPolicyProfile.allCases {
            let classification = MCPClientToolPolicyCatalog.classification(for: profile)
            XCTAssertFalse(classification.grantedCapabilities.contains(.agentSessionAdmin), profile.rawValue)
            XCTAssertFalse(MCPClientToolPolicyCatalog.resolvedToolNames(for: profile).contains(toolName), profile.rawValue)
        }
    }

    func testExploreAndDiscoveryNeverReachTheTool() {
        XCTAssertTrue(MCPClientToolPolicyCatalog.discoveryRestrictedCapabilities.contains(.agentSessionAdmin))
        XCTAssertTrue(MCPClientToolPolicyCatalog.hiddenToolNames(for: .explore).contains(toolName))
        XCTAssertTrue(MCPDomainHost.executionRoleGatedCapabilities.contains(.agentSessionAdmin))
        XCTAssertTrue(MCPClientToolPolicyCatalog.shouldAdvertise(toolName: toolName, role: .engineer, allowsAgentExternalControlTools: false))
    }

    // MARK: - External surface is unchanged

    /// The administrative-principal / plain external connection catalog, pinned. Definitions of these
    /// tools are additionally byte-guarded by the generated canonical snapshot.
    func testExternalDirectAndDiscoveryCatalogsAreUnchangedAndExcludeSessionAdmin() {
        XCTAssertEqual(MCPClientToolPolicyCatalog.resolvedToolNames(for: .direct), [
            "app_settings", "bind_context", "manage_workspaces", "manage_selection", "file_actions",
            "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt",
            "apply_edits", "oracle_utils", "ask_oracle", "oracle_send", "git", "manage_worktree",
            "context_builder", "agent_run", "agent_manage", "history"
        ])
        XCTAssertEqual(MCPClientToolPolicyCatalog.resolvedToolNames(for: .discovery), [
            "manage_selection", "get_code_structure", "get_file_tree", "read_file", "file_search",
            "workspace_context", "prompt", "git", "ask_user", "history"
        ])
    }

    func testAdministrativePrincipalHostAdvertisementAndCallGateExcludeSessionAdmin() async throws {
        let runtime = try await makeRuntime()
        _ = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(),
            scope: .window(id: 1),
            bindings: MCPDomainToolCatalog.windowToolNames.map { try binding(toolName: $0) }
        )
        // External connections carry no run-scoped route, so no live grant is ever added; the
        // orchestrator flag and an exact link fact must not smuggle one in either.
        let administrative = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [], additionalToolNames: [MCPWindowToolName.askOracle],
            role: .direct, allowsAgentExternalControlTools: false
        )
        let advertised = await runtime.domainHost.advertisedCatalog(.init(
            isGloballyEnabled: true, disabledToolNames: [], policy: administrative
        ))
        XCTAssertFalse(advertised.definitions.map(\.name).contains(toolName))
        XCTAssertEqual(advertised.hiddenReasonsByToolName[toolName], .missingAdditionalToolGrant)
        do {
            try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: toolName, policy: administrative)
            XCTFail("an administrative principal must not reach session_admin by name")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .missingAdditionalGrant(toolName: toolName))
        }

        for policy in [
            MCPDomainClientPolicySnapshot(restrictedToolNames: [], additionalToolNames: [], role: .engineer, allowsAgentExternalControlTools: true),
            MCPDomainClientPolicySnapshot(restrictedToolNames: [], additionalToolNames: [], role: .direct, allowsAgentExternalControlTools: false, hasExactAgentSessionLinkGrant: true)
        ] {
            do {
                try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: toolName, policy: policy)
                XCTFail("only the live session_admin grant may admit the tool")
            } catch let denial as MCPDomainCallPolicyDenial {
                XCTAssertEqual(denial, .missingAdditionalGrant(toolName: toolName))
            }
        }
    }

    // MARK: - Live grant

    func testLiveGrantAdvertisesToEngineerButNotExplore() async throws {
        let runtime = try await makeRuntime()
        _ = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(),
            scope: .window(id: 1),
            bindings: [binding(toolName: toolName)]
        )
        let engineer = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [], additionalToolNames: [toolName], role: .engineer, allowsAgentExternalControlTools: false
        )
        let visible = await runtime.domainHost.advertisedCatalog(.init(isGloballyEnabled: true, disabledToolNames: [], policy: engineer))
        XCTAssertEqual(visible.definitions.map(\.name), [toolName])
        try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: toolName, policy: engineer)
        let decision = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(toolName: toolName, policy: engineer)
        XCTAssertEqual(decision.admissionClass, .control)

        let explore = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [], additionalToolNames: [toolName], role: .explore, allowsAgentExternalControlTools: false
        )
        let hidden = await runtime.domainHost.advertisedCatalog(.init(isGloballyEnabled: true, disabledToolNames: [], policy: explore))
        XCTAssertEqual(hidden.hiddenReasonsByToolName[toolName], .roleAdvertisementPolicy)
        do {
            _ = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(toolName: toolName, policy: explore)
            XCTFail("explore runs must not call session_admin by name")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .roleUnavailable(toolName: toolName))
        }

        let disabled = await runtime.domainHost.advertisedCatalog(.init(isGloballyEnabled: true, disabledToolNames: [toolName], policy: engineer))
        XCTAssertEqual(disabled.hiddenReasonsByToolName[toolName], .disabled)
    }

    // MARK: - Fixtures

    private func makeRuntime() async throws -> MCPDomainRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-admin-policy-\(UUID().uuidString)", isDirectory: true)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "session-admin-policy-test",
            storageDirectory: directory,
            eventDirectory: directory,
            temporaryDirectory: directory,
            externalReloadInterval: nil
        ))
        try await runtime.start()
        return runtime
    }

    private func binding(toolName: String) throws -> MCPDomainToolBinding {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
        return MCPDomainToolBinding(definition: definition, operation: { _ in .null })
    }
}
