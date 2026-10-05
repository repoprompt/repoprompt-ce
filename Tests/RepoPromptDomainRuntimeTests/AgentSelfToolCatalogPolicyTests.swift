import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class AgentSelfToolCatalogPolicyTests: XCTestCase {
    func testCanonicalSelfToolHasOnlyTwoOperationsAndNoTargetSelectors() throws {
        let name = "self_compact"
        XCTAssertEqual(MCPDomainCanonicalToolDefinitions.definitions.filter { $0.name == name }.count, 1)
        XCTAssertNil(MCPDomainToolCatalog.entry(named: "agent_self"))
        let entry = try XCTUnwrap(MCPDomainToolCatalog.entry(named: name))
        XCTAssertEqual(entry.scope, .window)
        XCTAssertEqual(entry.capability, .agentSelfControl)
        XCTAssertEqual(entry.admissionClass, .control)
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: name))
        let schema = try XCTUnwrap(definition.inputSchema.objectValue)
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(schema["required"], .array([.string("op")]))
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        XCTAssertEqual(properties["op"]?.objectValue?["enum"], .array([.string("context"), .string("compact")]))
        XCTAssertEqual(Set(properties.keys), ["op", "note", "idempotency_key"])
        for operation in ["context", "compact"] {
            XCTAssertEqual(MCPDomainToolCatalog.operationIdentity(for: name, input: .value(operation)).normalizedOperation, operation)
        }
        XCTAssertEqual(MCPDomainToolCatalog.operationIdentity(for: name, input: .value("poll")).normalizedOperation, MCPDomainToolOperationIdentity.unknownOperation)
    }

    func testCanonicalSelfDefinitionFitsOneThousandCharactersWithEssentialContract() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "self_compact"))
        let serialized = try String(decoding: JSONEncoder().encode(definition), as: UTF8.self)
        XCTAssertLessThanOrEqual(serialized.count, 1000, "Complete minified definition, not description alone")
        let description = definition.description
        for required in [
            "Agent Mode session", "no target selector", "`context`", "load", "status",
            "`compact`", "nonempty `note`", "8,192 UTF-8 bytes", "`idempotency_key`",
            "200 UTF-8 bytes", "same note", "New `scheduled`", "finish this turn normally",
            "no new authority"
        ] {
            XCTAssertTrue(description.contains(required), required)
        }
    }

    func testSelfToolGrantedToAllAgentProfilesIncludingExploreButNotDirectOrDiscovery() {
        let name = "self_compact"
        for profile in MCPClientToolPolicyProfile.allCases {
            let visible = MCPClientToolPolicyCatalog.resolvedToolNames(for: profile)
            XCTAssertEqual(visible.contains(name), profile != .direct && profile != .discovery, profile.rawValue)
        }
        XCTAssertFalse(MCPClientToolPolicyCatalog.hiddenToolNames(for: .explore).contains(name))
        XCTAssertFalse(MCPDomainHost.executionRoleGatedCapabilities.contains(.agentSelfControl))
    }

    func testRevokedCapabilityDeniedAtCallTimeEvenWithExactLinkGrant() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone, profileIdentifier: "agent-self-policy-test",
            storageDirectory: directory, eventDirectory: directory, temporaryDirectory: directory,
            externalReloadInterval: nil
        ))
        try await runtime.start()
        let name = "self_compact"
        let revoked = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [], additionalToolNames: [], role: .engineer,
            allowsAgentExternalControlTools: true, hasExactAgentSessionLinkGrant: true
        )
        do {
            try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: name, policy: revoked)
            XCTFail("revoked self_compact grant must deny a named call")
        } catch let denial as MCPDomainCallPolicyDenial {
            XCTAssertEqual(denial, .missingAdditionalGrant(toolName: name))
        }
    }
}
