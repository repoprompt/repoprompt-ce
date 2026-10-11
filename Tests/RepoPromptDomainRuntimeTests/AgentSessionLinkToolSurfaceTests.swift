import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class AgentSessionLinkToolSurfaceTests: XCTestCase {
    func testExactLinkRolesAndLegacyDefaultPreserveFullDefinitionBytes() throws {
        let full = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.agentSessionLink))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (anyLink, outbound, expected) in [
            (false, false, AgentSessionLinkToolSurface.full),
            (true, false, .overseenOnly),
            (true, true, .full)
        ] {
            let surface = AgentSessionLinkToolSurface(hasAnyActiveLink: anyLink, hasActiveOutboundLink: outbound)
            XCTAssertEqual(surface, expected)
            if expected == .full {
                XCTAssertEqual(try encoder.encode(surface.project(full)), try encoder.encode(full))
            }
        }
    }

    func testReducedDefinitionRetainsCreationFieldsTypesAndOnlyOfferedTags() throws {
        let full = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.agentSessionLink))
        let reduced = AgentSessionLinkToolSurface.overseenOnly.project(full)
        XCTAssertEqual(reduced.description, "Declare what you are waiting on, ask a linked overseer for attention, or create a lane. Attention grants no authority.")
        XCTAssertEqual(reduced.annotations, full.annotations)
        XCTAssertEqual(reduced.isEnabledByDefault, full.isEnabledByDefault)
        let properties = try XCTUnwrap(reduced.inputSchema.objectValue?["properties"]?.objectValue)
        let fullProperties = try XCTUnwrap(full.inputSchema.objectValue?["properties"]?.objectValue)
        let offered: Set = ["set_waiting_on", "request_attention", "create_lane"]
        XCTAssertEqual(Set(properties["op"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []), offered)
        XCTAssertEqual(Set(properties.keys), [
            "op", "summary", "clear", "observer_session_id", "idempotency_key", "role", "model_id",
            "session_name", "workspace", "message", "workflow_id", "workflow_name"
        ])
        let canonicalOfferedFields = Set(fullProperties.compactMap { name, field -> String? in
            guard let description = field.objectValue?["description"]?.stringValue,
                  description.hasPrefix("["), let end = description.firstIndex(of: "]")
            else { return nil }
            let tags = description.dropFirst().prefix(upTo: end).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return Set(tags).isDisjoint(with: offered) ? nil : name
        }).union(["op", "model_id"])
        XCTAssertEqual(Set(properties.keys), canonicalOfferedFields, "new canonical fields for offered ops must not silently disappear")
        for (name, field) in properties {
            var projected = try XCTUnwrap(field.objectValue)
            var canonical = try XCTUnwrap(fullProperties[name]?.objectValue)
            let description = projected.removeValue(forKey: "description")?.stringValue
            canonical.removeValue(forKey: "description")
            if name == "op" {
                projected.removeValue(forKey: "enum")
                canonical.removeValue(forKey: "enum")
            }
            XCTAssertEqual(projected, canonical, "\(name): all non-prose field attributes must derive from full")
            if let description, description.hasPrefix("["), let end = description.firstIndex(of: "]") {
                let tags = description.dropFirst().prefix(upTo: end).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                XCTAssertFalse(tags.isEmpty, name)
                XCTAssertTrue(Set(tags).isSubset(of: offered), "\(name): \(description)")
            }
        }
        XCTAssertEqual(reduced.inputSchema.objectValue?["required"], full.inputSchema.objectValue?["required"])
        XCTAssertFalse(properties["clear"]?.objectValue?["description"]?.stringValue?.contains("snooze") == true)
        XCTAssertEqual(AgentSessionLinkToolSurface.overseenOnly.project(reduced), reduced, "projection is idempotent")
    }

    func testHostProjectionDoesNotChangeGrantRoleOrDisableAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("surface-policy-\(UUID().uuidString)")
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone, profileIdentifier: "surface-policy-test", storageDirectory: directory,
            eventDirectory: directory, temporaryDirectory: directory, externalReloadInterval: nil
        ))
        try await runtime.start()
        let name = MCPWindowToolName.agentSessionLink
        let full = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: name))
        _ = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(), scope: .window(id: 1),
            bindings: [MCPDomainToolBinding(definition: full, operation: { _ in .null })]
        )
        // External/headless/static additional grants retain the full default. No new eligibility
        // decision is made here; the Agent transport alone supplies a reduced exact-link surface.
        let legacy = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [], additionalToolNames: [name], role: .direct,
            allowsAgentExternalControlTools: false
        )
        let legacyCatalog = await runtime.domainHost.advertisedCatalog(.init(
            isGloballyEnabled: true, disabledToolNames: [], policy: legacy
        ))
        XCTAssertEqual(legacyCatalog.definitions, [full])
        let inbound = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [name], additionalToolNames: [], role: .explore,
            allowsAgentExternalControlTools: false, hasExactAgentSessionLinkGrant: true
        )
        let catalog = await runtime.domainHost.advertisedCatalog(.init(
            isGloballyEnabled: true, disabledToolNames: [], policy: inbound, agentSessionLinkSurface: .overseenOnly
        ))
        XCTAssertEqual(catalog.definitions, [AgentSessionLinkToolSurface.overseenOnly.project(full)])
        try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: name, policy: inbound)
        let admission = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(toolName: name, policy: inbound)
        XCTAssertEqual(admission.admissionClass, .control)
        let disabled = await runtime.domainHost.advertisedCatalog(.init(
            isGloballyEnabled: true, disabledToolNames: [name], policy: inbound, agentSessionLinkSurface: .overseenOnly
        ))
        XCTAssertTrue(disabled.definitions.isEmpty)
        let globallyDisabled = await runtime.domainHost.advertisedCatalog(.init(
            isGloballyEnabled: false, disabledToolNames: [], policy: inbound, agentSessionLinkSurface: .overseenOnly
        ))
        XCTAssertTrue(globallyDisabled.definitions.isEmpty)
        let unlinkedExplore = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [], additionalToolNames: [name], role: .explore, allowsAgentExternalControlTools: false
        )
        let hidden = await runtime.domainHost.advertisedCatalog(.init(
            isGloballyEnabled: true, disabledToolNames: [], policy: unlinkedExplore, agentSessionLinkSurface: .overseenOnly
        ))
        XCTAssertTrue(hidden.definitions.isEmpty, "projection cannot grant visibility")
        do {
            _ = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(toolName: name, policy: unlinkedExplore)
            XCTFail("projection cannot grant execution")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .roleUnavailable(toolName: name))
        }
    }
}
